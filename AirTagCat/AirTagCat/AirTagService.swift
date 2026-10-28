import CoreBluetooth
import Combine

private let kFindMyServiceUUID = CBUUID(string: "7DFC9000-7D1C-4951-86AA-8D9728F8D66C")
private let kAppleNearbyUUID   = CBUUID(string: "FD44")
private let kRSSI1m: Double    = -59
private let kPathN:  Double    =  2.7
private let kNamesKey          = "airtag_names_v1"

struct FoundTag: Identifiable {
    let id: String          // CBPeripheral UUID string — stable per device
    var name: String
    var rssi: Int?
    var distance: Double?
    var soundOn: Bool = false
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

    private var central:     CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    private var rssiTimers:  [String: Timer] = [:]

    // FindMy private framework items (FMFAItem objects), ordered as retrieved
    private var fmItems: [NSObject] = []
    // User-assigned names, keyed by peripheral UUID
    private var nameMap: [String: String]

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

    func playSound(tagID: String) {
        mutateTag(tagID) { $0.soundOn = true }
        triggerSound(tagID: tagID, play: true)
    }

    func stopSound(tagID: String) {
        mutateTag(tagID) { $0.soundOn = false }
        triggerSound(tagID: tagID, play: false)
    }

    // MARK: - Helpers

    private func mutateTag(_ id: String, body: (inout FoundTag) -> Void) {
        guard let idx = tags.firstIndex(where: { $0.id == id }) else { return }
        body(&tags[idx])
    }

    private func toMeters(_ rssi: Int) -> Double {
        pow(10.0, (kRSSI1m - Double(rssi)) / (10.0 * kPathN))
    }

    // MARK: - FindMy Private Framework

    private func loadFindMyItems() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/FindMy.framework"),
              bundle.load() else { return }

        // Attempt to retrieve items from the local FindMy database.
        // We try several plausible class/selector names because the private API
        // isn't documented — the app degrades gracefully if none match.
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

    // Return the FindMy-assigned name for the item at a given index, if available.
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

    // Sound via FindMy private framework (handles owner-key authentication).
    // Tries both item-level selectors and manager-level selectors with various
    // plausible names.  If none match, sound silently does nothing.
    private func triggerSound(tagID: String, play: Bool) {
        guard let tagIdx = tags.firstIndex(where: { $0.id == tagID }),
              tagIdx < fmItems.count else { return }

        let item = fmItems[tagIdx]

        // 1 — Try direct method on FMFAItem
        let itemSels: [String] = play
            ? ["requestAlertSound", "beginAlertSound", "startAlertSound",
               "playAlertSound", "alert", "beginPlaying", "play", "startPlaying"]
            : ["stopAlertSound",  "endAlertSound",   "cancelAlertSound",
               "stopPlaying",     "stop",            "endAlert", "cancelAlert"]

        for sel in itemSels {
            let s = NSSelectorFromString(sel)
            if item.responds(to: s) {
                _ = item.perform(s)
                return
            }
        }

        // 2 — Try through a manager class
        let managers   = ["FMFALocatingManager", "FMFAAlertingManager",
                          "FMFABeaconManager", "FMFAAccessoryManager"]
        let mgrShared  = ["sharedManager", "shared", "sharedInstance"]
        let playSels   = ["startAlertingItem:", "alertItem:", "startAlerting:",
                          "playAlertForItem:", "beginAlertingItem:"]
        let stopSels   = ["stopAlertingItem:",  "stopAlert:",   "endAlertForItem:",
                          "cancelAlertingItem:", "stopAlerting:"]
        let actionSels = play ? playSels : stopSels

        for className in managers {
            guard let cls = NSClassFromString(className) as? NSObject.Type else { continue }
            for sharedSel in mgrShared {
                guard let mgr = cls.perform(NSSelectorFromString(sharedSel))?
                                   .takeUnretainedValue() as? NSObject else { continue }
                for actionSel in actionSels {
                    let s = NSSelectorFromString(actionSel)
                    if mgr.responds(to: s) {
                        _ = mgr.perform(s, with: item)
                        return
                    }
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension AirTagService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { state = .off; return }
        state = .scanning
        let svcUUIDs = [kFindMyServiceUUID, kAppleNearbyUUID]
        // Grab AirTags already connected to locationd
        let existing = central.retrieveConnectedPeripherals(withServices: svcUUIDs)
        existing.forEach { registerAndConnect($0) }
        if !existing.isEmpty { state = .ready }
        // Keep scanning for any additional AirTags
        central.scanForPeripherals(withServices: svcUUIDs, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        registerAndConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .ready
        startRSSI(for: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // Will retry on next scan result
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier.uuidString
        rssiTimers[id]?.invalidate()
        rssiTimers.removeValue(forKey: id)
        mutateTag(id) { t in t.rssi = nil; t.distance = nil; t.soundOn = false }
        central.connect(peripheral, options: nil) // auto-reconnect
    }

    private func registerAndConnect(_ p: CBPeripheral) {
        let id = p.identifier.uuidString
        guard peripherals[id] == nil else { return }
        peripherals[id] = p
        p.delegate = self
        // Name priority: user-saved > FindMy index-match > fallback label
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
        let meters = toMeters(RSSI.intValue)
        mutateTag(id) { t in
            t.rssi     = RSSI.intValue
            t.distance = meters
        }
    }
}
