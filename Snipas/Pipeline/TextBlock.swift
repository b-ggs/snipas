import AppKit

/// A recognized line of text. `rect` is in image pixel space, top-left origin.
struct OCRLine: Equatable {
    var text: String
    var rect: CGRect
}

/// A group of lines translated and displayed together.
struct TextBlock: Identifiable {
    let id: Int
    /// Lines joined with "\n".
    let text: String
    let lineCount: Int
    /// Global AppKit screen coordinates (points, bottom-left origin).
    let screenRect: CGRect
    /// The screenshot pixels under `screenRect`.
    let original: CGImage?
    let background: NSColor
    let foreground: NSColor
    /// Placed from the AI's reading of the image rather than OCR (outlined in the overlay).
    var isApproximate = false
}

enum Geometry {
    /// Vision normalized rect (bottom-left origin) → pixel rect (top-left origin).
    static func pixelRect(fromNormalized r: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: r.minX * imageSize.width,
               y: (1 - r.maxY) * imageSize.height,
               width: r.width * imageSize.width,
               height: r.height * imageSize.height)
    }

    /// Global AppKit rect → pixel rect (top-left origin) in a display's screenshot.
    static func pixelRect(fromScreen r: CGRect, imageSize: CGSize, screenFrame: CGRect) -> CGRect {
        let sx = imageSize.width / screenFrame.width
        let sy = imageSize.height / screenFrame.height
        return CGRect(x: (r.minX - screenFrame.minX) * sx,
                      y: (screenFrame.maxY - r.maxY) * sy,
                      width: r.width * sx,
                      height: r.height * sy).integral
    }

    /// Pixel rect (top-left origin) in a display's screenshot → global AppKit points.
    static func screenRect(fromPixel r: CGRect, imageSize: CGSize, screenFrame: CGRect) -> CGRect {
        let sx = imageSize.width / screenFrame.width
        let sy = imageSize.height / screenFrame.height
        return CGRect(x: screenFrame.minX + r.minX / sx,
                      y: screenFrame.maxY - r.maxY / sy,
                      width: r.width / sx,
                      height: r.height / sy)
    }
}

enum BlockMerger {
    /// Groups lines that read as one paragraph / stacked list: similar height,
    /// small vertical gap, and left-aligned or horizontally overlapping.
    static func merge(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        var groups: [[OCRLine]] = []
        for line in sorted {
            if let i = groups.lastIndex(where: { canAppend($0.last!, line) }) {
                groups[i].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups
    }

    static func canAppend(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let ha = a.rect.height, hb = b.rect.height
        guard ha > 0, hb > 0 else { return false }
        let h = max(ha, hb)
        guard h / min(ha, hb) <= 1.35 else { return false }
        let gap = b.rect.minY - a.rect.maxY
        guard gap >= -0.3 * h, gap <= 0.6 * h else { return false }
        let leftAligned = abs(a.rect.minX - b.rect.minX) <= 1.0 * h
        let overlap = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX)
        return leftAligned || overlap > 0.6 * min(a.rect.width, b.rect.width)
    }

    static func join(_ lines: [OCRLine]) -> String {
        lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    static func union(_ lines: [OCRLine]) -> CGRect {
        lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
    }
}
