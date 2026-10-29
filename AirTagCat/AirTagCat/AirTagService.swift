import CoreBluetooth
import Darwin

// Same order as SOCKET_PATHS in Tweak.m; the tweak binds the first one
// locationd's sandbox allows.
private let kSocketPaths = [
    "/var/jb/var/tmp/airtagcat.sock",
    "/var/root/Library/Caches/locationd/airtagcat.sock",
    "/tmp/airtagcat.sock",
]
private let kRSSI1m: Double = -59
private let kPathN:  Double =  2.7
private let kNamesKey       = "airtag_names_v1"

enum SoundSequence: String, CaseIterable, Identifiable {
    case classic   = "Classic"
    case chirp     = "Chirp"
    case repeated  = "Repeated"
    case insistent = "Insistent"

    var id: String { rawValue }

    // Raw sequence bytes for CLDurianTask.startSoundSequenceTaskWithSequence:
    // Format: [sound_id, reps, len, pause] × N  (IDs 4+5 are audible)
    var flatBytes: [UInt8] {
        switch self {
        case .classic:   return [0x04, 0x01, 0x00, 0x00, 0x05, 0x02, 0x00, 0x00]
        case .chirp:     return [0x04, 0x01, 0x00, 0x00]
        case .repeated:  return [0x04, 0x05, 0x00, 0x00]
        case .insistent: return [0x04, 0x01, 0x00, 0x00, 0x05, 0x05, 0x00, 0x00]
        }
    }
}

struct FoundTag: Identifiable {
    let id: String
    var name: String
    var rssi: Int?
    var distance: Double?
    var soundOn: Bool                  = false
    var selectedSound: SoundSequence  = .classic
}

final class AirTagService: NSObject, ObservableObject {

    enum State: Equatable {
        case connecting, ready, noTweak

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.connecting,.connecting), (.ready,.ready), (.noTweak,.noTweak): return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .connecting: return "Connecting to locationd hook…"
            case .ready:      return "Active"
            case .noTweak:    return "Tweak not detected — install AirTagCat.deb first"
            }
        }
    }

    @Published var state: State      = .connecting
    @Published var tags:  [FoundTag] = []

    private var socketFd:        Int32          = -1
    private var loggedErrors:    [String: Int32] = [:]   // per path, so retries don't spam
    private var nameMap:         [String: String]
    private var peripherals:     [String: CBPeripheral] = [:]  // tagID → CBPeripheral
    private var peripheralUUIDs: [String: UUID]         = [:]  // tagID → peripheral UUID
    private var rssiTimers:      [String: Timer]        = [:]
    private var smoothedRSSI:    [String: Double]       = [:]
    private var central:         CBCentralManager?
    private var hintTimer:       Timer?

    private let kEMAAlpha: Double = 0.15

    override init() {
        nameMap = (UserDefaults.standard.dictionary(forKey: kNamesKey) as? [String: String]) ?? [:]
        super.init()
    }

    // MARK: - Public API

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
        attemptSocketConnect()
        // Show a hint after 6 s if still not connected
        hintTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .connecting else { return }
            self.state = .noTweak
        }
    }

    func setName(_ name: String, forTagID id: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        nameMap[id] = name
        UserDefaults.standard.set(nameMap, forKey: kNamesKey)
        mutateTag(id) { $0.name = name }
    }

    func setSound(_ sound: SoundSequence, forTagID id: String) {
        mutateTag(id) { $0.selectedSound = sound }
    }

    func playSound(tagID: String) {
        mutateTag(tagID) { $0.soundOn = true }
        guard let tag = tags.first(where: { $0.id == tagID }) else { return }
        sendCommand(["type": "playSound",
                     "deviceId": tagID,
                     "sequence": tag.selectedSound.flatBytes.map { Int($0) }])
    }

    func stopSound(tagID: String) {
        mutateTag(tagID) { $0.soundOn = false }
        sendCommand(["type": "stopSound", "deviceId": tagID])
    }

    // MARK: - Socket

    private func attemptSocketConnect() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.doConnect() }
    }

    private func doConnect() {
        guard let fd = kSocketPaths.lazy.compactMap(connectSocket).first else {
            scheduleRetry(); return
        }

        DispatchQueue.main.async { [weak self] in
            self?.socketFd = fd
            self?.hintTimer?.invalidate()
            self?.state = .ready
        }
        readLoop(fd: fd)
    }

    private func connectSocket(_ path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { Darwin.strcpy($0, src) }
        }
        let ok = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0

        guard ok else {
            let err = errno
            Darwin.close(fd)
            if loggedErrors[path] != err {
                loggedErrors[path] = err
                NSLog("[AirTagCat] connect(%@) failed: errno %d (%@)", path, err, String(cString: strerror(err)))
            }
            return nil
        }
        NSLog("[AirTagCat] connected to %@", path)
        return fd
    }

    private func readLoop(fd: Int32) {
        var tmp  = [UInt8](repeating: 0, count: 4096)
        var accum = Data()

        while true {
            let n = Darwin.read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            accum.append(contentsOf: tmp[0..<n])

            while let nl = accum.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(accum[..<nl])
                accum = accum[accum.index(after: nl)...]
                if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { [weak self] in self?.handleMessage(msg) }
                }
            }
        }

        Darwin.close(fd)
        DispatchQueue.main.async { [weak self] in
            self?.socketFd = -1
            self?.state = .connecting
            self?.scheduleRetry()
        }
    }

    private func scheduleRetry() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.doConnect()
        }
    }

    private func sendCommand(_ cmd: [String: Any]) {
        guard socketFd >= 0,
              var data = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { Darwin.write(socketFd, $0.baseAddress!, $0.count) }
    }

    // MARK: - Message handling

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String, type == "devices",
              let list = msg["devices"] as? [[String: Any]] else { return }
        state = .ready
        for d in list {
            guard let tagID = d["id"] as? String else { continue }
            let tweetName = (d["name"] as? String) ?? "AirTag"
            let peripheralId = (d["peripheralId"] as? String) ?? ""

            if !tags.contains(where: { $0.id == tagID }) {
                tags.append(FoundTag(id: tagID, name: nameMap[tagID] ?? tweetName))
            } else if nameMap[tagID] == nil {
                mutateTag(tagID) { $0.name = tweetName }
            }

            if !peripheralId.isEmpty, let uuid = UUID(uuidString: peripheralId) {
                peripheralUUIDs[tagID] = uuid
                connectForRSSI(tagID: tagID, uuid: uuid)
            }
        }
    }

    // MARK: - RSSI via CoreBluetooth

    private func connectForRSSI(tagID: String, uuid: UUID) {
        guard peripherals[tagID] == nil,
              let central = central, central.state == .poweredOn else { return }
        let found = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = found.first {
            peripherals[tagID] = p
            p.delegate = self
            central.connect(p, options: nil)
        }
    }

    private func startRSSITimer(for peripheral: CBPeripheral) {
        let tagID = peripherals.first(where: { $0.value === peripheral })?.key ?? ""
        guard !tagID.isEmpty else { return }
        rssiTimers[tagID]?.invalidate()
        rssiTimers[tagID] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak peripheral] _ in
            peripheral?.readRSSI()
        }
    }

    // MARK: - Helpers

    private func mutateTag(_ id: String, body: (inout FoundTag) -> Void) {
        guard let idx = tags.firstIndex(where: { $0.id == id }) else { return }
        body(&tags[idx])
    }

    private func tagID(for peripheral: CBPeripheral) -> String? {
        peripherals.first(where: { $0.value === peripheral })?.key
    }

    private func toMeters(_ rssi: Int) -> Double {
        pow(10.0, (kRSSI1m - Double(rssi)) / (10.0 * kPathN))
    }
}

// MARK: - CBCentralManagerDelegate

extension AirTagService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        for (tagID, uuid) in peripheralUUIDs where peripherals[tagID] == nil {
            connectForRSSI(tagID: tagID, uuid: uuid)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        startRSSITimer(for: peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let tagID = tagID(for: peripheral) else { return }
        rssiTimers[tagID]?.invalidate()
        rssiTimers.removeValue(forKey: tagID)
        smoothedRSSI.removeValue(forKey: tagID)
        mutateTag(tagID) { t in t.rssi = nil; t.distance = nil }
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension AirTagService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue < 0,
              let tagID = tagID(for: peripheral) else { return }
        let raw = Double(RSSI.intValue)
        let ema = smoothedRSSI[tagID].map { kEMAAlpha * raw + (1 - kEMAAlpha) * $0 } ?? raw
        smoothedRSSI[tagID] = ema
        let display = Int(ema.rounded())
        mutateTag(tagID) { t in t.rssi = display; t.distance = toMeters(display) }
    }
}
