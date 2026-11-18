import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.setUp() }
    }
}

@main
struct SnipasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            Image(systemName: state.isRunning ? "ellipsis.bubble.fill" : "character.bubble")
        }
        Settings {
            SettingsView()
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.engine) private var engine = Engine.claude.rawValue
    @AppStorage(SettingsKey.target) private var target = "en"
    @AppStorage(SettingsKey.sources) private var sources = "lt"

    var body: some View {
        Button("Translate Selection…  (\(AppState.translateShortcut))") { state.translateSelection() }
            .disabled(state.isRunning)
        Button("Translate All Screens") { state.translateAllScreens() }
            .disabled(state.isRunning)
        Button("Clear Overlays  (Esc)") { state.clear() }
            .disabled(!state.hasOverlays && !state.isRunning)
        Button("Peek / Hide Overlays  (\(AppState.toggleShortcut))") { state.overlay.toggleHidden() }
            .disabled(!state.hasOverlays)
        Divider()
        Text("\(sourceSummary) → \(Language.name(for: target)) · \(Engine(rawValue: engine)?.displayName ?? engine)")
        Picker("Engine", selection: $engine) {
            ForEach(Engine.allCases) { Text($0.displayName).tag($0.rawValue) }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Snipas") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var sourceSummary: String {
        let codes = sources.split(separator: ",").map(String.init)
        return codes.isEmpty ? "Any" : codes.map(Language.name(for:)).joined(separator: ", ")
    }
}
