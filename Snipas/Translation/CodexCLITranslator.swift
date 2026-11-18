import Foundation

struct CodexCLITranslator: Translator {
    var pathOverride: String
    var model: String
    var timeout: TimeInterval

    func translate(_ items: [TranslationItem], context: TranslationContext,
                   mode: VisionMode, image: Data?) async throws -> TranslationOutput {
        guard let path = CLIRunner.resolve("codex", override: pathOverride) else { throw CLIError.notFound("codex") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snipas/codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let effectiveMode = (mode != .none && image != nil) ? mode : .none
        let schemaURL = dir.appendingPathComponent("schema.json")
        let outURL = dir.appendingPathComponent("out.json")
        try Data(TranslationPrompt.schema(for: effectiveMode).utf8).write(to: schemaURL)

        var args = ["exec",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "--sandbox", "read-only",
                    "--color", "never",
                    "-c", "model_reasoning_effort=\"low\"",
                    "--output-schema", schemaURL.path,
                    "-o", outURL.path]
        if effectiveMode != .none, let image {
            let imageURL = dir.appendingPathComponent("selection.png")
            try image.write(to: imageURL)
            args += ["-i", imageURL.path]
        }
        let m = model.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { args += ["-m", m] }
        args.append("-")

        let prompt = TranslationPrompt.system(context, mode: effectiveMode) + "\n\n"
            + TranslationPrompt.user(items, mode: effectiveMode)
        let stdout = try await CLIRunner.run(path, args: args, stdin: prompt, timeout: timeout)
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? String(decoding: stdout, as: UTF8.self)
        return try TranslationParser.parsePayload(text)
    }
}
