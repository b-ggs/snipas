import AppKit
import NaturalLanguage

@MainActor
enum LanguageFilter {
    /// True if the block likely needs translating into `target`.
    static func shouldTranslate(_ text: String, target: String) -> Bool {
        guard hasLetters(text) else { return false }

        // Prefer the spell checker: if almost every word is a valid word in the
        // target language, it's already in the target language. This handles
        // short UI strings far better than statistical detection, and unknown
        // languages (e.g. Lithuanian) simply show up as misspellings.
        let checker = NSSpellChecker.shared
        let spellLang = checker.availableLanguages.first { $0 == target || $0.hasPrefix(target + "_") }
        if let spellLang {
            let (words, misspelled) = spellStats(text, language: spellLang, checker: checker)
            if words > 0 {
                return Double(misspelled) / Double(words) > 0.15
            }
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let p = recognizer.languageHypotheses(withMaximum: 3)[NLLanguage(rawValue: target)] ?? 0
        return p < 0.8
    }

    static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.filter(CharacterSet.letters.contains).count >= 2
    }

    private static func spellStats(_ text: String, language: String, checker: NSSpellChecker) -> (Int, Int) {
        let ns = text as NSString
        var words = 0
        var misspelled = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, _, _, _ in
            guard let sub, sub.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return }
            words += 1
            // Skip all-caps/mixed-case identifiers and single letters.
            if sub.count == 1 { return }
            let range = checker.checkSpelling(of: sub, startingAt: 0, language: language, wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
            if range.location != NSNotFound { misspelled += 1 }
        }
        return (words, misspelled)
    }
}
