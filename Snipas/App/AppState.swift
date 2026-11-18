import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isRunning = false
    @Published private(set) var hasOverlays = false

    let overlay = OverlayController()
    let hud = HUD()
    let snip = SnipController()
    private(set) lazy var pipeline = TranslationPipeline(overlay: overlay, hud: hud)

    private enum HotKeyID: UInt32 { case translate = 1, toggle = 2, escape = 3 }
    static let translateShortcut = "⌃⌥T"
    static let toggleShortcut = "⌃⌥⇧T"

    func setUp() {
        SettingsKey.registerDefaults()
        pipeline.onRunningChange = { [weak self] in self?.isRunning = $0 }
        overlay.onChange = { [weak self] in self?.overlaysChanged() }
        hud.onVisibilityChange = { [weak self] _ in self?.overlaysChanged() }
        hud.onClose = { [weak self] in self?.clear() }

        let hk = HotKeyManager.shared
        hk.register(id: HotKeyID.translate.rawValue, keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.snipOrCancel()
        }
        hk.register(id: HotKeyID.toggle.rawValue, keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
            self?.overlay.toggleHidden()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }

        if !Permissions.hasScreenRecording { Permissions.requestScreenRecording() }
        // Optional: exact text (with diacritics) from apps' accessibility trees.
        if !AccessibilityText.isTrusted { AccessibilityText.requestTrust() }
    }

    /// Hotkey: cancel an in-progress snip or translation; otherwise start a new snip
    /// (replacing any overlays already shown).
    func snipOrCancel() {
        if snip.isActive || isRunning { clear() } else { translateSelection() }
    }

    /// Drag out a region, then translate just that region.
    func translateSelection() {
        clear()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        snip.begin { [weak self] rect in
            guard let self, let rect else { return }
            Task { await self.pipeline.run(region: rect, frontmostPID: front) }
        }
    }

    /// Translate everything on every display.
    func translateAllScreens() {
        clear()
        Task { await pipeline.run() }
    }

    func clear() {
        snip.cancel()
        pipeline.cancel()
        overlay.dismissAll()
        hud.hide()
    }

    private func overlaysChanged() {
        hasOverlays = overlay.hasOverlays
        // Esc dismisses, but only grab it while something of ours is on screen.
        if hasOverlays || hud.isVisible {
            HotKeyManager.shared.register(id: HotKeyID.escape.rawValue, keyCode: kVK_Escape, modifiers: 0) { [weak self] in
                self?.clear()
            }
        } else {
            HotKeyManager.shared.unregister(id: HotKeyID.escape.rawValue)
        }
    }
}
