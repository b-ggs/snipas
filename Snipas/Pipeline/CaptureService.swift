import AppKit
import ScreenCaptureKit

struct CapturedDisplay {
    let image: CGImage
    /// NSScreen frame in global AppKit coordinates.
    let frame: CGRect
}

enum CaptureError: LocalizedError {
    case noPermission
    var errorDescription: String? {
        "Screen Recording permission is required. Enable Snipas in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then relaunch."
    }
}

@MainActor
enum CaptureService {
    /// Screenshots every display, excluding this app's own windows (overlays, HUD).
    /// - Parameter region: if set, only displays intersecting it (global AppKit coords) are captured.
    static func captureAll(intersecting region: CGRect? = nil) async throws -> [CapturedDisplay] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        var result: [CapturedDisplay] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            if let region, !screen.frame.intersects(region) { continue }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(CapturedDisplay(image: image, frame: screen.frame))
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
