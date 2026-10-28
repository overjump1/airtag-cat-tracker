import CoreBluetooth
import Combine

// AirTag GATT service UUID (Find My Network accessory service)
private let kFindMyServiceUUID = CBUUID(string: "7DFC9000-7D1C-4951-86AA-8D9728F8D66C")
// Apple Nearby service (fallback scan target)
private let kAppleNearbyUUID   = CBUUID(string: "FD44")
// AirTag L2CAP PSM for owner command channel
private let kAirTagPSM: CBL2CAPPSM = 0x0101

private let kRSSI1m: Double = -59   // calibrate: measure RSSI at exactly 1 m
private let kPathN:  Double =  2.7  // 2.0 = open air, 2.7 = indoor

final class AirTagService: NSObject, ObservableObject {

    enum State: Equatable {
        case off, scanning, connecting, ready, error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.off, .off), (.scanning, .scanning),
                 (.connecting, .connecting), (.ready, .ready): return true
            case (.error(let a), .error(let b)):               return a == b
            default: return false
            }
        }

        var label: String {
            switch self {
            case .off:          return "Bluetooth off"
            case .scanning:     return "Scanning for AirTag…"
            case .connecting:   return "Connecting…"
            case .ready:        return "AirTag connected"
            case .error(let s): return s
            }
        }
        var isReady: Bool { self == .ready }
        var isScanning: Bool { self == .scanning || self == .connecting }
    }

    @Published var state:    State   = .off
    @Published var rssi:     Int?    = nil
    @Published var distance: Double? = nil
    @Published var soundOn:  Bool    = false

    private var central:    CBCentralManager?
    private var peripheral: CBPeripheral?
    private var l2cap:      CBL2CAPChannel?
    private var rssiTimer:  Timer?

    // MARK: - Public API

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func playSound() {
        soundOn = true
        if let ch = l2cap {
            sendCommand([0x28, 0x00, 0x03, 0x00, 0x00], to: ch) // opcode 40: play sequence
        } else {
            peripheral?.openL2CAPChannel(kAirTagPSM)
        }
    }

    func stopSound() {
        soundOn = false
        if let ch = l2cap {
            sendCommand([0x08], to: ch) // opcode 8: stop sound
        }
    }

    // MARK: - Helpers

    private func sendCommand(_ bytes: [UInt8], to ch: CBL2CAPChannel) {
        let data = Data(bytes)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            ch.outputStream.write(base, maxLength: data.count)
        }
    }

    private func connectTo(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central?.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func startRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }

    private func toMeters(_ rssi: Int) -> Double {
        pow(10.0, (kRSSI1m - Double(rssi)) / (10.0 * kPathN))
    }
}

// MARK: - CBCentralManagerDelegate
extension AirTagService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            state = .off; return
        }
        // First try: grab the peripheral already connected by locationd/Find My
        let serviceUUIDs = [kFindMyServiceUUID, kAppleNearbyUUID]
        let alreadyConnected = central.retrieveConnectedPeripherals(withServices: serviceUUIDs)
        if let p = alreadyConnected.first {
            connectTo(p)
        } else {
            state = .scanning
            central.scanForPeripherals(withServices: serviceUUIDs, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        connectTo(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .ready
        startRSSIPolling()
        peripheral.openL2CAPChannel(kAirTagPSM) // best-effort; RSSI works without it
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        state = .scanning
        central.scanForPeripherals(withServices: [kFindMyServiceUUID, kAppleNearbyUUID], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        l2cap = nil
        rssi = nil; distance = nil; soundOn = false
        rssiTimer?.invalidate()
        state = .scanning
        // Auto-reconnect
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }
}

// MARK: - CBPeripheralDelegate
extension AirTagService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue < 0 else { return }
        rssi     = RSSI.intValue
        distance = toMeters(RSSI.intValue)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let ch = channel else { return } // L2CAP is optional; proximity still works
        l2cap = ch
        ch.outputStream.schedule(in: .main, forMode: .default)
        ch.outputStream.open()
        // If a play was requested before the channel opened, send it now
        if soundOn { sendCommand([0x28, 0x00, 0x03, 0x00, 0x00], to: ch) }
    }
}
