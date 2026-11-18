import AppKit
import XCTest
@testable import Snipas

final class GeometryTests: XCTestCase {
    func testNormalizedToPixelFlipsY() {
        let r = Geometry.pixelRect(fromNormalized: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1),
                                   imageSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(r.minX, 100, accuracy: 0.001)
        XCTAssertEqual(r.minY, 50, accuracy: 0.001)   // top 10% of image
        XCTAssertEqual(r.width, 200, accuracy: 0.001)
        XCTAssertEqual(r.height, 50, accuracy: 0.001)
    }

    func testPixelToScreenOnRetinaSecondaryDisplay() {
        // 2x display placed to the right of a 1440x900 primary, top-aligned.
        let frame = CGRect(x: 1440, y: -100, width: 1000, height: 1000)
        let r = Geometry.screenRect(fromPixel: CGRect(x: 200, y: 0, width: 400, height: 100),
                                    imageSize: CGSize(width: 2000, height: 2000), screenFrame: frame)
        XCTAssertEqual(r, CGRect(x: 1540, y: 850, width: 200, height: 50))
    }
}

final class BlockMergerTests: XCTestCase {
    func line(_ t: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 200, h: CGFloat = 20) -> OCRLine {
        OCRLine(text: t, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    func testMergesParagraphLines() {
        let groups = BlockMerger.merge([line("Labas rytas,", 10, 10), line("kaip sekasi?", 12, 34)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(BlockMerger.join(groups[0]), "Labas rytas,\nkaip sekasi?")
    }

    func testKeepsColumnsAndDistantLinesApart() {
        let groups = BlockMerger.merge([
            line("Failas", 10, 10, w: 60),
            line("Redaguoti", 300, 10, w: 80),      // same row, other column
            line("Pagalba", 10, 200, w: 70),        // far below
            line("Didelė antraštė", 10, 230, h: 48) // very different height
        ])
        XCTAssertEqual(groups.count, 4)
    }
}

final class ParserTests: XCTestCase {
    func testParsesClaudeStructuredOutput() throws {
        let json = #"{"type":"result","is_error":false,"result":"ignored","structured_output":{"translations":[{"id":0,"text":"Hello"},{"id":2,"text":"Log in"}]}}"#
        XCTAssertEqual(try TranslationParser.parseClaude(Data(json.utf8)).results.mapValues(\.text), [0: "Hello", 2: "Log in"])
    }

    func testParsesClaudeResultStringFallback() throws {
        let json = #"{"is_error":false,"result":"```json\n{\"translations\":[{\"id\":1,\"text\":\"Yes\"}]}\n```"}"#
        XCTAssertEqual(try TranslationParser.parseClaude(Data(json.utf8)).results.mapValues(\.text), [1: "Yes"])
    }

    func testClaudeErrorThrows() {
        let json = #"{"is_error":true,"result":"Not logged in"}"#
        XCTAssertThrowsError(try TranslationParser.parseClaude(Data(json.utf8)))
    }

    func testCodexDuplicatedOutput() throws {
        // codex -o has been observed writing the object twice back-to-back.
        let s = #"{"translations":[{"id":0,"text":"Good {morning}"}]}{"translations":[{"id":0,"text":"Good {morning}"}]}"#
        XCTAssertEqual(try TranslationParser.parsePayload(s).results.mapValues(\.text), [0: "Good {morning}"])
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try TranslationParser.parsePayload("sorry, I can't"))
    }
}

final class ConfigTests: XCTestCase {
    let supported: Set = ["en", "cs", "pl", "de", "fi", "sv", "ru"]

    func testLithuanianFallsBackToCzechPolishWithoutCorrection() {
        let c = OCRService.config(sources: ["lt"], target: "en", supported: supported)
        XCTAssertEqual(c.languages, ["cs", "pl", "en"])
        XCTAssertFalse(c.usesLanguageCorrection)
        XCTAssertFalse(c.automaticallyDetectsLanguage)
    }

    func testSupportedSourceKeepsCorrection() {
        let c = OCRService.config(sources: ["de"], target: "en", supported: supported)
        XCTAssertEqual(c.languages, ["de", "en"])
        XCTAssertTrue(c.usesLanguageCorrection)
    }

    func testChunking() {
        let items = (0..<95).map { TranslationItem(id: $0, text: "abc") }
        XCTAssertEqual(TranslationPipeline.chunk(items).map(\.count), [40, 40, 15])
    }

    func testPromptPrefersConfiguredLanguage() {
        let p = TranslationPrompt.system(TranslationContext(targetName: "English", sourceNames: ["Lithuanian"]))
        XCTAssertTrue(p.contains("assume it is Lithuanian"))
    }
}

@MainActor
final class LanguageFilterTests: XCTestCase {
    func testSkipsEnglishTranslatesLithuanian() {
        XCTAssertFalse(LanguageFilter.shouldTranslate("Open the settings window", target: "en"))
        XCTAssertTrue(LanguageFilter.shouldTranslate("Prisijungti prie paskyros", target: "en"))
        XCTAssertTrue(LanguageFilter.shouldTranslate("Labas rytas", target: "en"))
        XCTAssertFalse(LanguageFilter.shouldTranslate("12:45 %", target: "en"))
    }
}

final class OCRTests: XCTestCase {
    func render(_ text: String) -> CGImage {
        let size = NSSize(width: 900, height: 160)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (text as NSString).draw(at: NSPoint(x: 20, y: 50),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testRecognizesLithuanianishText() async throws {
        let image = render("Labas rytas, kaip sekasi?")
        let lines = try await OCRService.recognize(image, sources: ["lt"], target: "en")
        let joined = lines.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("labas"), joined)
        XCTAssertTrue(joined.contains("sekasi"), joined)
        // Box should be near the top-left-origin y of the drawn text.
        // Text baseline drawn at y=50 of 160 (bottom-left) → occupies roughly the
        // middle of the image in top-left pixel space, at any backing scale.
        let h = CGFloat(image.height)
        XCTAssertGreaterThan(lines[0].rect.minY / h, 0.1)
        XCTAssertLessThan(lines[0].rect.maxY / h, 0.9)
    }

    func testColorSamplerOnDarkBackground() {
        let size = NSSize(width: 200, height: 60)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill(); rect.fill()
            ("Ąžuolas" as NSString).draw(at: NSPoint(x: 10, y: 10),
                                         withAttributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.yellow])
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let (bg, fg) = ColorSampler.sample(img, rect: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        XCTAssertLessThan(bg.brightnessComponent, 0.1)
        XCTAssertGreaterThan(fg.redComponent, 0.6)
        XCTAssertGreaterThan(fg.greenComponent, 0.6)
    }
}

final class TextMatcherTests: XCTestCase {
    // OCR strings below are real Vision outputs for the ground truth.
    func testRepairsLithuanianDiacritics() {
        let cases = [
            ("Ąžuolas šlamejo ükanotą rytą", "Ąžuolas šlamėjo ūkanotą rytą"),
            ("[veskite slaptažodj ir spauskite „Prisijungti\"", "Įveskite slaptažodį ir spauskite „Prisijungti“"),
            ("Gražiy švenčiy linkime visiems!", "Gražių švenčių linkime visiems!"),
            ("Užsakymo büsena: išsiysta", "Užsakymo būsena: išsiųsta"),
        ]
        for (ocr, truth) in cases {
            XCTAssertEqual(TextMatcher.correct(ocr, candidates: [truth]), truth, ocr)
        }
    }

    func testExtractsWrappedLineFromParagraph() {
        let paragraph = "Mūsų parduotuvėje rasite viską, ko reikia namams. Užsakymo būsena: išsiųsta vakar vakare."
        XCTAssertEqual(TextMatcher.correct("Užsakymo büsena: išsiysta", candidates: ["Meniu", paragraph]),
                       "Užsakymo būsena: išsiųsta")
    }

    func testLineSpanningSeveralNodes() {
        // Inline link splits one visual line into separate accessibility strings.
        XCTAssertEqual(TextMatcher.correct("Skaitykite daugiau apie mūsy paslaugas",
                                           candidates: ["Skaitykite daugiau", "apie mūsų paslaugas"]),
                       "Skaitykite daugiau apie mūsų paslaugas")
    }

    func testNoMatchFallsBack() {
        XCTAssertNil(TextMatcher.correct("Labas rytas", candidates: ["Completely unrelated text here"]))
        XCTAssertNil(TextMatcher.correct("Labas rytas", candidates: []))
        // Short strings require an exact folded match.
        XCTAssertNil(TextMatcher.correct("Taip", candidates: ["Ne"]))
        XCTAssertEqual(TextMatcher.correct("Ne", candidates: ["Ne"]), "Ne")
    }
}

final class AXIndexTests: XCTestCase {
    func testCandidatesNearLineInReadingOrder() {
        let index = AXIndex(items: [
            AXTextItem(text: "far away", rect: CGRect(x: 900, y: 900, width: 50, height: 20)),
            AXTextItem(text: "second", rect: CGRect(x: 150, y: 100, width: 80, height: 20)),
            AXTextItem(text: "first", rect: CGRect(x: 100, y: 100, width: 40, height: 20)),
        ])
        XCTAssertEqual(index.candidates(near: CGRect(x: 100, y: 100, width: 140, height: 20)), ["first", "second"])
    }
}

final class RegionGeometryTests: XCTestCase {
    func testScreenToPixelRoundTripsOnSecondaryRetinaDisplay() {
        let frame = CGRect(x: 1440, y: -100, width: 1000, height: 1000)
        let size = CGSize(width: 2000, height: 2000)
        let region = CGRect(x: 1540, y: 850, width: 200, height: 50)
        let px = Geometry.pixelRect(fromScreen: region, imageSize: size, screenFrame: frame)
        XCTAssertEqual(px, CGRect(x: 200, y: 0, width: 400, height: 100))
        XCTAssertEqual(Geometry.screenRect(fromPixel: px, imageSize: size, screenFrame: frame), region)
    }
}


final class VisionTests: XCTestCase {
    func testParsesStreamJSONResultLineWithSource() throws {
        let stream = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[]}}
        {"type":"result","is_error":false,"structured_output":{"translations":[{"id":0,"source":"Įveskite slaptažodį","text":"Enter password"}]}}
        """
        let r = try TranslationParser.parseClaude(Data(stream.utf8))
        XCTAssertEqual(r.results[0], TranslationResult(text: "Enter password", source: "Įveskite slaptažodį"))
    }

    func testClaudeStreamMessageCarriesImage() throws {
        let line = ClaudeCLITranslator.streamMessage(text: "hi", png: Data([1, 2, 3]))
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let content = (obj["message"] as! [String: Any])["content"] as! [[String: Any]]
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual((content.first?["source"] as? [String: Any])?["data"] as? String, "AQID")
        let args = ClaudeCLITranslator.arguments(system: "s", schema: "{}", model: "", streaming: true)
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertFalse(args.contains("json"))
    }

    func testPNGDownscalesLongEdge() throws {
        let ctx = CGContext(data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = try XCTUnwrap(ImageEncoding.png(ctx.makeImage()!))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 1568)
        XCTAssertEqual(rep.pixelsHigh, 392)
    }

    func testVisionPromptsAskForSource() {
        let ctx = TranslationContext(targetName: "English", sourceNames: ["Lithuanian"])
        XCTAssertTrue(TranslationPrompt.system(ctx, mode: .assist).contains("\"source\""))
        XCTAssertTrue(TranslationPrompt.system(ctx, mode: .readAll).contains("id 0"))
        XCTAssertFalse(TranslationPrompt.system(ctx).contains("image"))
        XCTAssertTrue(TranslationPrompt.schema(for: .assist).contains("source"))
    }
}

final class HUDPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = NSSize(width: 200, height: 30)

    func testBelowSelection() {
        let f = HUD.place(size: size, anchor: CGRect(x: 400, y: 400, width: 200, height: 100), in: screen)
        XCTAssertEqual(f, NSRect(x: 400, y: 362, width: 200, height: 30))
    }

    func testAboveWhenNoRoomBelowAndClampedToEdge() {
        let f = HUD.place(size: size, anchor: CGRect(x: 950, y: 10, width: 40, height: 100), in: screen)
        XCTAssertEqual(f.minY, 118)
        XCTAssertEqual(f.maxX, 992)
    }

    func testInsideWhenSelectionFillsScreen() {
        let f = HUD.place(size: size, anchor: screen, in: screen)
        XCTAssertEqual(f.maxY, 792)
    }
}

/// Calls the real CLIs. Run with:
/// TEST_RUNNER_INSTA_INTEGRATION=1 xcodebuild test -scheme Snipas -only-testing:SnipasTests/EngineIntegrationTests
final class EngineIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INSTA_INTEGRATION"] == "1", "integration tests disabled")
    }

    var png: Data {
        let img = NSImage(size: NSSize(width: 700, height: 120), flipped: false) { r in
            NSColor(white: 0.95, alpha: 1).setFill(); r.fill()
            ("Įveskite slaptažodį" as NSString).draw(at: NSPoint(x: 20, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 30)])
            ("Užsakymo būsena: išsiųsta" as NSString).draw(at: NSPoint(x: 20, y: 15), withAttributes: [.font: NSFont.systemFont(ofSize: 30)])
            return true
        }
        return ImageEncoding.png(img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)!
    }
    let ctx = TranslationContext(targetName: "English", sourceNames: ["Lithuanian"])
    let items = [TranslationItem(id: 0, text: "[veskite slaptažodj"), TranslationItem(id: 1, text: "Užsakymo büsena: išsiysta")]

    func check(_ t: Translator) async throws {
        let assist = try await t.translate(items, context: ctx, mode: .assist, image: png)
        print("assist:", assist)
        XCTAssertEqual(assist.results[0]?.source, "Įveskite slaptažodį")
        XCTAssertEqual(assist.results[1]?.source, "Užsakymo būsena: išsiųsta")
        XCTAssertTrue(assist.results[1]?.text.lowercased().contains("order") ?? false)

        let readAll = try await t.translate([], context: ctx, mode: .readAll, image: png)
        print("readAll:", readAll)
        XCTAssertTrue(readAll.results[0]?.source?.contains("slaptažodį") ?? false)
        XCTAssertTrue(readAll.results[0]?.text.lowercased().contains("password") ?? false)

        // Only the first line is given; the second must come back as an extra near the bottom half.
        let partial = try await t.translate([TranslationItem(id: 0, text: "[veskite slaptažodj",
                                                             box: NormBox(x: 0.02, y: 0.1, w: 0.45, h: 0.3))],
                                            context: ctx, mode: .assist, image: png)
        print("partial:", partial)
        XCTAssertEqual(partial.results[0]?.source, "Įveskite slaptažodį")
        let extra = try XCTUnwrap(partial.extras.first { $0.source.contains("būsena") })
        XCTAssertTrue(extra.text.lowercased().contains("order"))
        XCTAssertGreaterThan(extra.box.y + extra.box.h / 2, 0.5)
        XCTAssertFalse(partial.extras.contains { $0.source.contains("slaptažod") }, "re-listed a covered line")

        let plain = try await t.translate([TranslationItem(id: 3, text: "Prisijungti")], context: ctx)
        print("plain:", plain)
        XCTAssertNotNil(plain.results[3])
        XCTAssertEqual(plain.language, "Lithuanian")
        XCTAssertEqual(assist.language, "Lithuanian")
    }

    func testClaude() async throws { try await check(ClaudeCLITranslator(pathOverride: "", model: "haiku", timeout: 120)) }
    func testCodex() async throws { try await check(CodexCLITranslator(pathOverride: "", model: "", timeout: 180)) }
}


final class ExtrasTests: XCTestCase {
    func testParsesExtrasAndClampsBoxes() throws {
        let json = #"{"translations":[{"id":0,"source":"A","text":"B"}],"extra":[{"source":"Akcija","text":"Sale","box":{"x":0.8,"y":0.5,"w":0.5,"h":0.1}},{"source":"","text":"","box":{"x":0,"y":0,"w":0.1,"h":0.1}}]}"#
        let out = try TranslationParser.parsePayload(json)
        XCTAssertEqual(out.results[0]?.text, "B")
        XCTAssertEqual(out.extras, [ExtraText(source: "Akcija", text: "Sale", box: NormBox(x: 0.8, y: 0.5, w: 0.2, h: 0.1))])
    }

    func testMissingExtraKeyIsFine() throws {
        XCTAssertEqual(try TranslationParser.parsePayload(#"{"translations":[]}"#).extras, [])
    }

    func testItemEncodingOmitsBoxWhenNil() throws {
        let plain = String(decoding: try JSONEncoder().encode(TranslationItem(id: 1, text: "x")), as: UTF8.self)
        XCTAssertFalse(plain.contains("box"))
        let withBox = String(decoding: try JSONEncoder().encode(
            TranslationItem(id: 1, text: "x", box: NormBox(x: 0.12345, y: 0, w: 0.5, h: 0.25))), as: UTF8.self)
        XCTAssertTrue(withBox.contains("0.123"))
    }

    func testNormBoxFromScreenRect() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 200) // AppKit, bottom-left origin
        let b = NormBox(rect: CGRect(x: 200, y: 250, width: 100, height: 20), in: frame)!
        XCTAssertEqual(b, NormBox(x: 0.25, y: 0.15, w: 0.25, h: 0.1)) // 300-270=30 from top → 0.15
        XCTAssertEqual(b.pixelRect(width: 800, height: 400), CGRect(x: 200, y: 60, width: 200, height: 40))
        XCTAssertNil(NormBox(rect: CGRect(x: 0, y: 0, width: 10, height: 10), in: frame))
    }

    func testAssistPromptAndSchemaMentionExtras() {
        let ctx = TranslationContext(targetName: "English", sourceNames: [])
        XCTAssertTrue(TranslationPrompt.system(ctx, mode: .assist).contains("\"extra\""))
        XCTAssertTrue(TranslationPrompt.schema(for: .assist).contains("\"extra\""))
        XCTAssertFalse(TranslationPrompt.schema(for: .readAll).contains("\"extra\""))
    }
}

final class BoxSnapperTests: XCTestCase {
    /// White canvas with black text drawn at a known spot (top-left pixel coords returned).
    func canvas(text: String, at p: NSPoint, size: CGFloat = 28) -> (CGImage, CGRect) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 200, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 200).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
        (text as NSString).draw(at: p, withAttributes: attrs)
        let sz = (text as NSString).size(withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        // Convert bottom-left drawing rect to top-left pixel space.
        return (rep.cgImage!, CGRect(x: p.x, y: 200 - p.y - sz.height, width: sz.width, height: sz.height))
    }

    func testInkBoundsFindsTextAndIgnoresAvoided() throws {
        let (img, truth) = canvas(text: "Akcija -50%", at: NSPoint(x: 300, y: 40))
        let ink = try XCTUnwrap(BoxSnapper.inkBounds(in: img, region: CGRect(x: 250, y: 80, width: 340, height: 110), avoid: []))
        XCTAssertTrue(truth.insetBy(dx: -2, dy: -2).contains(ink), "\(ink) vs \(truth)")
        XCTAssertGreaterThan(ink.width, truth.width * 0.8)
        XCTAssertNil(BoxSnapper.inkBounds(in: img, region: CGRect(x: 250, y: 80, width: 340, height: 110),
                                          avoid: [truth.insetBy(dx: -4, dy: -4)]))
    }

    func testSnapTightensSloppyModelBox() async {
        let (img, truth) = canvas(text: "Nemokamas pristatymas", at: NSPoint(x: 120, y: 60))
        let sloppy = truth.insetBy(dx: -30, dy: -12).offsetBy(dx: 15, dy: 8)
        let (snapped, method) = await BoxSnapper.snap(sloppy, in: img, avoid: [], sources: ["lt"], target: "en")
        XCTAssertNotEqual(method, .model)
        XCTAssertLessThan(abs(snapped.midY - truth.midY), truth.height * 0.3, "\(snapped) vs \(truth)")
        XCTAssertLessThan(abs(snapped.height - truth.height), truth.height * 0.5)
    }
}


final class LanguageFieldTests: XCTestCase {
    func testParsesLanguage() throws {
        let out = try TranslationParser.parsePayload(#"{"language":" Lithuanian ","translations":[{"id":0,"text":"Hi"}]}"#)
        XCTAssertEqual(out.language, "Lithuanian")
        XCTAssertNil(try TranslationParser.parsePayload(#"{"language":"","translations":[]}"#).language)
    }

    func testAllSchemasRequireLanguage() {
        for mode in [VisionMode.none, .assist, .readAll] {
            XCTAssertTrue(TranslationPrompt.schema(for: mode).contains(#""required":["language","translations""#), "\(mode)")
        }
        let ctx = TranslationContext(targetName: "English", sourceNames: ["Lithuanian"])
        XCTAssertTrue(TranslationPrompt.system(ctx).contains("\"language\""))
    }
}

@MainActor
final class HUDLayoutTests: XCTestCase {
    func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

    func testSpinnerHugsLeadingEdge() throws {
        for text in ["Reading selection…", "Reading the image with Claude Code…"] {
            try check(text)
        }
    }

    func check(_ text: String) throws {
        let hud = HUD()
        // Long status with buttons first, so the reused panel starts wide.
        hud.show("Lithuanian → English · 12 translated · Claude Code", actions: [HUD.Action(title: "Use image") {}], closable: true)
        hud.show(text, busy: true)
        defer { hud.hide() }
        let root = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }?.contentView)
        root.layoutSubtreeIfNeeded()
        let spinner = try XCTUnwrap(allSubviews(root).first { $0 is NSProgressIndicator })
        let label = try XCTUnwrap(allSubviews(root).first { ($0 as? NSTextField)?.stringValue == text })
        let s = spinner.convert(spinner.bounds, to: root), l = label.convert(label.bounds, to: root)
        print("HUD spinner:", s, "label:", l, "root:", root.bounds, text)
        XCTAssertEqual(s.minX, 10)
        XCTAssertLessThanOrEqual(s.width, 18)
        XCTAssertLessThanOrEqual(l.minX - s.maxX, 8)
        // Right gutter roughly matches the left one.
        XCTAssertEqual(root.bounds.maxX - l.maxX, 14, accuracy: 3)
    }
}


@MainActor
final class ScanningOverlayTests: XCTestCase {
    func testScanningCoversWholeRegionAndClears() {
        let overlay = OverlayController()
        let rect = CGRect(x: 100, y: 100, width: 400, height: 250)
        overlay.showScanning(rect)
        let panel = NSApp.windows.first { $0.isVisible && $0.contentView is ScanningView }
        XCTAssertEqual(panel?.frame, rect)
        XCTAssertEqual(panel?.ignoresMouseEvents, true)
        overlay.dismissAll()
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.contentView is ScanningView })
    }
}
