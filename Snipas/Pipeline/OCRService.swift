import Foundation
import Vision

enum OCRService {
    /// Vision has no recognizer for some languages; use the closest supported
    /// Latin/Cyrillic glyph sets instead (and let the AI repair diacritics).
    static let fallbacks: [String: [String]] = [
        "lt": ["cs", "pl"], "lv": ["cs", "pl"], "et": ["fi", "sv"],
        "sk": ["cs"], "sl": ["cs"], "hr": ["cs"], "hu": ["cs", "de"],
        "el": ["en"], "he": ["en"], "bg": ["ru"], "be": ["ru", "uk"],
    ]

    struct Config: Equatable {
        var languages: [String]
        var usesLanguageCorrection: Bool
        var automaticallyDetectsLanguage: Bool
    }

    static func config(sources: [String], target: String, supported: Set<String>) -> Config {
        var langs: [String] = []
        var allSupported = true
        for code in sources {
            if supported.contains(code) {
                langs.append(code)
            } else {
                allSupported = false
                langs.append(contentsOf: (fallbacks[code] ?? []).filter(supported.contains))
            }
        }
        if supported.contains(target) { langs.append(target) }
        var seen = Set<String>()
        langs = langs.filter { seen.insert($0).inserted }
        return Config(languages: langs,
                      // Correction would "fix" e.g. Lithuanian words into Czech ones.
                      usesLanguageCorrection: allSupported,
                      automaticallyDetectsLanguage: sources.isEmpty)
    }

    static func recognize(_ image: CGImage, sources: [String], target: String) async throws -> [OCRLine] {
        var request = RecognizeTextRequest()
        let supported = Set(request.supportedRecognitionLanguages.map { $0.minimalIdentifier })
        let cfg = config(sources: sources, target: target, supported: supported)
        request.recognitionLevel = .accurate
        request.recognitionLanguages = cfg.languages.map { Locale.Language(identifier: $0) }
        request.usesLanguageCorrection = cfg.usesLanguageCorrection
        request.automaticallyDetectsLanguage = cfg.automaticallyDetectsLanguage

        let size = CGSize(width: image.width, height: image.height)
        let observations = try await request.perform(on: image)
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, rect: Geometry.pixelRect(fromNormalized: obs.boundingBox.cgRect, imageSize: size))
        }
    }
}
