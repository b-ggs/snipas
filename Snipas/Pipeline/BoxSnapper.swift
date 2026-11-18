import CoreGraphics
import Foundation

/// Tightens the rough boxes a vision model gives for text OCR missed.
enum BoxSnapper {
    enum Method: Equatable { case ocr, ink, model }

    /// - Parameters:
    ///   - rough: the model's box, in `image` pixels (top-left origin).
    ///   - avoid: rects (same space) already covered by other boxes.
    /// - Returns: the snapped rect and how it was found.
    static func snap(_ rough: CGRect, in image: CGImage, avoid: [CGRect],
                     sources: [String], target: String) async -> (CGRect, Method) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let margin = max(8, min(rough.height, 80) * 0.6)
        let search = rough.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral
        guard search.width >= 4, search.height >= 4 else { return (rough, .model) }

        // 1) OCR just this spot: a tighter crop often succeeds where the full image didn't.
        if let crop = image.cropping(to: search),
           let lines = try? await OCRService.recognize(crop, sources: sources, target: target) {
            let hits = lines
                .map { $0.rect.offsetBy(dx: search.minX, dy: search.minY) }
                .filter { r in r.intersects(rough) && !avoid.contains { overlapFraction(r, $0) > 0.5 } }
            if let first = hits.first {
                return (hits.dropFirst().reduce(first) { $0.union($1) }, .ocr)
            }
        }

        // 2) Bounding box of "ink" — pixels that differ from the local background.
        if let ink = inkBounds(in: image, region: search, avoid: avoid), ink.intersects(rough) {
            return (ink, .ink)
        }
        return (rough.intersection(bounds), .model)
    }

    /// Fraction of `a`'s area covered by `b`.
    static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, a.height > 0 else { return 0 }
        return (i.width * i.height) / (a.width * a.height)
    }

    /// Bounds of pixels clearly different from the region's border color, ignoring
    /// `avoid` rects. Nil when the background is too busy to tell.
    static func inkBounds(in image: CGImage, region: CGRect, avoid: [CGRect]) -> CGRect? {
        let r = region.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 4, r.height >= 4, let crop = image.cropping(to: r) else { return nil }
        let w = crop.width, h = crop.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Bitmap memory starts at the top row, matching our top-left pixel space.
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        let localAvoid = avoid.map { $0.offsetBy(dx: -r.minX, dy: -r.minY) }
        func avoided(_ x: Int, _ y: Int) -> Bool {
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            return localAvoid.contains { $0.contains(p) }
        }

        var border: [(Int, Int, Int)] = []
        for x in 0..<w { border.append(rgb(x, 0)); border.append(rgb(x, h - 1)) }
        for y in 0..<h { border.append(rgb(0, y)); border.append(rgb(w - 1, y)) }
        func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
        let bg = (median(border.map(\.0)), median(border.map(\.1)), median(border.map(\.2)))
        // A noisy border means a photo/gradient background — ink detection is meaningless.
        let noisy = border.filter { abs($0.0 - bg.0) + abs($0.1 - bg.1) + abs($0.2 - bg.2) > 60 }.count
        guard noisy < border.count / 4 else { return nil }

        var minX = w, minY = h, maxX = -1, maxY = -1, count = 0
        for y in 0..<h {
            for x in 0..<w {
                let c = rgb(x, y)
                guard abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2) > 120, !avoided(x, y) else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count >= 8, maxX >= minX, maxY >= minY else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        // Ink everywhere → not a text-on-plain-background situation.
        guard box.width * box.height < CGFloat(w * h) * 0.9 else { return nil }
        return box.offsetBy(dx: r.minX, dy: r.minY)
    }
}
