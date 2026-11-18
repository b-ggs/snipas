import AppKit
import ApplicationServices

struct AXTextItem {
    let text: String
    /// Global AppKit coordinates (bottom-left origin).
    let rect: CGRect
}

/// Reads visible text strings + frames from other apps' Accessibility trees.
enum AccessibilityText {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    struct Snapshot: Sendable {
        let primaryHeight: CGFloat
        /// Union of all screens, Quartz coordinates (top-left origin).
        let screensQuartz: CGRect
        let frontmostPID: pid_t?
    }

    @MainActor
    static func snapshot(frontmostPID: pid_t? = nil) -> Snapshot {
        let primary = NSScreen.screens.first?.frame ?? .zero
        let union = NSScreen.screens.reduce(CGRect.null) { acc, s in
            acc.union(CGRect(x: s.frame.minX, y: primary.maxY - s.frame.maxY, width: s.frame.width, height: s.frame.height))
        }
        return Snapshot(primaryHeight: primary.height, screensQuartz: union,
                        frontmostPID: frontmostPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private static let attributes = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute,
                                     kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                     kAXChildrenAttribute] as CFArray

    /// Walks every app that has an on-screen window. Bounded by node count and time.
    static func collect(_ snap: Snapshot, budget: TimeInterval = 1.5, maxNodesPerApp: Int = 8000) -> [AXTextItem] {
        guard isTrusted else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        let me = ProcessInfo.processInfo.processIdentifier

        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        var pids: [pid_t] = []
        if let f = snap.frontmostPID { pids.append(f) }
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  (w[kCGWindowLayer as String] as? Int) == 0, pid != me, !pids.contains(pid) else { continue }
            pids.append(pid)
        }

        var items: [AXTextItem] = []
        for pid in pids where pid != me {
            guard Date() < deadline else { break }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            // Asks Chromium/Electron apps to build their accessibility tree.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            var roots: [AXUIElement] = []
            if let ws = copy(app, kAXWindowsAttribute) as? [AXUIElement] { roots += ws }
            if pid == snap.frontmostPID, let bar = copy(app, kAXMenuBarAttribute) {
                roots.append(bar as! AXUIElement)
            }
            walk(roots, snap: snap, deadline: deadline, maxNodes: maxNodesPerApp, into: &items)
        }
        return items
    }

    private static func walk(_ roots: [AXUIElement], snap: Snapshot, deadline: Date, maxNodes: Int,
                             into items: inout [AXTextItem]) {
        var stack = roots.reversed() as [AXUIElement]
        var visited = 0
        while let el = stack.popLast(), visited < maxNodes {
            visited += 1
            if visited % 200 == 0, Date() >= deadline { return }

            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 7 else { continue }

            let role = values[0] as? String
            var frame: CGRect?
            if let p = axPoint(values[4]), let s = axSize(values[5]) { frame = CGRect(origin: p, size: s) }

            // Off-screen (e.g. scrolled away) → skip the subtree. Zero-size groups are kept.
            if let f = frame, f.width > 0, f.height > 0, !f.intersects(snap.screensQuartz) { continue }

            if let f = frame, f.width > 0, f.height > 0 {
                let appKit = CGRect(x: f.minX, y: snap.primaryHeight - f.maxY, width: f.width, height: f.height)
                var seen = Set<String>()
                for v in [values[1], values[2], values[3]] {
                    guard let s = v as? String else { continue }
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, t.count <= 20_000, seen.insert(t).inserted else { continue }
                    items.append(AXTextItem(text: t, rect: appKit))
                }
            }
            if role == kAXScrollBarRole as String { continue }
            if let children = values[6] as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func axPoint(_ v: AnyObject) -> CGPoint? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        var p = CGPoint.zero
        return AXValueGetType(ax) == .cgPoint && AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    private static func axSize(_ v: AnyObject) -> CGSize? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        var s = CGSize.zero
        return AXValueGetType(ax) == .cgSize && AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }
}

/// Finds accessibility strings near an OCR line.
struct AXIndex {
    let items: [AXTextItem]

    /// Candidates whose frame overlaps `rect` (AppKit global), top-to-bottom, left-to-right.
    func candidates(near rect: CGRect) -> [String] {
        let probe = rect.insetBy(dx: -rect.height, dy: -rect.height * 0.5)
        return items
            .filter { $0.rect.intersects(probe) }
            .sorted { abs($0.rect.maxY - $1.rect.maxY) > 2 ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX }
            .map(\.text)
    }
}
