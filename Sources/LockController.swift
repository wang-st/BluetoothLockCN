import Foundation
import CoreGraphics
import Darwin

// 锁屏与锁屏状态检测
enum LockController {

    /// 当前会话是否处于锁屏状态
    static func isScreenLocked() -> Bool {
        guard let cfDict = CGSessionCopyCurrentDictionary() else { return false }
        let dict = cfDict as NSDictionary
        return (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// 立即锁屏（通过 login.framework 私有符号 SACLockScreenImmediate，运行时动态解析）
    // 返回值仅表示请求已提交，不代表系统已完成锁屏。
    @discardableResult
    static func lockScreen() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Void
        let fn = unsafeBitCast(sym, to: LockFn.self)
        fn()
        return true
    }
}
