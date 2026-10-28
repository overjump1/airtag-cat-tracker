import CoreBluetooth
import Combine

private let kFindMyServiceUUID = CBUUID(string: "7DFC9000-7D1C-4951-86AA-8D9728F8D66C")
private let kAppleNearbyUUID   = CBUUID(string: "FD44")
private let kAirTagPSM: CBL2CAPPSM = 0x0101   // Durian L2CAP command channel
private let kRSSI1m: Double    = -59
private let kPathN:  Double    =  2.7
private let kNamesKey          = "airtag_names_v1"

// Sound sequence format per seemoo-lab/airtag research:
//   Opcode 40 (0x28) = Play Sound Sequence
//   Opcode  8 (0x08) = Stop Sound
//   Payload format:  [sound_id(0-7), repetitions, length, pause]  × N entries
//   Audible sounds:  4 and 5 (used by Find My's default "beep" sequence)
enum SoundSequence: String, CaseIterable, Identifiable {
    case classic   = "Classic"
    case chirp     = "Chirp"
    case repeated  = "Repeated"
    case insistent = "Insistent"

    var id: String { rawValue }

    // Full L2CAP payload: opcode 0x28 + sequence entries
    var bytes: [UInt8] {
        switch self {
        case .classic:   return [0x28, 0x04, 0x01, 0x00, 0x00, 0x05, 0x02, 0x00, 0x00]
        case .chirp:     return [0x28, 0x04, 0x01, 0x00, 0x00]
        case .repeated:  return [0x28, 0x04, 0x05, 0x00, 0x00]
        case .insistent: return [0x28, 0x04, 0x01, 0x00, 0x00, 0x05, 0x05, 0x00, 0x00]
        }
    }

    static let stopBytes: [UInt8] = [0x08]
}

struct FoundTag: Identifiable {
    let id: String          // CBPeripheral UUID string — stable per device
    var name: String
    var rssi: Int?
    var distance: Double?
    var soundOn: Bool          = false
    var selectedSound: SoundSequence = .classic
}

final class AirTagService: NSObject, ObservableObject {

    enum State: Equatable {
        case off, scanning, ready, error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.off, .off), (.scanning, .scanning), (.ready, .ready): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }

        var label: String {
            switch self {
            case .off:          return "Bluetooth off"
            case .scanning:     return "Scanning…"
            case .ready:        return "Active"
            case .error(let s): return s
            }
        }
    }

    @Published var state: State   = .off
    @Published var tags:  [FoundTag] = []

    private var central:        CBCentralManager?
    private var peripherals:    [String: CBPeripheral]   = [:]
    private var l2capChannels:  [String: CBL2CAPChannel] = [:]
    private var pendingWrites:  [String: [UInt8]]        = [:]
    private var rssiTimers:     [String: Timer]          = [:]
    private var smoothedRSSI:   [String: Double]         = [:]
    private var fmItems:        [NSObject]               = []
    private var nameMap:        [String: String]

    // EMA factor: 0.15 gives ~6-sample lag which smooths the wild RSSI swings
    // without making the indicator feel unresponsive to real movement
    private let kEMAAlpha: Double = 0.15

    override init() {
        nameMap = (UserDefaults.standard.dictionary(forKey: kNamesKey) as? [String: String]) ?? [:]
        super.init()
    }

    // MARK: - Public API

    func start() {
        loadFindMyItems()
        central = CBCentralManager(delegate: self, queue: .main)
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
        guard let tagIdx = tags.firstIndex(where: { $0.id == tagID }) else { return }
        sendL2CAPBytes(tags[tagIdx].selectedSound.bytes, tagID: tagID)
    }

    func stopSound(tagID: String) {
        mutateTag(tagID) { $0.soundOn = false }
        pendingWrites.removeValue(forKey: tagID)
        sendL2CAPBytes(SoundSequence.stopBytes, tagID: tagID)
    }

    // MARK: - Helpers

    private func mutateTag(_ id: String, body: (inout FoundTag) -> Void) {
        guard let idx = tags.firstIndex(where: { $0.id == id }) else { return }
        body(&tags[idx])
    }

    private func toMeters(_ rssi: Int) -> Double {
        pow(10.0, (kRSSI1m - Double(rssi)) / (10.0 * kPathN))
    }

    // MARK: - L2CAP Sound

    private func sendL2CAPBytes(_ bytes: [UInt8], tagID: String) {
        if let ch = l2capChannels[tagID] {
            if ch.outputStream.hasSpaceAvailable {
                writeToChannel(ch, bytes: bytes)
            } else {
                pendingWrites[tagID] = bytes   // deliver via StreamDelegate when ready
            }
        } else if let p = peripherals[tagID] {
            pendingWrites[tagID] = bytes        // deliver via didOpen
            p.openL2CAPChannel(kAirTagPSM)
        }
    }

    private func writeToChannel(_ ch: CBL2CAPChannel, bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return }
            _ = ch.outputStream.write(base, maxLength: $0.count)
        }
    }

    // MARK: - FindMy Private Framework (names only)

    private func loadFindMyItems() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/FindMy.framework"),
              bundle.load() else { return }

        let dbClasses  = ["FMFAItemDatabase", "FMFABeaconDatabase",
                          "FMFAAccessoryDatabase", "FMFADatabase"]
        let sharedSels = ["sharedDatabase", "sharedInstance", "shared", "defaultDatabase"]
        let itemsSels  = ["items", "allItems", "accessories", "allAccessories",
                          "beacons", "allBeacons"]

        outer: for className in dbClasses {
            guard let cls = NSClassFromString(className) as? NSObject.Type else { continue }
            for sharedSel in sharedSels {
                guard let db = cls.perform(NSSelectorFromString(sharedSel))?
                                  .takeUnretainedValue() as? NSObject else { continue }
                for itemsSel in itemsSels {
                    if let list = db.perform(NSSelectorFromString(itemsSel))?
                                    .takeUnretainedValue() as? [NSObject], !list.isEmpty {
                        fmItems = list
                        break outer
                    }
                }
            }
        }
    }

    private func fmName(at index: Int) -> String? {
        guard index < fmItems.count else { return nil }
        let obj = fmItems[index]
        for sel in ["name", "displayName", "title", "localizedName"] {
            if let s = obj.perform(NSSelectorFromString(sel))?
                          .takeUnretainedValue() as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }
}

// MARK: - CBCentralManagerDelegate
extension AirTagService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { state = .off; return }
        state = .scanning
        let svcUUIDs = [kFindMyServiceUUID, kAppleNearbyUUID]
        let existing = central.retrieveConnectedPeripherals(withServices: svcUUIDs)
        existing.forEach { registerAndConnect($0) }
        if !existing.isEmpty { state = .ready }
        central.scanForPeripherals(withServices: svcUUIDs, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        registerAndConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .ready
        startRSSI(for: peripheral)
        peripheral.openL2CAPChannel(kAirTagPSM)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) { }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier.uuidString
        rssiTimers[id]?.invalidate()
        rssiTimers.removeValue(forKey: id)
        l2capChannels.removeValue(forKey: id)
        smoothedRSSI.removeValue(forKey: id)
        pendingWrites.removeValue(forKey: id)
        mutateTag(id) { t in t.rssi = nil; t.distance = nil; t.soundOn = false }
        central.connect(peripheral, options: nil)
    }

    private func registerAndConnect(_ p: CBPeripheral) {
        let id = p.identifier.uuidString
        guard peripherals[id] == nil else { return }
        peripherals[id] = p
        p.delegate = self
        let tagIndex = tags.count
        let name = nameMap[id]
                ?? fmName(at: tagIndex)
                ?? (tags.isEmpty ? "AirTag" : "AirTag \(tagIndex + 1)")
        tags.append(FoundTag(id: id, name: name))
        central?.connect(p, options: nil)
    }

    private func startRSSI(for p: CBPeripheral) {
        let id = p.identifier.uuidString
        rssiTimers[id]?.invalidate()
        rssiTimers[id] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            p.readRSSI()
        }
    }
}

// MARK: - CBPeripheralDelegate
extension AirTagService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue < 0 else { return }
        let id = peripheral.identifier.uuidString
        let raw = Double(RSSI.intValue)
        let ema = smoothedRSSI[id].map { kEMAAlpha * raw + (1 - kEMAAlpha) * $0 } ?? raw
        smoothedRSSI[id] = ema
        let display = Int(ema.rounded())
        mutateTag(id) { t in t.rssi = display; t.distance = toMeters(display) }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let ch = channel else { return }
        let id = peripheral.identifier.uuidString
        l2capChannels[id] = ch
        ch.inputStream.delegate  = self
        ch.outputStream.delegate = self
        ch.inputStream.schedule(in: .main, forMode: .common)
        ch.outputStream.schedule(in: .main, forMode: .common)
        ch.inputStream.open()
        ch.outputStream.open()
        // If the stream is immediately ready, flush any pending write now;
        // otherwise StreamDelegate will fire .hasSpaceAvailable and flush it
        if ch.outputStream.hasSpaceAvailable, let bytes = pendingWrites.removeValue(forKey: id) {
            writeToChannel(ch, bytes: bytes)
        }
    }
}

// MARK: - StreamDelegate (L2CAP output stream ready)
extension AirTagService: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard eventCode.contains(.hasSpaceAvailable) else { return }
        guard let (id, ch) = l2capChannels.first(where: { $0.value.outputStream === aStream }),
              let bytes = pendingWrites.removeValue(forKey: id) else { return }
        writeToChannel(ch, bytes: bytes)
    }
}
