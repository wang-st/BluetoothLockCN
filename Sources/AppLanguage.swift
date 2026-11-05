import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var displayName: String { self == .chinese ? "中文" : "English" }

    func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
}
