import AppKit

/// Crosshair region picker across all displays (like the Snipping Tool / ⌘⇧4).
@MainActor
final class SnipController {
    private var windows: [SnipWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var previousApp: NSRunningApplication?

    var isActive: Bool { !windows.isEmpty }

    /// Calls `completion` with the selected rect in global AppKit coordinates, or nil if cancelled.
    func begin(completion: @escaping (CGRect?) -> Void) {
        cancel()
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let w = SnipWindow(screen: screen)
            w.snipView.onFinish = { [weak self] rect in self?.finish(rect) }
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard !windows.isEmpty || completion != nil else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        // Hand focus back so the user's app stays active under the overlays.
        if let prev = previousApp, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate()
        }
        previousApp = nil
        let c = completion
        completion = nil
        if let rect, rect.width >= 6, rect.height >= 6 { c?(rect) } else { c?(nil) }
    }
}

final class SnipWindow: NSWindow {
    let snipView: SnipView

    init(screen: NSScreen) {
        snipView = SnipView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = snipView
    }

    override var canBecomeKey: Bool { true }
}

final class SnipView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let sel = selection, let window else { onFinish?(nil); return }
        onFinish?(window.convertToScreen(sel))
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) } // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()

        guard let sel = selection else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        var origin = NSPoint(x: sel.maxX - size.width - 6, y: sel.minY - size.height - 6)
        if origin.y < 2 { origin.y = sel.minY + 4 }
        let bg = NSRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attrs)
    }
}
