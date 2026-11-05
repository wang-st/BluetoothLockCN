import Foundation
import CoreGraphics

// 用户活动监测（无需辅助功能权限，使用公开 API）
enum ActivityMonitor {

    /// 关注的输入事件类型：鼠标移动/点击/拖拽、滚轮、键盘
    private static let watchedTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseDragged,
        .rightMouseDown, .rightMouseDragged, .otherMouseDown,
        .scrollWheel, .keyDown
    ]

    /// 距最近一次用户输入的秒数
    static func secondsSinceLastInput() -> CFTimeInterval {
        var minIdle = CFTimeInterval.greatestFiniteMagnitude
        for type in watchedTypes {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            // 负值表示该类事件从未发生（无数据），不能当作"刚刚输入"
            if idle >= 0, idle < minIdle { minIdle = idle }
        }
        return minIdle
    }

    /// 用户是否正在使用电脑（N 秒内有输入）
    static func isUserActive(within seconds: CFTimeInterval = 5) -> Bool {
        secondsSinceLastInput() < seconds
    }
}
