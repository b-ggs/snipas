import AppKit

@MainActor
final class TranslationPipeline {
    let overlay: OverlayController
    let hud: HUD
    private var generation = 0
    private(set) var isRunning = false
    var onRunningChange: ((Bool) -> Void)?

    nonisolated static let maxItemsPerChunk = 40
    nonisolated static let maxCharsPerChunk = 3500
    static let maxConcurrentChunks = 4

    init(overlay: OverlayController, hud: HUD) {
        self.overlay = overlay
        self.hud = hud
    }

    func cancel() {
        generation += 1
        setRunning(false)
    }

    private func setRunning(_ r: Bool) {
        isRunning = r
        onRunningChange?(r)
    }

    /// What's currently on screen, so "Use image" can improve it in place.
    private struct Pass {
        let generation: Int
        let region: CGRect?
        let settings: AppSettings
        let scan: Scan
        var language: String?
        var imageUsed = false
        var errors: [String] = []
    }
    private var pass: Pass?

    /// - Parameters:
    ///   - region: Global AppKit rect to translate (a snip). nil = all screens.
    ///   - frontmostPID: The app the user was in (the snip UI briefly takes focus).
    func run(region: CGRect? = nil, frontmostPID: pid_t? = nil) async {
        generation += 1
        let gen = generation
        pass = nil
        overlay.dismissAll()
        hud.anchor = region
        setRunning(true)
        defer { if gen == generation { setRunning(false) } }

        let settings = AppSettings.current()

        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            hud.show(CaptureError.noPermission.localizedDescription, isError: true, closable: true)
            return
        }

        hud.show(region == nil ? "Reading screens…" : "Reading selection…", busy: true)
        let scan: Scan
        do {
            scan = try await buildBlocks(settings: settings, region: region, frontmostPID: frontmostPID)
        } catch {
            hud.show(error.localizedDescription, isError: true, closable: true)
            return
        }
        guard gen == generation else { return }
        pass = Pass(generation: gen, region: region, settings: settings, scan: scan)

        guard !scan.blocks.isEmpty else {
            showStatus()
            return
        }

        overlay.show(scan.blocks)
        let items = scan.blocks.map { TranslationItem(id: $0.id, text: $0.text) }
        hud.show("Translating \(items.count) line\(items.count == 1 ? "" : "s") with \(settings.engine.displayName)…", busy: true)

        let outputs = await translate(Self.chunk(items), settings: settings, mode: .none, image: nil, gen: gen)
        guard gen == generation else { return }
        overlay.removePending()
        absorb(outputs)
        showStatus()
    }

    /// Re-translates the current selection with its screenshot attached: the model
    /// reads exact source text, fixes OCR mistakes, and adds text OCR missed.
    func useImage() async {
        guard var p = pass, p.generation == generation, !isRunning, let sel = p.scan.selection else { return }
        let gen = generation
        setRunning(true)
        defer { if gen == generation { setRunning(false) } }

        let blocks = p.scan.blocks
        let mode: VisionMode = blocks.isEmpty ? .readAll : .assist
        // The whole selection is being read, not just the boxes OCR found.
        overlay.showScanning(sel.frame)
        defer { if gen == generation { overlay.hideScanning() } }
        // Bring back boxes that were dropped as "unchanged" — the image may change that.
        // (For a whole-image read, the scanning outline stands in until the result arrives.)
        if mode == .assist { overlay.add(blocks.filter { !overlay.contains($0.id) }) }
        let items: [TranslationItem] = mode == .readAll ? [] : blocks.map {
            TranslationItem(id: $0.id, text: $0.text, box: NormBox(rect: $0.screenRect, in: sel.frame))
        }
        hud.show("Reading the image with \(p.settings.engine.displayName)…", busy: true)

        guard let png = ImageEncoding.png(sel.image) else { showStatus(); return }
        let outputs = await translate([items], settings: p.settings, mode: mode, image: png, gen: gen)
        guard gen == generation else { return }
        overlay.removePending()
        p.imageUsed = true
        pass = p
        absorb(outputs)
        if mode == .readAll, let r = outputs.first?.results[0] {
            overlay.add([Self.wholeSelectionBlock(sel)])
            overlay.setTranslation(r.text, source: r.source, for: 0)
        }

        let extras = outputs.flatMap(\.extras)
        if mode == .assist, !extras.isEmpty {
            let added = await placeExtras(extras, selection: sel, existing: blocks, settings: p.settings,
                                          firstID: (blocks.map(\.id).max() ?? -1) + 1)
            guard gen == generation else { return }
            overlay.add(added.map(\.0))
            for (block, extra) in added {
                overlay.setTranslation(extra.text, source: extra.source.isEmpty ? nil : extra.source, for: block.id)
            }
        }
        showStatus()
    }

    var canUseImage: Bool { pass.map { $0.generation == generation && $0.scan.selection != nil && !$0.imageUsed } ?? false }

    /// Runs chunks concurrently, applying results to the overlays as they arrive.
    private func translate(_ chunks: [[TranslationItem]], settings: AppSettings, mode: VisionMode,
                           image: Data?, gen: Int) async -> [TranslationOutput] {
        let translator = settings.makeTranslator()
        let context = settings.context
        var outputs: [TranslationOutput] = []
        var errors: [String] = []
        await withTaskGroup(of: Result<TranslationOutput, Error>.self) { group in
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    do { return .success(try await translator.translate(chunk, context: context, mode: mode, image: image)) }
                    catch { return .failure(error) }
                }
            }
            for _ in 0..<min(Self.maxConcurrentChunks, chunks.count) { addNext() }
            for await result in group {
                guard gen == generation else { group.cancelAll(); return }
                switch result {
                case .success(let output):
                    for (id, r) in output.results { overlay.setTranslation(r.text, source: r.source, for: id) }
                    outputs.append(output)
                case .failure(let error):
                    errors.append(error.localizedDescription)
                }
                addNext()
            }
        }
        if gen == generation { pass?.errors = errors }
        return outputs
    }

    private func absorb(_ outputs: [TranslationOutput]) {
        if let lang = outputs.compactMap(\.language).first { pass?.language = lang }
    }

    /// Persistent summary: "Lithuanian → English · 4 translated", plus buttons.
    private func showStatus() {
        guard let p = pass else { return }
        let target = Language.name(for: p.settings.target)
        var actions: [HUD.Action] = []
        if canUseImage {
            actions.append(HUD.Action(title: "Use image") { [weak self] in
                Task { await self?.useImage() }
            })
        }
        let engine = p.settings.engine.displayName + (p.imageUsed ? " + image" : "")

        if let error = p.errors.first {
            hud.show(error, isError: true, actions: actions, closable: true)
        } else if p.scan.blocks.isEmpty && !overlay.hasOverlays {
            hud.show(p.region == nil ? "No text found." : "No text found in the selection.",
                     actions: actions, closable: true)
        } else if !overlay.hasOverlays {
            hud.show("Already in \(target) · \(engine)", actions: actions, closable: true)
        } else {
            let source = p.language ?? p.settings.sources.first.map(Language.name(for:)) ?? "Auto"
            let n = overlay.count
            hud.show("\(source) → \(target) · \(n) translated · \(engine)", actions: actions, closable: true)
        }
    }

    struct Selection {
        let image: CGImage
        /// Pixel-aligned global AppKit rect of `image`.
        let frame: CGRect
    }

    struct Scan {
        var blocks: [TextBlock] = []
        /// The selected area (largest part if it spans displays); nil for full-screen passes.
        var selection: Selection?
    }

    /// One block covering the whole selection, for when OCR found nothing.
    static func wholeSelectionBlock(_ sel: Selection) -> TextBlock {
        let colors = ColorSampler.sample(sel.image, rect: CGRect(x: 0, y: 0, width: sel.image.width, height: sel.image.height))
        return TextBlock(id: 0, text: "", lineCount: 1, screenRect: sel.frame, original: sel.image,
                         background: colors.background, foreground: colors.foreground)
    }

    /// Turns the model's extra findings into snapped overlay blocks.
    private func placeExtras(_ extras: [ExtraText], selection sel: Selection, existing: [TextBlock],
                             settings: AppSettings, firstID: Int) async -> [(TextBlock, ExtraText)] {
        let img = sel.image
        let size = CGSize(width: img.width, height: img.height)
        // Existing boxes in selection-image pixels.
        var avoid: [CGRect] = existing.compactMap { b in
            NormBox(rect: b.screenRect, in: sel.frame)?.pixelRect(width: img.width, height: img.height)
        }
        var out: [(TextBlock, ExtraText)] = []
        var id = firstID
        for extra in extras {
            let rough = extra.box.pixelRect(width: img.width, height: img.height)
            // The model sometimes re-lists text we already have.
            if avoid.contains(where: { BoxSnapper.overlapFraction(rough, $0) > 0.5 }) { continue }
            let (snapped, _) = await BoxSnapper.snap(rough, in: img, avoid: avoid,
                                                     sources: settings.sources, target: settings.target)
            let pad = max(2, snapped.height * 0.08)
            let pixelRect = snapped.insetBy(dx: -pad, dy: -pad)
                .intersection(CGRect(origin: .zero, size: size)).integral
            guard pixelRect.width >= 4, pixelRect.height >= 4 else { continue }
            let colors = ColorSampler.sample(img, rect: pixelRect)
            var block = TextBlock(
                id: id,
                text: extra.source,
                lineCount: max(1, extra.source.split(separator: "\n").count),
                screenRect: Geometry.screenRect(fromPixel: pixelRect, imageSize: size, screenFrame: sel.frame),
                original: img.cropping(to: pixelRect),
                background: colors.background,
                foreground: colors.foreground)
            block.isApproximate = true
            out.append((block, extra))
            avoid.append(pixelRect)
            id += 1
        }
        return out
    }

    private func buildBlocks(settings: AppSettings, region: CGRect?, frontmostPID: pid_t?) async throws -> Scan {
        // Read the Accessibility tree concurrently with the screenshot.
        let snap = AccessibilityText.snapshot(frontmostPID: frontmostPID)
        let axTask = Task.detached(priority: .userInitiated) { AccessibilityText.collect(snap) }
        let displays = try await CaptureService.captureAll(intersecting: region)
        let ax = AXIndex(items: await axTask.value)

        var scan = Scan()
        var blocks: [TextBlock] = []
        var nextID = 0
        for display in displays {
            var image = display.image
            var frame = display.frame
            if let region {
                // Treat the selected part of this display as its own little "screen".
                let part = region.intersection(display.frame)
                let full = CGSize(width: image.width, height: image.height)
                let pixels = Geometry.pixelRect(fromScreen: part, imageSize: full, screenFrame: frame)
                guard !part.isEmpty, let crop = image.cropping(to: pixels) else { continue }
                image = crop
                // Use the pixel-aligned rect so overlays line up exactly with the crop.
                frame = Geometry.screenRect(fromPixel: pixels, imageSize: full, screenFrame: frame)
                if scan.selection.map({ $0.frame.width * $0.frame.height < frame.width * frame.height }) ?? true {
                    scan.selection = Selection(image: image, frame: frame)
                }
            }
            let size = CGSize(width: image.width, height: image.height)
            var lines = try await OCRService.recognize(image, sources: settings.sources, target: settings.target)
            // Swap OCR guesses for the exact on-screen strings where we can.
            for i in lines.indices {
                let rect = Geometry.screenRect(fromPixel: lines[i].rect, imageSize: size, screenFrame: frame)
                if let exact = TextMatcher.correct(lines[i].text, candidates: ax.candidates(near: rect)) {
                    lines[i].text = exact
                }
            }
            for group in BlockMerger.merge(lines) {
                let text = BlockMerger.join(group)
                // A snip is an explicit request: translate everything with letters in it.
                guard region == nil ? LanguageFilter.shouldTranslate(text, target: settings.target)
                                    : LanguageFilter.hasLetters(text) else { continue }
                let union = BlockMerger.union(group)
                let pad = max(2, union.height / CGFloat(group.count) * 0.12)
                let pixelRect = union.insetBy(dx: -pad, dy: -pad)
                    .intersection(CGRect(origin: .zero, size: size)).integral
                guard pixelRect.width >= 4, pixelRect.height >= 4 else { continue }
                let colors = ColorSampler.sample(image, rect: pixelRect)
                blocks.append(TextBlock(
                    id: nextID,
                    text: text,
                    lineCount: group.count,
                    screenRect: Geometry.screenRect(fromPixel: pixelRect, imageSize: size, screenFrame: frame),
                    original: image.cropping(to: pixelRect),
                    background: colors.background,
                    foreground: colors.foreground))
                nextID += 1
            }
        }
        scan.blocks = blocks
        return scan
    }

    nonisolated static func chunk(_ items: [TranslationItem]) -> [[TranslationItem]] {
        var chunks: [[TranslationItem]] = []
        var current: [TranslationItem] = []
        var chars = 0
        for item in items {
            if !current.isEmpty, current.count >= maxItemsPerChunk || chars + item.text.count > maxCharsPerChunk {
                chunks.append(current)
                current = []
                chars = 0
            }
            current.append(item)
            chars += item.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
