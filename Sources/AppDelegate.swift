import AppKit
import CoreBluetooth
import SwiftUI
import ServiceManagement

// 自绘无边框面板：位置完全手动控制，紧贴菜单栏图标下方
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 状态机核心：蓝牙在场判定 + 锁屏决策；UI 通过 PanelModel 呈现
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let panelSize = PanelView.size

    private var statusItem: NSStatusItem!
    private var panel: PanelWindow!
    private let ble = BLEManager()
    let model = PanelModel()
    private var eventMonitors: [Any] = []

    // 信号与在场状态
    private var smoothed: Double = -127
    private var hasSignal = false
    private var lastRSSIAt: Date?
    private var belowSince: Date?
    private var awayAt: Date?
    private var connectionLostAt: Date?
    private var presenceIsAway = false
    private var pendingAwayLock = false // 设备已离开但因用户在使用而暂缓锁屏
    private var screenWasLocked = false // 用于检测"解锁瞬间"

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        ble.onStateChange = { [weak self] in self?.refresh() }
        ble.onRSSI = { [weak self] value in self?.handleRSSI(value) }
        ble.onDeviceListChanged = { [weak self] in self?.refresh() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.lockIcon()
            button.action = #selector(statusItemClicked(_:))
            button.target = self
        }

        panel = makePanel()

        if Prefs.monitoring {
            Notifier.requestAuthorization()
        }
        installCloseMonitors()
        startHousekeeping()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ble.stopScan()
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    // MARK: - 状态栏与弹出面板

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            hidePanel()
            return
        }
        // 首次打开且无设备时自动扫描
        if ble.isReady, ble.selectedIdentifier == nil,
           ble.discovered.isEmpty, !ble.isScanning {
            ble.startScan()
        }
        showPanel()
    }

    // MARK: - 自绘面板的创建 / 定位 / 显隐

    private func makePanel() -> PanelWindow {
        let newPanel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.hasShadow = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hidesOnDeactivate = false
        newPanel.animationBehavior = .utilityWindow

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.masksToBounds = true

        // 毛玻璃背景（跟随系统深浅色）
        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        let hosting = NSHostingView(rootView: PanelView(model: model, actions: makeActions()))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        newPanel.contentView = container
        return newPanel
    }

    /// 精确定位：面板水平居中于菜单栏图标，顶部紧贴菜单栏下缘
    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // 计算图标在屏幕坐标系中的位置
        let buttonFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame

        var x = buttonFrame.midX - panelSize.width / 2
        x = max(visible.minX + 6, min(x, visible.maxX - panelSize.width - 6))
        let y = visible.maxY - panelSize.height // visibleFrame.maxY 即菜单栏下缘

        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
                       display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().alphaValue = 1
        })
    }

    private func hidePanel() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    /// 菜单栏锁形模板图标（跟随菜单栏深浅色自动变色）
    static func lockIcon() -> NSImage? {
        guard let img = NSImage(named: "LockTemplate") else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    /// 菜单栏组合图标：锁形在前 + 4 格信号条在后（模板图，深浅色自适应）
    static func combinedIcon(level: Int) -> NSImage? {
        guard let lock = NSImage(named: "LockTemplate") else { return nil }
        let n = max(1, min(4, level))
        let barWidth: CGFloat = 2.5, gap: CGFloat = 1.5
        let heights: [CGFloat] = [4, 7, 10, 13]
        let barsWidth = CGFloat(n) * barWidth + CGFloat(n - 1) * gap
        let lockW: CGFloat = 13, gapAfterLock: CGFloat = 3
        let canvasH: CGFloat = 16
        let img = NSImage(size: NSSize(width: lockW + gapAfterLock + barsWidth, height: canvasH))
        img.lockFocus()
        // 锁形（保持源图 768:896 纵横比）
        let aspect: CGFloat = 896.0 / 768.0
        let drawH: CGFloat = 15
        let drawW = min(lockW, drawH / aspect)
        lock.draw(in: NSRect(x: 0, y: (canvasH - drawH) / 2, width: drawW, height: drawH))
        // 信号条（底部对齐）
        NSColor.black.setFill()
        for i in 0..<n {
            let rect = NSRect(x: lockW + gapAfterLock + CGFloat(i) * (barWidth + gap), y: 1,
                              width: barWidth, height: heights[i])
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// 菜单栏图标：监控中显示 🔒 + 4 格信号条（格数不变不刷新，避免视觉跳动）；
    /// 离开锁屏显示纯锁形+"已锁"；其余状态显示纯锁形
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let away = Prefs.monitoring && presenceIsAway
        if Prefs.monitoring, hasSignal, !away {
            // 信号映射：阈值-20dBm → 1 格，阈值+30dBm → 4 格，线性分档
            let t = (smoothed - Double(Prefs.threshold) + 20) / 50
            let level = max(1, min(4, Int(ceil(t * 4))))
            button.image = Self.combinedIcon(level: level)
            button.title = ""
        } else {
            button.image = Self.lockIcon()
            button.title = away ? " 已锁" : ""
        }
    }

    /// 兜底：点击面板以外任意位置立即关闭
    private func installCloseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }
            let statusWindow = self.statusItem.button?.window
            // 面板内部与状态栏图标的点击放行（图标由按钮 action 处理开合）
            if event.window === self.panel || event.window === statusWindow { return event }
            self.hidePanel()
            return event
        })
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            if let self = self, self.panel.isVisible {
                self.hidePanel()
            }
        })
        if let localMonitor = localMonitor { eventMonitors.append(localMonitor) }
        if let globalMonitor = globalMonitor { eventMonitors.append(globalMonitor) }
    }

    /// 将内部状态同步到 SwiftUI 面板模型
    private func syncModel() {
        model.monitoring = Prefs.monitoring
        model.bleReady = ble.isReady
        model.bleStateText = ble.stateText
        model.connected = ble.isConnected
        model.deviceName = ble.selectedName
        model.selectedDeviceID = ble.selectedIdentifier
        model.discovered = ble.discovered.compactMap { p in
            p.name.map { DiscoveredDevice(id: p.identifier, name: $0) }
        }
        model.scanning = ble.isScanning
        model.smoothed = smoothed
        model.hasSignal = hasSignal
        model.isAway = presenceIsAway
        model.pendingLock = pendingAwayLock
        model.threshold = Prefs.threshold
        model.delaySec = Prefs.delaySec
        model.activitySuppression = Prefs.activitySuppression
        model.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func refresh() {
        syncModel()
        updateStatusIcon()
    }

    // MARK: - RSSI 处理与在场状态机

    private func handleRSSI(_ value: Int32) {
        guard value < 0 else { return } // 过滤无效读数
        // 长时间无读数后（如断连重连），旧值已不代表当前信号，直接重置而非平滑拖尾
        if hasSignal, let last = lastRSSIAt, Date().timeIntervalSince(last) <= 30 {
            smoothed = smoothed * 0.5 + Double(value) * 0.5
        } else {
            smoothed = Double(value)
        }
        hasSignal = true
        lastRSSIAt = Date()

        guard Prefs.monitoring, ble.isReady else {
            refresh()
            return
        }

        // 自适应轮询间隔（节能）：信号远离阈值 → 6 秒一次；临近阈值 → 1.5 秒一次
        let distance = smoothed - Double(Prefs.threshold)
        let interval: TimeInterval
        switch distance {
        case ..<8:   interval = 1.5
        case 8..<15: interval = 3.0
        default:     interval = 6.0
        }
        ble.setPollInterval(interval)

        let now = Date()
        let threshold = Double(Prefs.threshold)

        if smoothed < threshold {
            if belowSince == nil { belowSince = now }
            if !presenceIsAway, let since = belowSince,
               now.timeIntervalSince(since) >= Double(Prefs.delaySec) {
                requestAwayLock(reason: "设备已离开信号范围")
            }
        } else {
            belowSince = nil
            pendingAwayLock = false
            if presenceIsAway {
                presenceIsAway = false
                if let away = awayAt, now.timeIntervalSince(away) >= 5 {
                    Notifier.send(title: "蓝牙感应锁",
                                  body: "设备已回到附近（信号 \(Int(smoothed)) dBm）")
                }
                awayAt = nil
            }
        }
        refresh()
    }

    /// 请求执行"离开→锁屏"；若活动监测开启且用户正在使用电脑，则暂缓到空闲时执行
    private func requestAwayLock(reason: String) {
        if Prefs.activitySuppression && ActivityMonitor.isUserActive() {
            pendingAwayLock = true
            refresh()
        } else {
            pendingAwayLock = false
            markAwayLocked(reason: reason)
        }
    }

    /// 离开 → 锁屏（若尚未锁屏）
    private func markAwayLocked(reason: String) {
        presenceIsAway = true
        pendingAwayLock = false
        belowSince = nil
        awayAt = Date()
        if !LockController.isScreenLocked() {
            if LockController.lockScreen() {
                Notifier.send(title: "蓝牙感应锁", body: "\(reason)，Mac 已自动锁屏")
            } else {
                Notifier.send(title: "蓝牙感应锁", body: "\(reason)，但自动锁屏失败，请手动锁屏")
            }
        }
        refresh()
    }

    private func resetPresence() {
        belowSince = nil
        awayAt = nil
        connectionLostAt = nil
        presenceIsAway = false
        pendingAwayLock = false
    }

    // MARK: - 信号丢失兜底（断连 / RSSI 停止更新）

    private func startHousekeeping() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.housekeeping()
        }
    }

    private func housekeeping() {
        let now = Date()

        // 解锁瞬间：能解锁说明用户本人在场，立即清除"已锁"状态并马上刷新信号
        let locked = LockController.isScreenLocked()
        if screenWasLocked, !locked {
            resetPresence()
            ble.refreshRSSINow()
        }
        screenWasLocked = locked

        guard Prefs.monitoring, ble.isReady, ble.selectedName != nil else { return }

        // 暂缓中的锁屏：等用户停止使用电脑后立即执行
        if pendingAwayLock && !presenceIsAway {
            if !ActivityMonitor.isUserActive() {
                markAwayLocked(reason: "设备已离开信号范围（已等待您停止使用电脑）")
            }
            return
        }

        if !ble.isConnected {
            // 连接断开（设备关蓝牙/走远）；蓝牙总开关关闭的情况已在 guard 排除
            if connectionLostAt == nil { connectionLostAt = now }
            if !presenceIsAway, let t = connectionLostAt,
               now.timeIntervalSince(t) >= 10 {
                requestAwayLock(reason: "设备蓝牙连接已断开超过 10 秒")
            }
        } else {
            connectionLostAt = nil
            // 连接仍在但 RSSI 长时间无更新（设备远去且未断连）
            if hasSignal, !presenceIsAway, let t = lastRSSIAt,
               now.timeIntervalSince(t) >= 10 {
                requestAwayLock(reason: "设备信号已长时间无更新")
            }
        }
    }

    // MARK: - 面板动作

    private func makeActions() -> PanelActions {
        PanelActions(
            onToggleMonitoring: { [weak self] in self?.toggleMonitoring() },
            onScan: { [weak self] in
                guard let self = self else { return }
                if self.ble.isScanning { self.ble.stopScan() } else { self.ble.startScan() }
                self.refresh()
            },
            onSelectDevice: { [weak self] id in
                guard let self = self,
                      let p = self.ble.discovered.first(where: { $0.identifier == id }) else { return }
                self.ble.select(p)
                self.resetPresence()
                self.refresh()
            },
            onClearDevice: { [weak self] in
                self?.ble.disconnectSelected()
                self?.resetPresence()
                self?.refresh()
            },
            onThreshold: { [weak self] value in
                Prefs.threshold = value
                self?.refresh()
            },
            onDelay: { [weak self] value in
                Prefs.delaySec = value
                self?.refresh()
            },
            onActivityToggle: { [weak self] value in
                Prefs.activitySuppression = value
                self?.refresh()
            },
            onLaunchToggle: { [weak self] enabled in
                self?.setLaunchAtLogin(enabled)
            },
            onLock: { LockController.lockScreen() },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    /// 开机自启（SMAppService，macOS 13+ 官方登录项机制）
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Notifier.send(title: "蓝牙感应锁",
                          body: "开机自启设置失败：\(error.localizedDescription)。建议先将应用移到「应用程序」文件夹后重试。")
        }
        refresh()
    }

    private func toggleMonitoring() {
        Prefs.monitoring.toggle()
        if Prefs.monitoring {
            Notifier.requestAuthorization()
            resetPresence()
            ble.resumePollingIfNeeded()
        } else {
            resetPresence()
            ble.pausePolling()
        }
        refresh()
    }
}
