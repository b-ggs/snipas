import Foundation

/// Repairs OCR lines using exact strings from the Accessibility tree.
///
/// Vision has no Lithuanian model and misreads its letters in consistent ways
/// (ė→e, ū→ü, į→j/[, ų→y). We compare in a "folded" alphabet where those
/// confusions are equal, find the best approximate occurrence of the OCR line
/// inside an accessibility string, and return that exact substring.
enum TextMatcher {
    /// Maps a character to a comparison class. Always 1:1 so indices line up.
    static func fold(_ c: Character) -> Character {
        let s = String(c).lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        guard let f = s.first else { return c }
        switch f {
        case "y": return "u"
        case "j", "[", "|", "!", "1", "l", "í", "ı": return "i"
        case "0": return "o"
        case "„", "“", "”", "\"", "«", "»", "'", "‘", "’", "`": return "\""
        case "–", "—", "−": return "-"
        default: return f.isWhitespace ? " " : f
        }
    }

    /// Best approximate occurrence of `query` within `text` (semi-global edit
    /// distance over folded characters). Returns the exact matched substring of
    /// `text` and its distance.
    static func bestMatch(_ query: String, in text: String) -> (match: String, distance: Int)? {
        let q = Array(query).map(fold)
        let tChars = Array(text)
        let t = tChars.map(fold)
        let m = q.count, n = t.count
        guard m > 0, n > 0 else { return nil }

        // prev/cur: distance; prevStart/curStart: where in `t` the alignment began.
        var prev = [Int](repeating: 0, count: n + 1)
        var prevStart = Array(0...n)
        var cur = [Int](repeating: 0, count: n + 1)
        var curStart = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            cur[0] = i
            curStart[0] = 0
            for j in 1...n {
                let sub = prev[j - 1] + (q[i - 1] == t[j - 1] ? 0 : 1)
                let del = prev[j] + 1       // skip a query char
                let ins = cur[j - 1] + 1    // skip a text char
                if sub <= del && sub <= ins {
                    cur[j] = sub; curStart[j] = prevStart[j - 1]
                } else if del <= ins {
                    cur[j] = del; curStart[j] = prevStart[j]
                } else {
                    cur[j] = ins; curStart[j] = curStart[j - 1]
                }
            }
            swap(&prev, &cur)
            swap(&prevStart, &curStart)
        }
        var bestEnd = 1
        for j in 1...n where prev[j] < prev[bestEnd] { bestEnd = j }
        let start = prevStart[bestEnd]
        guard start < bestEnd else { return nil }
        let match = String(tChars[start..<bestEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return match.isEmpty ? nil : (match, prev[bestEnd])
    }

    /// Exact replacement text for an OCR line, or nil if no candidate matches well.
    /// `candidates` should be ordered top-to-bottom, left-to-right.
    static func correct(_ ocr: String, candidates: [String]) -> String? {
        let query = ocr.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let len = query.count
        guard len >= 2, !candidates.isEmpty else { return nil }
        let allowed = len < 4 ? 0 : max(1, len / 5)

        var pool = candidates
        if candidates.count > 1 {
            // A visual line can span several accessibility nodes (e.g. inline links).
            pool.append(candidates.joined(separator: " "))
        }
        var best: (String, Int)?
        for c in pool where c.count <= 20_000 {
            guard let r = bestMatch(query, in: c) else { continue }
            if best == nil || r.distance < best!.1 { best = (r.match, r.distance) }
            if r.distance == 0 { break }
        }
        guard let (match, dist) = best, dist <= allowed else { return nil }
        // Guard against matches that are much shorter/longer than the line.
        guard abs(match.count - len) <= max(2, len / 4) else { return nil }
        return match.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
