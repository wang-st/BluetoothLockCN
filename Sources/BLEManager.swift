import Foundation
import CoreBluetooth

// 蓝牙设备扫描、连接与 RSSI 轮询
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    var onStateChange: (() -> Void)?
    var onRSSI: ((Int32) -> Void)?
    var onDeviceListChanged: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pollTimer: Timer?
    private var scanTimer: Timer?

    private(set) var discovered: [CBPeripheral] = []
    private(set) var isScanning = false
    private var savedIdentifier: UUID?
    private var savedName: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        if let s = UserDefaults.standard.string(forKey: Prefs.deviceUUIDKey) {
            savedIdentifier = UUID(uuidString: s)
        }
        savedName = UserDefaults.standard.string(forKey: Prefs.deviceNameKey)
    }

    // MARK: - 状态

    var isReady: Bool { central.state == .poweredOn }
    var isConnected: Bool { peripheral?.state == .connected }

    var selectedIdentifier: UUID? { peripheral?.identifier ?? savedIdentifier }
    var selectedName: String? { peripheral?.name ?? savedName }

    var stateText: String {
        switch central.state {
        case .poweredOn: return Prefs.language.text("蓝牙已开启", "Bluetooth is on")
        case .poweredOff: return Prefs.language.text("蓝牙已关闭", "Bluetooth is off")
        case .unauthorized: return Prefs.language.text("蓝牙权限未授权（系统设置 → 隐私与安全性 → 蓝牙）", "Bluetooth access is denied (System Settings → Privacy & Security → Bluetooth)")
        case .unsupported: return Prefs.language.text("本机不支持低功耗蓝牙", "This Mac does not support Bluetooth Low Energy")
        case .unknown, .resetting: return Prefs.language.text("蓝牙初始化中…", "Initializing Bluetooth…")
        @unknown default: return Prefs.language.text("蓝牙状态未知", "Unknown Bluetooth state")
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if let p = peripheral {
                // 睡眠关闭蓝牙时不一定回调 didDisconnect，唤醒后需恢复仍保留的设备。
                if p.state == .disconnected { central.connect(p) }
            } else if let id = savedIdentifier,
                      let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                select(p, persist: false)
            }
        }
        if central.state != .poweredOn { stopPolling() }
        onStateChange?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name?.isEmpty == false else { return } // 只列出有名字的设备
        if !discovered.contains(where: { $0.identifier == peripheral.identifier }) {
            discovered.append(peripheral)
            onDeviceListChanged?()
        }
        // 重启后系统不记得设备时：扫描到已保存的设备自动恢复选择
        if peripheral.identifier == savedIdentifier, self.peripheral?.state != .connected {
            select(peripheral, persist: false)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        startPolling()
        onStateChange?()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onStateChange?()
        // 连接失败也要安排重试，否则设备走远一次后就永远连不上
        if peripheral.identifier == savedIdentifier, isReady {
            scheduleReconnect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        stopPolling()
        onStateChange?()
        // 自动重连被选中的设备
        if peripheral.identifier == savedIdentifier, isReady {
            scheduleReconnect(to: peripheral)
        }
    }

    /// 3 秒后重连指定设备（仍是被选中设备且蓝牙可用时）
    private func scheduleReconnect(to p: CBPeripheral) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self,
                  self.savedIdentifier == p.identifier,
                  self.isReady,
                  self.peripheral?.state != .connected else { return }
            self.central.connect(p)
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        onRSSI?(RSSI.int32Value)
    }

    // MARK: - 公开操作

    func startScan(duration: TimeInterval = 8) {
        guard isReady else { return }
        discovered.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: nil)
        onDeviceListChanged?()
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        if central.state == .poweredOn { central.stopScan() }
        // 无论蓝牙状态如何都要清除标志，否则 UI 会永远显示"扫描中"
        if isScanning {
            isScanning = false
            onDeviceListChanged?()
        }
    }

    func select(_ p: CBPeripheral, persist: Bool = true) {
        stopScan() // 选定设备后立即停止扫描，避免无谓的无线电活动
        stopPolling()
        if let old = peripheral { central.cancelPeripheralConnection(old) }
        peripheral = p
        savedIdentifier = p.identifier
        savedName = p.name
        if persist {
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Prefs.deviceUUIDKey)
            UserDefaults.standard.set(p.name, forKey: Prefs.deviceNameKey)
        }
        if isReady { central.connect(p) }
        onStateChange?()
    }

    func disconnectSelected() {
        stopPolling()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        savedIdentifier = nil
        savedName = nil
        UserDefaults.standard.removeObject(forKey: Prefs.deviceUUIDKey)
        UserDefaults.standard.removeObject(forKey: Prefs.deviceNameKey)
        onStateChange?()
    }

    // MARK: - RSSI 轮询（自适应间隔，节能）

    private var pollInterval: TimeInterval = 1.5

    /// 动态调整轮询间隔：信号远离阈值时放慢以省电，接近阈值时加快以保证响应
    func setPollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        guard pollTimer != nil else { return } // 未在轮询中则下次启动时生效
        startPolling(immediate: false)
    }

    /// 暂停监控时停止轮询
    func pausePolling() { stopPolling() }

    /// 立即读一次 RSSI，并把轮询间隔调到最快（用于屏幕刚解锁等需要即时反馈的场景）
    func refreshRSSINow() {
        setPollInterval(1.5)
        readOnce()
    }

    /// 恢复监控时重启轮询（设备已连接才有效）
    func resumePollingIfNeeded() {
        guard peripheral?.state == .connected, pollTimer == nil else { return }
        startPolling()
    }

    private func startPolling(immediate: Bool = true) {
        pollTimer?.invalidate()
        if immediate { readOnce() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.readOnce()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func readOnce() {
        guard let p = peripheral, p.state == .connected else { return }
        p.readRSSI()
    }
}
