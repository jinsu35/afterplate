import Foundation

/// The app's language, chosen in Settings. The interface follows
/// it through the String Catalog (Localizable.xcstrings: Korean source,
/// English translations) once the app is restarted — macOS picks a bundle's
/// language at launch, from AppleLanguages. Code that writes model prompts
/// or review text asks `AppLanguage.current` directly.
enum AppLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"

    static let key = "appLanguage"

    nonisolated static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "ko") ?? .korean
    }

    /// Saves the choice and tells the bundle which language to load next
    /// launch.
    static func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    var label: String { self == .korean ? "한국어" : "English" }
    var isEnglish: Bool { self == .english }
}

/// Where the app keeps what it learns. `-AfterplateDataFolder <path>` at
/// launch points a test run at a copy, leaving the real one alone.
enum AppData {
    nonisolated static let folder: URL = {
        if let path = UserDefaults.standard.string(forKey: "AfterplateDataFolder"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Afterplate", isDirectory: true)
    }()

    /// `-AfterplateNewPerson YES` at launch: no AI connected, as on a Mac
    /// the app has never run on — sign-ins, keys and the AI choice kept apart
    /// from the real ones, to see the first run.
    nonisolated static let newPerson = UserDefaults.standard.bool(forKey: "AfterplateNewPerson")

    /// Names a setting kept apart in that mode, one per data folder: two
    /// test windows side by side shared the AI choice, and one picking Grok
    /// turned the other's ChatGPT calls into Grok ones.
    nonisolated static func apart(_ name: String) -> String {
        newPerson ? "\(name)-new-person-\(folder.lastPathComponent)" : name
    }

    /// Where ChatGPT's and Grok's sign-ins are kept.
    nonisolated static var accounts: URL {
        newPerson ? folder.appendingPathComponent("accounts", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Afterplate", isDirectory: true)
    }
}
