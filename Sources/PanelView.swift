import SwiftUI
import Combine
import AppKit

// MARK: - 面板数据模型（供 SwiftUI 观察）

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let name: String
}

final class PanelModel: ObservableObject {
    @Published var language = Prefs.language
    @Published var monitoring = false
    @Published var bleReady = false
    @Published var bleStateText = ""
    @Published var connected = false
    @Published var deviceName: String?
    @Published var selectedDeviceID: UUID?
    @Published var discovered: [DiscoveredDevice] = []
    @Published var scanning = false
    @Published var smoothed: Double = -127
    @Published var hasSignal = false
    @Published var isAway = false
    @Published var pendingLock = false
    @Published var threshold = -70
    @Published var delaySec = 3
    @Published var activitySuppression = true
    @Published var launchAtLogin = false
}

// MARK: - 面板动作回调

struct PanelActions {
    var onToggleMonitoring: () -> Void = {}
    var onScan: () -> Void = {}
    var onSelectDevice: (UUID) -> Void = { _ in }
    var onClearDevice: () -> Void = {}
    var onThreshold: (Int) -> Void = { _ in }
    var onDelay: (Int) -> Void = { _ in }
    var onActivityToggle: (Bool) -> Void = { _ in }
    var onLaunchToggle: (Bool) -> Void = { _ in }
    var onLanguage: (AppLanguage) -> Void = { _ in }
    var onLock: () -> Void = {}
    var onQuit: () -> Void = {}
}

// MARK: - 主面板视图

struct PanelView: View {
    static let size = NSSize(width: 360, height: 700)

    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var colorScheme
    let actions: PanelActions

    private var language: AppLanguage { model.language }

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.85, blue: 0.73)
            : Color(red: 0.06, green: 0.46, blue: 0.38)
    }
    private var cardColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.65 : 0.88)
    }
    private var normalized: Double {
        max(0, min(1, (model.smoothed + 100) / 70))
    }
    private var thresholdNorm: Double {
        max(0, min(1, (Double(model.threshold) + 100) / 70))
    }
    private var bars: Int {
        model.hasSignal ? min(5, max(1, Int(normalized * 5.4))) : 0
    }
    private var statusInfo: (text: String, color: Color) {
        if !model.bleReady { return (language.text("蓝牙未就绪", "Bluetooth unavailable"), .secondary) }
        if model.deviceName == nil { return (language.text("等待选择设备", "Choose a device"), .secondary) }
        if !model.monitoring { return (language.text("监控已暂停", "Monitoring paused"), .secondary) }
        if model.pendingLock { return (language.text("使用中 · 暂缓锁屏", "In use · Lock deferred"), .orange) }
        if model.isAway { return (language.text("设备已离开", "Device away"), .red) }
        if !model.connected { return (language.text("正在重新连接", "Reconnecting"), .orange) }
        if !model.hasSignal { return (language.text("正在获取信号", "Waiting for signal"), .secondary) }
        return (language.text("设备在附近", "Device nearby"), accent)
    }
    private var signalColor: Color {
        if model.isAway { return .red }
        if model.pendingLock { return .orange }
        if !model.hasSignal { return .secondary }
        return accent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    signalSection
                    deviceSection
                    settingsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .background(ScrollbarHider())
            }
            .scrollIndicators(.hidden)
            footer
        }
        .font(.system(size: 12))
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("蓝牙感应锁", "Bluetooth Lock"))
                    .font(.system(size: 16, weight: .semibold))
                Text(language.text("离开时，自动守护你的 Mac", "Locks your Mac when you step away"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(language.text("开启监控", "Enable monitoring"), isOn: Binding(
                get: { model.monitoring },
                set: { _ in actions.onToggleMonitoring() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(model.monitoring ? language.text("暂停自动锁屏监控", "Pause automatic locking") : language.text("开启自动锁屏监控", "Enable automatic locking"))
        }
        .padding(18)
    }

    private var signalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(language.text("实时信号", "Live signal"), systemImage: "wave.3.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                statusCapsule
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(model.hasSignal ? "\(Int(model.smoothed))" : "—")
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                            .tracking(-2)
                            .monospacedDigit()
                        Text("dBm")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(model.deviceName ?? language.text("选择设备后开始感应", "Choose a device to get started"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.deviceName ?? language.text("选择设备后开始感应", "Choose a device to get started"))
                }
                Spacer(minLength: 12)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .fill(i < bars ? signalColor : accent.opacity(0.12))
                            .frame(width: 7, height: CGFloat(12 + i * 7))
                    }
                }
                .frame(width: 70, height: 60)
                .accessibilityHidden(true)
            }

            VStack(spacing: 9) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.1))
                        Capsule()
                            .fill(LinearGradient(colors: [accent.opacity(0.4), accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * (model.hasSignal ? normalized : 0))
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: 3, height: 14)
                            .position(x: geo.size.width * thresholdNorm, y: 4)
                        if model.hasSignal {
                            Circle()
                                .fill(signalColor)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(cardColor, lineWidth: 2))
                                .position(x: max(6, min(geo.size.width - 6, geo.size.width * normalized)), y: 4)
                        }
                    }
                }
                .frame(height: 8)
                .accessibilityLabel(language.text("锁定阈值 \(model.threshold) dBm", "Lock threshold \(model.threshold) dBm"))
                HStack {
                    Text(language.text("弱", "Weak"))
                    Spacer()
                    Text(language.text("锁定阈值 \(model.threshold) dBm", "Lock threshold \(model.threshold) dBm"))
                        .monospacedDigit()
                    Spacer()
                    Text(language.text("强", "Strong"))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.09), accent.opacity(0.01)],
                                             startPoint: .topTrailing, endPoint: .bottomLeading))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.15), lineWidth: 1)
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 5) {
            Circle().fill(statusInfo.color).frame(width: 5, height: 5)
            Text(statusInfo.text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusInfo.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(statusInfo.color.opacity(0.1), in: Capsule())
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(language.text("监控设备", "Monitored device"), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.mini)
                }
                Button(action: actions.onScan) {
                    Label(model.scanning ? language.text("停止", "Stop") : language.text("扫描", "Scan"), systemImage: model.scanning ? "stop.fill" : "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .background(accent.opacity(0.08), in: Capsule())
                .disabled(!model.bleReady)
            }

            if !model.bleReady {
                Text(model.bleStateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.discovered.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: model.scanning ? "dot.radiowaves.left.and.right" : "sensor.tag.radiowaves.forward")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(accent.opacity(0.7))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.scanning ? language.text("正在寻找附近设备", "Looking for nearby devices") : language.text("暂无扫描结果", "No devices found"))
                            .font(.system(size: 11, weight: .medium))
                        Text(model.scanning ? language.text("请将蓝牙设备放在 Mac 附近", "Keep your Bluetooth device near your Mac") : language.text("点击扫描，选择要感应的蓝牙设备", "Scan to choose a Bluetooth device"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            if !model.discovered.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.discovered) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        let selected = model.selectedDeviceID == device.id
        return Button {
            actions.onSelectDevice(device.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? accent : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(selected ? accent.opacity(0.1) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                Text(device.name)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if selected {
                    Text(language.text("已选择", "Selected"))
                        .font(.system(size: 10))
                        .foregroundStyle(accent)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                }
            }
            .padding(8)
            .background(selected ? accent.opacity(0.07) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(device.name)
        .accessibilityValue(selected ? language.text("已选择", "Selected") : language.text("未选择", "Not selected"))
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(language.text("自动锁屏", "Auto lock"), systemImage: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))

            VStack(spacing: 5) {
                HStack {
                    Text(language.text("信号阈值", "Signal threshold"))
                    Spacer()
                    Text("\(model.threshold) dBm")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.08), in: Capsule())
                }
                Slider(value: Binding(
                    get: { Double(model.threshold) },
                    set: { actions.onThreshold(Int($0)) }
                ), in: -100...(-30), step: 1)
                .accessibilityLabel(language.text("锁定信号阈值", "Lock signal threshold"))
                HStack {
                    Text(language.text("更远时锁屏", "Lock farther away"))
                    Spacer()
                    Text(language.text("更近时锁屏", "Lock closer"))
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(language.text("离开延迟", "Lock delay"))
                Spacer(minLength: 0)
                Picker(language.text("离开延迟", "Lock delay"), selection: Binding(
                    get: { model.delaySec },
                    set: { actions.onDelay($0) }
                )) {
                    ForEach([1, 3, 5, 10, 15], id: \.self) { Text(language.text("\($0)秒", "\($0)s")).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 218)
                .controlSize(.small)
            }

            Divider().opacity(0.5)

            Toggle(isOn: Binding(
                get: { model.activitySuppression },
                set: { actions.onActivityToggle($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("使用电脑时暂缓锁屏", "Defer locking while in use"))
                    Text(language.text("鼠标键盘操作结束后再锁屏", "Wait until mouse and keyboard are idle"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { actions.onLaunchToggle($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("开机自动启动", "Launch at login"))
                    Text(language.text("登录后在菜单栏安静运行", "Run in the menu bar when you sign in"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider().opacity(0.5)

            HStack {
                Label("语言 / Language", systemImage: "globe")
                Spacer()
                Picker("语言 / Language", selection: Binding(
                    get: { model.language },
                    set: { actions.onLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: actions.onLock) {
                Label(language.text("立即锁屏", "Lock now"), systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white)
            .background(accent, in: RoundedRectangle(cornerRadius: 10))

            Button(action: actions.onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 36, height: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .help(language.text("退出蓝牙感应锁", "Quit Bluetooth Lock"))
            .accessibilityLabel(language.text("退出蓝牙感应锁", "Quit Bluetooth Lock"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cardColor.opacity(0.6))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - 彻底隐藏滚动条
// macOS 系统设置"始终显示滚动条"时 SwiftUI 的 .scrollIndicators(.hidden) 不生效，
// 此处穿透到 SwiftUI 底层的 NSScrollView 直接关闭 scroller
struct ScrollbarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            var current = view?.superview
            while let v = current {
                if let scrollView = v as? NSScrollView {
                    scrollView.hasVerticalScroller = false
                    scrollView.hasHorizontalScroller = false
                    scrollView.scrollerStyle = .overlay
                    break
                }
                current = v.superview
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
