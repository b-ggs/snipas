import AppKit

enum ColorSampler {
    /// Estimates background (median of the rect's border) and foreground
    /// (pixels most different from the background) in a pixel rect.
    static func sample(_ image: CGImage, rect: CGRect) -> (background: NSColor, foreground: NSColor) {
        let fallback = (NSColor.windowBackgroundColor, NSColor.labelColor)
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 2, r.height >= 2, let crop = image.cropping(to: r) else { return fallback }

        let w = crop.width, h = crop.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))

        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * w + x) * 4
            return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
        }

        var border: [(Double, Double, Double)] = []
        for x in 0..<w { border.append(rgb(x, 0)); border.append(rgb(x, h - 1)) }
        for y in 0..<h { border.append(rgb(0, y)); border.append(rgb(w - 1, y)) }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        let bg = (median(border.map(\.0)), median(border.map(\.1)), median(border.map(\.2)))

        func dist(_ c: (Double, Double, Double)) -> Double {
            let d = (c.0 - bg.0, c.1 - bg.1, c.2 - bg.2)
            return (d.0 * d.0 + d.1 * d.1 + d.2 * d.2).squareRoot()
        }
        let step = max(1, (w * h) / 20_000)
        var inner: [((Double, Double, Double), Double)] = []
        var i = 0
        while i < w * h {
            let c = rgb(i % w, i / w)
            inner.append((c, dist(c)))
            i += step
        }
        inner.sort { $0.1 > $1.1 }
        let top = inner.prefix(max(1, inner.count / 12))
        let n = Double(top.count)
        var fg = (top.reduce(0) { $0 + $1.0.0 } / n, top.reduce(0) { $0 + $1.0.1 } / n, top.reduce(0) { $0 + $1.0.2 } / n)

        if dist(fg) < 0.35 {
            let lum = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2
            fg = lum > 0.5 ? (0, 0, 0) : (1, 1, 1)
        }
        return (NSColor(srgbRed: bg.0, green: bg.1, blue: bg.2, alpha: 1),
                NSColor(srgbRed: fg.0, green: fg.1, blue: fg.2, alpha: 1))
    }
}
