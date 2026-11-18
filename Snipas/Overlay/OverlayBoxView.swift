import AppKit

/// One translated box. Shows the translation; while hovered it shows the
/// original screenshot pixels so the real text underneath is visible.
final class OverlayBoxView: NSView {
    enum State { case pending, translated(String) }

    let block: TextBlock
    var state: State = .pending { didSet { needsDisplay = true } }
    /// Exact source text read by the model from the image, if any.
    var exactSource: String?
    var sourceText: String { exactSource ?? block.text }
    private var hovering = false { didSet { needsDisplay = true } }
    private var flash = false { didSet { needsDisplay = true } }
    private var pulse: Timer?
    private var pulsePhase: CGFloat = 0

    static let padding: CGFloat = 3
    static let minFont: CGFloat = 8

    init(block: TextBlock, frame: NSRect) {
        self.block = block
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        pulse = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            if case .pending = self.state {
                self.pulsePhase += 0.15
                self.needsDisplay = true
            } else {
                self.pulse?.invalidate()
                self.pulse = nil
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { pulse?.invalidate() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let text: String
        if event.modifierFlags.contains(.option) {
            text = sourceText
        } else if case .translated(let t) = state {
            text = t
        } else {
            text = sourceText
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flash = false }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let showOriginal: Bool
        if case .translated = state { showOriginal = hovering } else { showOriginal = true }

        if showOriginal, let img = block.original {
            // Draw the captured pixels upright in a flipped view.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            let originalHeight = block.screenRect.height
            ctx.draw(img, in: CGRect(x: 0, y: bounds.height - originalHeight, width: bounds.width, height: originalHeight))
            ctx.restoreGState()
            if bounds.height > originalHeight {
                block.background.setFill()
                NSRect(x: 0, y: originalHeight, width: bounds.width, height: bounds.height - originalHeight).fill()
            }
        }

        switch state {
        case .pending:
            let alpha = 0.45 + 0.35 * sin(pulsePhase)
            NSColor.controlAccentColor.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            path.lineWidth = 2
            path.setLineDash([4, 3], count: 2, phase: pulsePhase * 4)
            path.stroke()
        case .translated(let text):
            if hovering {
                NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                path.lineWidth = 1
                path.stroke()
            } else {
                block.background.setFill()
                bounds.fill()
                let (attr, _) = Self.layout(text, width: bounds.width, height: bounds.height,
                                            lines: Self.lineCount(text, fallback: block.lineCount), color: block.foreground)
                attr.draw(with: bounds.insetBy(dx: Self.padding, dy: Self.padding / 2),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                if block.isApproximate {
                    // Placed from the AI's reading of the image, not OCR.
                    NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
                    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
                    path.lineWidth = 1.5
                    path.setLineDash([3, 2], count: 2, phase: 0)
                    path.stroke()
                }
            }
        }

        if flash {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
    }

    static func lineCount(_ text: String, fallback: Int) -> Int {
        max(fallback, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    /// Largest font (capped near the original line height) that fits the box.
    /// Returns the attributed string and the height it needs.
    static func layout(_ text: String, width: CGFloat, height: CGFloat, lines: Int, color: NSColor)
        -> (NSAttributedString, CGFloat) {
        let innerW = max(10, width - padding * 2)
        let innerH = max(6, height - padding)
        var size = min(max(minFont, innerH / CGFloat(max(lines, 1)) * 0.82), 48)
        func make(_ s: CGFloat) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: s),
                .foregroundColor: color,
                .paragraphStyle: para,
            ])
        }
        func needed(_ a: NSAttributedString) -> CGFloat {
            ceil(a.boundingRect(with: CGSize(width: innerW, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin]).height)
        }
        var attr = make(size)
        while size > minFont, needed(attr) > innerH {
            size -= 0.5
            attr = make(size)
        }
        return (attr, needed(attr) + padding)
    }
}
