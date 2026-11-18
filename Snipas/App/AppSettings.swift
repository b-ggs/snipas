import Foundation

enum Engine: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [Language] = [
        ("en", "English"), ("lt", "Lithuanian"), ("lv", "Latvian"), ("et", "Estonian"),
        ("pl", "Polish"), ("cs", "Czech"), ("sk", "Slovak"), ("ru", "Russian"),
        ("uk", "Ukrainian"), ("de", "German"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"),
        ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("hu", "Hungarian"),
        ("ro", "Romanian"), ("tr", "Turkish"), ("el", "Greek"), ("ar", "Arabic"),
        ("he", "Hebrew"), ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"),
        ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"),
    ].map { Language(code: $0.0, name: $0.1) }

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name
            ?? Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}

/// UserDefaults keys + a value snapshot used by the pipeline.
enum SettingsKey {
    static let target = "targetLanguage"
    static let sources = "sourceLanguages"   // comma-separated codes, in priority order
    static let engine = "engine"
    static let claudeModel = "claudeModel"
    static let codexModel = "codexModel"
    static let claudePath = "claudePath"
    static let codexPath = "codexPath"
    static let timeout = "timeoutSeconds"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            target: "en",
            sources: "lt",
            engine: Engine.claude.rawValue,
            claudeModel: "haiku",
            codexModel: "",
            claudePath: "",
            codexPath: "",
            timeout: 90.0,
        ])
    }
}

struct AppSettings {
    var target: String
    var sources: [String]
    var engine: Engine
    var claudeModel: String
    var codexModel: String
    var claudePath: String
    var codexPath: String
    var timeout: TimeInterval

    static func current() -> AppSettings {
        let d = UserDefaults.standard
        return AppSettings(
            target: d.string(forKey: SettingsKey.target) ?? "en",
            sources: (d.string(forKey: SettingsKey.sources) ?? "")
                .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            engine: Engine(rawValue: d.string(forKey: SettingsKey.engine) ?? "") ?? .claude,
            claudeModel: d.string(forKey: SettingsKey.claudeModel) ?? "",
            codexModel: d.string(forKey: SettingsKey.codexModel) ?? "",
            claudePath: d.string(forKey: SettingsKey.claudePath) ?? "",
            codexPath: d.string(forKey: SettingsKey.codexPath) ?? "",
            timeout: max(10, d.double(forKey: SettingsKey.timeout))
        )
    }

    var context: TranslationContext {
        TranslationContext(targetName: Language.name(for: target),
                           sourceNames: sources.map(Language.name(for:)))
    }

    func makeTranslator() -> Translator {
        switch engine {
        case .claude: return ClaudeCLITranslator(pathOverride: claudePath, model: claudeModel, timeout: timeout)
        case .codex: return CodexCLITranslator(pathOverride: codexPath, model: codexModel, timeout: timeout)
        }
    }
}
