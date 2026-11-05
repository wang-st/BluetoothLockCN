import Foundation

// CoreBluetooth cannot construct peripherals without hardware. These doubles replace
// only the OS boundary; the tests compile and call the production BLEManager directly.
protocol CBCentralManagerDelegate: AnyObject {}
protocol CBPeripheralDelegate: AnyObject {}
enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }

final class CBPeripheral {
    let identifier = UUID()
    var name: String? = "Test phone"
    var state = CBPeripheralState.disconnected
    weak var delegate: CBPeripheralDelegate?
    var rssi: Int32 = -50
    var reads = 0

    func readRSSI() {
        reads += 1
        (delegate as? BLEManager)?.peripheral(self, didReadRSSI: NSNumber(value: rssi), error: nil)
    }
}

final class CBCentralManager {
    static var latest: CBCentralManager!
    var state = CBManagerState.poweredOn
    var cached: [CBPeripheral] = []
    var connections: [CBPeripheral] = []
    var cancellations = 0

    init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?) { Self.latest = self }
    func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] {
        cached.filter { ids.contains($0.identifier) }
    }
    func connect(_ peripheral: CBPeripheral) {
        connections.append(peripheral)
        peripheral.state = .connecting
    }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancellations += 1 }
    func scanForPeripherals(withServices: [UUID]?, options: [String: Any]?) {}
    func stopScan() {}
}

@main
struct BLERecoveryTests {
    static func main() {
        // Avoid reading or changing the app's saved selection.
        UserDefaults.standard.removeObject(forKey: Prefs.deviceUUIDKey)
        UserDefaults.standard.removeObject(forKey: Prefs.deviceNameKey)
        let manager = BLEManager()
        let central = CBCentralManager.latest!
        let phone = CBPeripheral()
        var samples: [Int32] = []
        manager.onRSSI = { samples.append($0) }
        manager.select(phone, persist: false)
        phone.state = .connected
        manager.centralManager(central, didConnect: phone)
        require(samples == [-50], "initial connection must read RSSI")

        // Captured trace: poweredOff stops polling without a disconnect callback;
        // poweredOn follows while BLEManager still retains the disconnected phone.
        phone.state = .disconnected
        central.state = .poweredOff
        manager.centralManagerDidUpdateState(central)
        central.state = .poweredOn
        manager.centralManagerDidUpdateState(central)
        require(central.connections.count == 2,
                "wake must reconnect the retained phone without pressing Scan")
        require(central.connections.last === phone, "reconnect the selected phone")

        phone.rssi = -43
        phone.state = .connected
        manager.centralManager(central, didConnect: phone)
        require(samples.last == -43, "wake must publish a fresh sample")
        manager.setPollInterval(0.01)
        phone.rssi = -61
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        require(samples.last == -61, "RSSI must keep refreshing after wake")
        manager.pausePolling()

        // A repeated poweredOn notification must not interrupt an existing connection.
        let attempts = central.connections.count
        let cancellations = central.cancellations
        manager.centralManagerDidUpdateState(central)
        require(central.connections.count == attempts, "do not reconnect a connected phone")
        require(central.cancellations == cancellations, "do not cancel a healthy connection")

        phone.state = .connecting
        manager.centralManagerDidUpdateState(central)
        require(central.connections.count == attempts, "do not duplicate an in-flight connection")

        manager.disconnectSelected()
        manager.centralManagerDidUpdateState(central)
        require(central.connections.count == attempts, "do not restore a cleared selection")
        print("PASS: sleep -> Bluetooth off -> wake -> reconnect -> continuous fresh RSSI")
    }

    static func require(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }
}
