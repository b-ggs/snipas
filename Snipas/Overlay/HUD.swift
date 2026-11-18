import AppKit

/// Status bar for a translation pass: progress, then a persistent summary with
/// optional buttons. Sits next to the selection (or top of screen for full-screen passes).
@MainActor
final class HUD {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var buttons: NSStackView?
    private var spinner: NSProgressIndicator?
    private var row: NSStackView?
    private var hideWork: DispatchWorkItem?
    /// When set (a selection, global AppKit coords), the bar appears next to it.
    var anchor: CGRect?
    /// Called when the bar is shown or hidden.
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isVisible = false

    /// - Parameters:
    ///   - busy: shows a spinner.
    ///   - actions: buttons after the text; a close button is added whenever the bar persists.
    ///   - autoHide: seconds before hiding; nil keeps it until `hide()`.
    func show(_ text: String, busy: Bool = false, isError: Bool = false,
              actions: [Action] = [], closable: Bool = false, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        label?.stringValue = text
        label?.textColor = isError ? .systemRed : .labelColor
        spinner?.isHidden = !busy
        if busy { spinner?.startAnimation(nil) } else { spinner?.stopAnimation(nil) }

        buttons?.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for a in actions { buttons?.addArrangedSubview(HUDButton(title: a.title, handler: a.handler)) }
        if closable {
            let close = HUDButton(title: "✕") { [weak self] in self?.onClose?() }
            close.toolTip = "Dismiss (Esc)"
            buttons?.addArrangedSubview(close)
        }
        buttons?.isHidden = buttons?.arrangedSubviews.isEmpty ?? true
        panel.ignoresMouseEvents = buttons?.isHidden ?? true
        // Balanced gutters: tighter before a spinner, and match the text side when there are no buttons.
        let hasButtons = !(buttons?.isHidden ?? true)
        row?.edgeInsets = NSEdgeInsets(top: 7, left: busy ? 10 : 14, bottom: 7, right: hasButtons ? 8 : 14)

        panel.contentView?.layoutSubtreeIfNeeded()
        let fit = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 36)
        let size = NSSize(width: min(640, max(160, fit.width)), height: max(32, fit.height))
        panel.setFrame(Self.frame(size: size, anchor: anchor), display: true)
        panel.orderFrontRegardless()
        setVisible(true)

        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// Invoked by the close button.
    var onClose: (() -> Void)?

    func hide() {
        hideWork?.cancel()
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
        setVisible(false)
    }

    private func setVisible(_ v: Bool) {
        guard v != isVisible else { return }
        isVisible = v
        onVisibilityChange?(v)
    }

    /// Below the anchor (centered), else above it, else inside its top edge;
    /// without an anchor, top-center of the screen under the mouse.
    static func frame(size: NSSize, anchor: CGRect?) -> NSRect {
        let w = size.width, h = size.height, gap: CGFloat = 8
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return NSRect(x: 0, y: 0, width: w, height: h) }
        guard let a = anchor else { return NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 12, width: w, height: h) }
        return place(size: size, anchor: a, in: vf, gap: gap)
    }

    nonisolated static func place(size: NSSize, anchor a: CGRect, in vf: CGRect, gap: CGFloat = 8) -> NSRect {
        let w = size.width, h = size.height
        var y = a.minY - gap - h                                   // below
        if y < vf.minY { y = a.maxY + gap }                        // above
        if y + h > vf.maxY { y = min(a.maxY, vf.maxY) - gap - h }  // inside, top
        let x = min(max(a.midX - w / 2, vf.minX + gap), vf.maxX - w - gap)
        return NSRect(x: x, y: max(vf.minY, y), width: w, height: h)
    }

    private func makePanel() -> NSPanel {
        let p = OverlayPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        p.level = .popUpMenu
        p.ignoresMouseEvents = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isDisplayedWhenStopped = false
        spin.isHidden = true

        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.preferredMaxLayoutWidth = 420
        l.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let btns = NSStackView()
        btns.orientation = .horizontal
        btns.spacing = 6

        let row = NSStackView(views: [spin, l, btns])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(7, after: spin)
        row.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            row.topAnchor.constraint(equalTo: fx.topAnchor),
            row.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        p.contentView = fx
        panel = p
        label = l
        buttons = btns
        spinner = spin
        self.row = row
        return p
    }
}

/// Clickable without activating the app first (the bar lives in a non-activating panel).
private final class HUDButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }
}
