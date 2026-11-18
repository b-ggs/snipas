import AppKit

/// A rect as fractions of the image size, top-left origin.
struct NormBox: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        func r(_ v: Double) -> Double { (min(max(v, 0), 1) * 1000).rounded() / 1000 }
        self.x = r(x); self.y = r(y); self.w = r(w); self.h = r(h)
    }

    /// `rect` in global AppKit coords relative to `frame` (also AppKit) → normalized, top-left origin.
    init?(rect: CGRect, in frame: CGRect) {
        let r = rect.intersection(frame)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        self.init(x: (r.minX - frame.minX) / frame.width, y: (frame.maxY - r.maxY) / frame.height,
                  w: r.width / frame.width, h: r.height / frame.height)
    }

    func pixelRect(width: Int, height: Int) -> CGRect {
        CGRect(x: x * Double(width), y: y * Double(height), width: w * Double(width), height: h * Double(height))
    }
}

struct TranslationItem: Codable, Equatable {
    let id: Int
    let text: String
    /// Where the item is in the attached image (vision modes only).
    var box: NormBox? = nil
}

struct TranslationResult: Equatable {
    let text: String
    /// Exact source text as read from the image (vision modes only).
    let source: String?
}

/// Text the model found in the image that no item covered.
struct ExtraText: Equatable {
    let source: String
    let text: String
    let box: NormBox
}

struct TranslationOutput: Equatable {
    var results: [Int: TranslationResult] = [:]
    var extras: [ExtraText] = []
    /// English name of the main source language, as identified by the model.
    var language: String? = nil
}

struct TranslationContext {
    var targetName: String
    /// Likely source languages, most likely first.
    var sourceNames: [String]
}

/// How the screenshot of a selection is used.
enum VisionMode: Equatable {
    /// Text only.
    case none
    /// Image + OCR items: the model reads exact source text from the image.
    case assist
    /// OCR found nothing: the model reads all text from the image as item 0.
    case readAll
}

protocol Translator {
    /// `image` is PNG data, used when `mode != .none`.
    func translate(_ items: [TranslationItem], context: TranslationContext,
                   mode: VisionMode, image: Data?) async throws -> TranslationOutput
}

extension Translator {
    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> TranslationOutput {
        try await translate(items, context: context, mode: .none, image: nil)
    }
}

enum TranslationPrompt {
    static let schema = #"{"type":"object","additionalProperties":false,"properties":{"language":{"type":"string"},"translations":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"]}}},"required":["language","translations"]}"#
    static let visionSchema = #"{"type":"object","additionalProperties":false,"properties":{"language":{"type":"string"},"translations":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"integer"},"source":{"type":"string"},"text":{"type":"string"}},"required":["id","source","text"]}}},"required":["language","translations"]}"#

    static let assistSchema = #"{"type":"object","additionalProperties":false,"properties":{"language":{"type":"string"},"translations":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"integer"},"source":{"type":"string"},"text":{"type":"string"}},"required":["id","source","text"]}},"extra":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"source":{"type":"string"},"text":{"type":"string"},"box":{"type":"object","additionalProperties":false,"properties":{"x":{"type":"number"},"y":{"type":"number"},"w":{"type":"number"},"h":{"type":"number"}},"required":["x","y","w","h"]}},"required":["source","text","box"]}}},"required":["language","translations","extra"]}"#

    static func schema(for mode: VisionMode) -> String {
        switch mode {
        case .none: return schema
        case .assist: return assistSchema
        case .readAll: return visionSchema
        }
    }

    static func system(_ ctx: TranslationContext, mode: VisionMode = .none) -> String {
        var s = """
        You translate text captured from a computer screen. Translate the text of every item into \(ctx.targetName).
        """
        if let first = ctx.sourceNames.first {
            let list = ctx.sourceNames.joined(separator: ", ")
            s += """

            The source text is most likely \(list). When the source language is ambiguous (for example, it could be read as Czech, Polish, Slovak or another similar language), assume it is \(first).
            OCR may have dropped or confused diacritics and letters (e.g. ė/e, į/i, ų/u, ū/u, ą/a, ę/e, č/c, š/s, ž/z), so infer the intended words before translating.
            """
        }
        switch mode {
        case .none: break
        case .assist:
            s += """

            An image of the selected screen area is attached. Each item is an OCR reading of one line or block of text in that image and may contain recognition mistakes. "box" gives the item's position in the image as fractions of the image width and height ({x, y, w, h}, origin at the top-left). Look at that spot, put the exact source text (as it appears in the image, with correct diacritics) in "source", and its translation in "text".
            OCR can miss text (stylised fonts, text on images, small or faint text). If the image contains readable text that no item covers, add each missed line or paragraph to "extra" with its exact "source", its translation in "text", and a tight "box" around it in the same format. Never repeat text that an item already covers, and skip text cut off at the image edge. If nothing was missed, return "extra": [].
            """
        case .readAll:
            s += """

            An image of the selected screen area is attached; automatic text recognition found nothing in it. Read all text in the image and return exactly one item with id 0: "source" is all the text in reading order (one line per visual line), "text" is its translation with the same line structure. If there is no text, return empty strings.
            """
        }
        s += """

        Rules:
        - Preserve line breaks: if an item has N lines, return N lines where possible (lines are often separate UI labels).
        - Keep numbers, URLs, email addresses, file names, code, product and brand names, and usernames unchanged.
        - If an item is already in \(ctx.targetName) or is not translatable, return it unchanged.
        - Set "language" to the English name of the main source language (e.g. "Lithuanian"); if everything is already in \(ctx.targetName), use "\(ctx.targetName)".
        - Return every id exactly once. Output only JSON of the form {"language":"...","translations":[{"id":0,\(mode == .none ? "" : "\"source\":\"...\",")"text":"..."}]\(mode == .assist ? ",\"extra\":[{\"source\":\"...\",\"text\":\"...\",\"box\":{\"x\":0.1,\"y\":0.2,\"w\":0.3,\"h\":0.05}}]" : "")}.
        """
        return s
    }

    static func user(_ items: [TranslationItem], mode: VisionMode = .none) -> String {
        if mode == .readAll { return "Read and translate all text in the attached image." }
        let data = (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
        return "Items:\n" + String(decoding: data, as: UTF8.self)
    }
}

enum TranslationParser {
    private struct Item: Decodable { let id: Int; let text: String; let source: String? }
    private struct Extra: Decodable { let source: String?; let text: String; let box: NormBox? }
    private struct Payload: Decodable { let translations: [Item]; let extra: [Extra]?; let language: String? }
    private struct ClaudeEnvelope: Decodable {
        let structured_output: Payload?
        let result: String?
        let is_error: Bool?
    }

    /// Parses `claude -p` stdout: one JSON envelope (`--output-format json`) or
    /// JSON lines (`stream-json`), where the final `"type":"result"` line counts.
    static func parseClaude(_ data: Data) throws -> TranslationOutput {
        var envelopeData = data
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        if lines.count > 1, let last = lines.last(where: { $0.contains("\"type\":\"result\"") }) {
            envelopeData = Data(last.utf8)
        }
        let env = try JSONDecoder().decode(ClaudeEnvelope.self, from: envelopeData)
        if env.is_error == true { throw CLIError.badOutput(env.result ?? "Claude returned an error") }
        if let p = env.structured_output { return dict(p) }
        if let r = env.result { return try parsePayload(r) }
        throw CLIError.badOutput("No result in Claude output")
    }

    /// Parses model text that contains a {"translations": [...]} object, possibly
    /// fenced, prefixed with prose, or repeated.
    static func parsePayload(_ text: String) throws -> TranslationOutput {
        guard let json = firstJSONObject(in: text),
              let p = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw CLIError.badOutput(String(text.prefix(300)))
        }
        return dict(p)
    }

    private static func dict(_ p: Payload) -> TranslationOutput {
        let results = Dictionary(p.translations.map { item in
            let src = item.source?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (item.id, TranslationResult(text: item.text, source: (src?.isEmpty ?? true) ? nil : src))
        }, uniquingKeysWith: { a, _ in a })
        let extras: [ExtraText] = (p.extra ?? []).compactMap { e in
            let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let b = e.box, b.w > 0.003, b.h > 0.003 else { return nil }
            // Re-clamp in case the model returned out-of-range values.
            return ExtraText(source: e.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", text: text,
                             box: NormBox(x: b.x, y: b.y, w: min(b.w, 1 - b.x), h: min(b.h, 1 - b.y)))
        }
        let lang = p.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationOutput(results: results, extras: extras, language: (lang?.isEmpty ?? true) ? nil : lang)
    }

    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default: break
            }
        }
        return nil
    }
}

enum ImageEncoding {
    /// PNG, downscaled so the long edge is at most `maxEdge` px (vision models resize beyond that anyway).
    static func png(_ image: CGImage, maxEdge: Int = 1568) -> Data? {
        var img = image
        let long = max(image.width, image.height)
        if long > maxEdge {
            let scale = Double(maxEdge) / Double(long)
            let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            img = scaled
        }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
