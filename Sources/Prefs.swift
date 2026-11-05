import Foundation

// 偏好设置（UserDefaults 持久化）
enum Prefs {
    static let deviceUUIDKey = "deviceUUID"
    static let deviceNameKey = "deviceName"

    static var language: AppLanguage {
        get {
            AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .chinese
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    static var threshold: Int {
        get { UserDefaults.standard.object(forKey: "threshold") as? Int ?? -70 }
        set { UserDefaults.standard.set(newValue, forKey: "threshold") }
    }

    static var delaySec: Int {
        get { UserDefaults.standard.object(forKey: "delaySec") as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: "delaySec") }
    }

    static var monitoring: Bool {
        get { UserDefaults.standard.bool(forKey: "monitoring") }
        set { UserDefaults.standard.set(newValue, forKey: "monitoring") }
    }

    /// 使用电脑时暂缓锁屏（活动监测），默认开启
    static var activitySuppression: Bool {
        get { UserDefaults.standard.object(forKey: "activitySuppression") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "activitySuppression") }
    }
}
