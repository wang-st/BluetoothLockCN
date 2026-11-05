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

    /// 立即锁屏（通过 ApplicationServices 私有符号 SACLockScreenImmediate，运行时动态解析）
    @discardableResult
    static func lockScreen() -> Bool {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(handle, "SACLockScreenImmediate") else {
            return false
        }
        typealias LockFn = @convention(c) () -> Void
        let fn = unsafeBitCast(sym, to: LockFn.self)
        fn()
        return true
    }
}
