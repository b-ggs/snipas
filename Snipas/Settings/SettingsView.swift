import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.target) private var target = "en"
    @AppStorage(SettingsKey.sources) private var sources = "lt"
    @AppStorage(SettingsKey.engine) private var engine = Engine.claude.rawValue
    @AppStorage(SettingsKey.claudeModel) private var claudeModel = "haiku"
    @AppStorage(SettingsKey.codexModel) private var codexModel = ""
    @AppStorage(SettingsKey.claudePath) private var claudePath = ""
    @AppStorage(SettingsKey.codexPath) private var codexPath = ""
    @AppStorage(SettingsKey.timeout) private var timeout = 90.0

    @State private var testOutput = ""
    @State private var testing = false
    @State private var hasPermission = Permissions.hasScreenRecording
    @State private var hasAX = AccessibilityText.isTrusted

    private var sourceCodes: [String] { sources.split(separator: ",").map(String.init) }

    var body: some View {
        Form {
            Section("Languages") {
                Picker("Translate into", selection: $target) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Likely source languages")
                    Text("Used to steer text recognition and to resolve ambiguous text (e.g. Lithuanian that looks like Czech). Text in any other language is still translated.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !sourceCodes.isEmpty {
                        Text("Priority: " + sourceCodes.map(Language.name(for:)).joined(separator: " → "))
                            .font(.caption)
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                            ForEach(Language.all.filter { $0.code != target }) { lang in
                                Toggle(lang.name, isOn: binding(for: lang.code))
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }

            Section("Translation engine") {
                Picker("Engine", selection: $engine) {
                    ForEach(Engine.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if engine == Engine.claude.rawValue {
                    TextField("Model", text: $claudeModel, prompt: Text("haiku, sonnet, opus…"))
                    TextField("claude path", text: $claudePath, prompt: Text(CLIRunner.resolve("claude", override: "") ?? "auto-detect"))
                } else {
                    TextField("Model", text: $codexModel, prompt: Text("default"))
                    TextField("codex path", text: $codexPath, prompt: Text(CLIRunner.resolve("codex", override: "") ?? "auto-detect"))
                }
                Stepper("Timeout: \(Int(timeout)) s", value: $timeout, in: 15...600, step: 15)
                HStack {
                    Button(testing ? "Testing…" : "Test engine") { test() }.disabled(testing)
                    Text(testOutput).font(.caption).textSelection(.enabled).lineLimit(4)
                }
            }

            Section("Permissions & shortcuts") {
                HStack {
                    Label(hasPermission ? "Screen Recording granted" : "Screen Recording not granted",
                          systemImage: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasPermission ? .green : .orange)
                    Spacer()
                    if !hasPermission {
                        Button("Open System Settings") { Permissions.openScreenRecordingSettings() }
                    }
                }
                HStack {
                    Label(hasAX ? "Accessibility granted — exact text from apps" : "Accessibility not granted — OCR only",
                          systemImage: hasAX ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasAX ? .green : .orange)
                    Spacer()
                    if !hasAX {
                        Button("Open System Settings") { AccessibilityText.requestTrust(); AccessibilityText.openSettings() }
                    }
                }
                Text("With Accessibility, recognized text is replaced by the apps' real text, so diacritics (ė, į, ų, ū…) are exact. Images, video and games still use OCR.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(AppState.translateShortcut) drag to select an area to translate (again to start a new one) · \(AppState.toggleShortcut) hide/show overlays · Esc dismiss · the status bar under a selection shows source → target and has “Use image” to let the AI read the selection image · hover a box to see the original · click to copy translation, ⌥-click to copy original")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear { hasPermission = Permissions.hasScreenRecording; hasAX = AccessibilityText.isTrusted }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { sourceCodes.contains(code) },
            set: { on in
                var codes = sourceCodes.filter { $0 != code }
                if on { codes.append(code) }
                sources = codes.joined(separator: ",")
            })
    }

    private func test() {
        testing = true
        testOutput = ""
        let settings = AppSettings.current()
        let sample = settings.sources.first == "lt" || settings.sources.isEmpty
            ? "Labas rytas! Prisijungti prie paskyros"
            : "Bonjour tout le monde"
        Task {
            let start = Date()
            do {
                let r = try await settings.makeTranslator()
                    .translate([TranslationItem(id: 0, text: sample)], context: settings.context)
                testOutput = "“\(sample)” → “\(r.results[0]?.text ?? "?")” (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)"
            } catch {
                testOutput = error.localizedDescription
            }
            testing = false
        }
    }
}
