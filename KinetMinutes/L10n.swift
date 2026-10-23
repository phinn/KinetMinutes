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

    /// Key lookup + printf-style formatting (e.g. "%d" counts).
    static func string(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    /// 1.3: manual UI language override. Nil/"" = follow the system.
    /// Changing it needs a relaunch — static `tables` and every static button
    /// title captured at init keep the old language until then.
    static var appLanguageOverride: String? {
        get {
            let v = UserDefaults.standard.string(forKey: "AppLanguage") ?? ""
            return tables[v] != nil && !v.isEmpty ? v : nil
        }
        set {
            if let v = newValue, tables[v] != nil, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: "AppLanguage")
            } else {
                UserDefaults.standard.set("", forKey: "AppLanguage")
            }
        }
    }

    static func preferredLanguage() -> String {
        // Debug override first (screenshots), then manual choice, then system.
        if let env = ProcessInfo.processInfo.environment["KM_LANG"], tables[env] != nil { return env }
        if let user = appLanguageOverride { return user }
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
