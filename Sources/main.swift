import AppKit

// 蓝牙感应锁 — 入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 菜单栏应用，无 Dock 图标
app.run()
