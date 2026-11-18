import AppKit

final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private var panels: [Int: (OverlayPanel, OverlayBoxView)] = [:]
    private(set) var isHidden = false
    private var scanning: OverlayPanel?

    /// Pulsing outline over a whole region while the AI reads its image.
    func showScanning(_ rect: CGRect) {
        hideScanning()
        let panel = OverlayPanel(frame: rect)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.contentView = ScanningView(frame: NSRect(origin: .zero, size: rect.size))
        panel.orderFrontRegardless()
        scanning = panel
    }

    func hideScanning() {
        scanning?.orderOut(nil)
        (scanning?.contentView as? ScanningView)?.stop()
        scanning = nil
    }
    var onChange: (() -> Void)?

    var hasOverlays: Bool { !panels.isEmpty }
    var count: Int { panels.count }
    func contains(_ id: Int) -> Bool { panels[id] != nil }

    func show(_ blocks: [TextBlock]) {
        dismissAll()
        for block in blocks {
            let panel = OverlayPanel(frame: block.screenRect)
            let view = OverlayBoxView(block: block, frame: NSRect(origin: .zero, size: block.screenRect.size))
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            panel.orderFrontRegardless()
            panels[block.id] = (panel, view)
        }
        isHidden = false
        onChange?()
    }

    /// Adds boxes without clearing existing ones.
    func add(_ blocks: [TextBlock]) {
        for block in blocks {
            let panel = OverlayPanel(frame: block.screenRect)
            let view = OverlayBoxView(block: block, frame: NSRect(origin: .zero, size: block.screenRect.size))
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            if !isHidden { panel.orderFrontRegardless() }
            panels[block.id] = (panel, view)
        }
        onChange?()
    }

    func setTranslation(_ text: String, source: String? = nil, for id: Int) {
        guard let (panel, view) = panels[id] else { return }
        if let source { view.exactSource = source }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing changed → don't cover the original.
        if normalized.isEmpty || normalized == view.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) {
            remove(id)
            return
        }
        view.state = .translated(normalized)

        // Grow downward if the translation doesn't fit at the minimum font size.
        let r = view.block.screenRect
        let (_, needed) = OverlayBoxView.layout(normalized, width: r.width, height: r.height,
                                                lines: OverlayBoxView.lineCount(normalized, fallback: view.block.lineCount),
                                                color: .black)
        if needed > r.height + 1 {
            let h = min(needed, r.height * 3)
            panel.setFrame(NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h), display: true)
        }
    }

    func remove(_ id: Int) {
        guard let (panel, _) = panels.removeValue(forKey: id) else { return }
        panel.orderOut(nil)
        if panels.isEmpty { onChange?() }
    }

    func removePending() {
        for (id, (_, view)) in panels {
            if case .pending = view.state { remove(id) }
        }
    }

    func toggleHidden() {
        guard hasOverlays else { return }
        isHidden.toggle()
        for (panel, _) in panels.values {
            if isHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    func dismissAll() {
        hideScanning()
        guard !panels.isEmpty else { return }
        panels.values.forEach { $0.0.orderOut(nil) }
        panels.removeAll()
        isHidden = false
        onChange?()
    }
}

/// Animated dashed outline with a faint tint, drawn over a region being read.
final class ScanningView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.1
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    func stop() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        let pulse = 0.5 + 0.5 * sin(phase)
        NSColor.controlAccentColor.withAlphaComponent(0.04 + 0.06 * pulse).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55 + 0.35 * pulse).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: phase * 10)
        path.stroke()
    }
}
