import CoreBluetooth
import Combine

private let kFindMyServiceUUID = CBUUID(string: "7DFC9000-7D1C-4951-86AA-8D9728F8D66C")
private let kAppleNearbyUUID   = CBUUID(string: "FD44")
private let kAirTagPSM: CBL2CAPPSM = 0x0101
private let kRSSI1m: Double    = -59
private let kPathN:  Double    =  2.7
private let kNamesKey          = "airtag_names_v1"

enum SoundSequence: String, CaseIterable, Identifiable {
    case classic   = "Classic"
    case chirp     = "Chirp"
    case repeated  = "Repeated"
    case insistent = "Insistent"

    var id: String { rawValue }

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
    let id: String
    var name: String
    var rssi: Int?
    var distance: Double?
    var soundOn: Bool                   = false
    var selectedSound: SoundSequence   = .classic
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
            case .scanning:     return "Looking for AirTags…"
            case .ready:        return "Active"
            case .error(let s): return s
            }
        }
    }

    @Published var state: State      = .off
    @Published var tags:  [FoundTag] = []

    // Verified Find My peripherals
    private var peripherals:   [String: CBPeripheral]   = [:]
    // Apple-manufacturer peripherals we connected but haven't verified yet
    private var candidates:    Set<String>              = []
    private var l2capChannels: [String: CBL2CAPChannel] = [:]
    private var pendingWrites: [String: [UInt8]]        = [:]
    private var rssiTimers:    [String: Timer]          = [:]
    private var smoothedRSSI:  [String: Double]         = [:]
    private var connectedTimer: Timer?
    private var fmItems:       [NSObject]               = []
    private var nameMap:       [String: String]
    private var central:       CBCentralManager?

    // EMA α=0.15 ≈ 6-sample smoothing; kills the 0.5 m ↔ 21 m RSSI jitter
    private let kEMAAlpha: Double = 0.15

    override init() {
        nameMap = (UserDefaults.standard.dictionary(forKey: kNamesKey) as? [String: String]) ?? [:]
        super.init()
    }

    // MARK: - Public API

    func start() {
        loadFindMyItems()
        probeDurianDevices()
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
        guard let idx = tags.firstIndex(where: { $0.id == tagID }) else { return }
        sendL2CAPBytes(tags[idx].selectedSound.bytes, tagID: tagID)
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

    // MARK: - Verified peripheral management

    /// Adds a peripheral that has been confirmed to have the Find My GATT service.
    private func addVerifiedPeripheral(_ p: CBPeripheral) {
        let id = p.identifier.uuidString
        guard peripherals[id] == nil else { return }
        peripherals[id] = p
        candidates.remove(id)
        p.delegate = self
        if !tags.contains(where: { $0.id == id }) {
            let idx  = tags.count
            let name = nameMap[id]
                    ?? fmName(at: idx)
                    ?? (idx == 0 ? "AirTag" : "AirTag \(idx + 1)")
            tags.append(FoundTag(id: id, name: name))
        }
        state = .ready
        // Connect (or re-use existing connection) to start RSSI + L2CAP
        central?.connect(p, options: nil)
    }

    /// Pulls currently-connected system peripherals that could be AirTags.
    private func checkConnectedPeripherals() {
        // Fast path: locationd performed GATT discovery and the Find My UUID is registered
        let specific = central?.retrieveConnectedPeripherals(
            withServices: [kFindMyServiceUUID, kAppleNearbyUUID]) ?? []
        specific.forEach { addVerifiedPeripheral($0) }

        // Slow path: locationd opened L2CAP directly without GATT discovery, so no
        // Find My UUID is registered. Generic services (0x1800/0x1801/0x180A) are
        // cached by the BLE stack for every connected peripheral regardless.
        let generic = central?.retrieveConnectedPeripherals(withServices: [
            CBUUID(string: "1800"),   // Generic Access   — on every BLE device
            CBUUID(string: "1801"),   // Generic Attribute — on every BLE device
            CBUUID(string: "180A"),   // Device Information — on most BLE devices
        ]) ?? []
        generic
            .filter { peripherals[$0.identifier.uuidString] == nil }  // not yet verified
            .forEach { connectCandidate($0) }
    }

    private func connectCandidate(_ p: CBPeripheral) {
        let id = p.identifier.uuidString
        guard peripherals[id] == nil, !candidates.contains(id) else { return }
        candidates.insert(id)
        p.delegate = self
        central?.connect(p, options: nil)
    }

    // MARK: - L2CAP Sound

    private func sendL2CAPBytes(_ bytes: [UInt8], tagID: String) {
        if let ch = l2capChannels[tagID] {
            if ch.outputStream.hasSpaceAvailable {
                writeToChannel(ch, bytes: bytes)
            } else {
                pendingWrites[tagID] = bytes
            }
        } else if let p = peripherals[tagID] {
            pendingWrites[tagID] = bytes
            p.openL2CAPChannel(kAirTagPSM)
        }
    }

    private func writeToChannel(_ ch: CBL2CAPChannel, bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return }
            _ = ch.outputStream.write(base, maxLength: $0.count)
        }
    }

    // MARK: - CLDurian private CoreLocation probe
    // locationd manages AirTags via CLDurianDeviceManager/CLDurianService inside its own
    // process. Those classes live in CoreLocation.framework which is loaded in every app.
    // On a jailbroken/no-sandbox device the XPC connection they make to locationd may give
    // us direct access to the already-connected CLDurianDevice objects — each wraps a
    // CBPeripheral we can hand straight to addVerifiedPeripheral().

    private func probeDurianDevices() {
        // Try all plausible manager/service class names and singleton selectors
        let classes   = ["CLDurianDeviceManager","CLDurianService","CLDurianManager","CLDurianController"]
        let sharedSel = ["sharedManager","sharedService","sharedInstance","shared","defaultManager","defaultService"]
        let deviceSel = ["devices","connectedDevices","allDevices","knownDevices","peripherals","accessories"]
        let periphSel = ["peripheral","cbPeripheral","bluetoothPeripheral","centralPeripheral"]

        for cls in classes {
            guard let c = NSClassFromString(cls) as? NSObject.Type else { continue }
            for ss in sharedSel {
                guard let mgr = c.perform(NSSelectorFromString(ss))?.takeUnretainedValue() as? NSObject else { continue }
                for ds in deviceSel {
                    guard let list = mgr.perform(NSSelectorFromString(ds))?.takeUnretainedValue() as? [NSObject],
                          !list.isEmpty else { continue }
                    for device in list {
                        for ps in periphSel {
                            if let p = device.perform(NSSelectorFromString(ps))?.takeUnretainedValue() as? CBPeripheral {
                                // Got a CBPeripheral directly from locationd's device manager
                                addVerifiedPeripheral(p)
                            }
                        }
                    }
                    return  // found the device list; stop searching
                }
            }
        }
    }

    // MARK: - FindMy Private Framework (names only)

    private func loadFindMyItems() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/FindMy.framework"),
              bundle.load() else { return }
        let dbClasses  = ["FMFAItemDatabase","FMFABeaconDatabase","FMFAAccessoryDatabase","FMFADatabase"]
        let sharedSels = ["sharedDatabase","sharedInstance","shared","defaultDatabase"]
        let itemsSels  = ["items","allItems","accessories","allAccessories","beacons","allBeacons"]
        outer: for cls in dbClasses {
            guard let c = NSClassFromString(cls) as? NSObject.Type else { continue }
            for ss in sharedSels {
                guard let db = c.perform(NSSelectorFromString(ss))?.takeUnretainedValue() as? NSObject else { continue }
                for is_ in itemsSels {
                    if let list = db.perform(NSSelectorFromString(is_))?.takeUnretainedValue() as? [NSObject], !list.isEmpty {
                        fmItems = list; break outer
                    }
                }
            }
        }
    }

    private func fmName(at index: Int) -> String? {
        guard index < fmItems.count else { return nil }
        let obj = fmItems[index]
        for sel in ["name","displayName","title","localizedName"] {
            if let s = obj.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? String, !s.isEmpty { return s }
        }
        return nil
    }
}

// MARK: - CBCentralManagerDelegate

extension AirTagService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { state = .off; return }
        state = .scanning

        // Primary: system-connected peripherals (locationd already found them)
        checkConnectedPeripherals()

        // AirTags in paired mode do NOT include the Find My UUID in their adv packets —
        // they only expose it via GATT after connecting. Scanning with nil catches them.
        // allowDuplicates:true keeps re-reporting the AirTag on each adv packet so we
        // don't miss it if the first advertisement fires before we call connect().
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        // locationd connects AirTags intermittently (every ~15 s); keep checking
        connectedTimer?.invalidate()
        connectedTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.checkConnectedPeripherals()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Filter to Apple-manufactured devices only (company ID 0x004C = [0x4C, 0x00])
        guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfr.count >= 2, mfr[0] == 0x4C, mfr[1] == 0x00 else { return }
        let id = peripheral.identifier.uuidString
        guard peripherals[id] == nil, !candidates.contains(id) else { return }
        candidates.insert(id)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        if peripherals[id] != nil {
            // Already a verified Find My device — start monitoring
            startRSSI(for: peripheral)
            peripheral.openL2CAPChannel(kAirTagPSM)
        } else {
            // Candidate from nil scan — verify it has the Find My service
            peripheral.discoverServices([kFindMyServiceUUID])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        candidates.remove(peripheral.identifier.uuidString)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier.uuidString
        rssiTimers[id]?.invalidate()
        rssiTimers.removeValue(forKey: id)
        l2capChannels.removeValue(forKey: id)
        smoothedRSSI.removeValue(forKey: id)
        pendingWrites.removeValue(forKey: id)
        mutateTag(id) { t in t.rssi = nil; t.distance = nil; t.soundOn = false }
        if peripherals[id] != nil {
            central.connect(peripheral, options: nil)   // auto-reconnect verified devices only
        }
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier.uuidString
        if error == nil,
           let svcs = peripheral.services,
           svcs.contains(where: { $0.uuid == kFindMyServiceUUID }) {
            // Confirmed Find My device
            addVerifiedPeripheral(peripheral)
        } else {
            // Not a Find My device — drop it
            candidates.remove(id)
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue < 0 else { return }
        let id  = peripheral.identifier.uuidString
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
        if ch.outputStream.hasSpaceAvailable, let bytes = pendingWrites.removeValue(forKey: id) {
            writeToChannel(ch, bytes: bytes)
        }
    }
}

// MARK: - StreamDelegate

extension AirTagService: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard eventCode.contains(.hasSpaceAvailable) else { return }
        guard let (id, ch) = l2capChannels.first(where: { $0.value.outputStream === aStream }),
              let bytes = pendingWrites.removeValue(forKey: id) else { return }
        writeToChannel(ch, bytes: bytes)
    }
}
