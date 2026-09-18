// L10n.swift — lightweight four-language strings (en / ja / zh-Hans / zh-Hant)
// Keys fall back to en. Values live in this table so Review/screenshots can
// drive UI language via -AppleLanguages without .lproj file juggling.

import Foundation

enum L10n {
    private static let tables: [String: [String: String]] = load()

    static func string(_ key: String) -> String {
        let lang = preferredLanguage()
        return tables[lang]?[key] ?? tables["en"]?[key] ?? key
    }

    static func preferredLanguage() -> String {
        // Debug override first (screenshots), then user's AppleLanguages.
        if let env = ProcessInfo.processInfo.environment["KM_LANG"], tables[env] != nil { return env }
        for code in Locale.preferredLanguages {
            if code.hasPrefix("zh-Hant") || code.hasPrefix("zh-HK") || code.hasPrefix("zh-TW") { return "zh-Hant" }
            if code.hasPrefix("zh") { return "zh-Hans" }
            if code.hasPrefix("ja") { return "ja" }
            if code.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    private static func load() -> [String: [String: String]] {
        guard let url = Bundle.main.url(forResource: "L10n", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return obj
    }
}
