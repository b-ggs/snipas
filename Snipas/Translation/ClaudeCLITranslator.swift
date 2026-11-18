import Foundation

struct ClaudeCLITranslator: Translator {
    var pathOverride: String
    var model: String
    var timeout: TimeInterval

    /// Flags that keep each call tiny: no tools, MCP servers, skills, CLAUDE.md
    /// or session files, and our own system prompt instead of the agent's.
    /// With an image, input must be stream-json, which requires stream-json output.
    static func arguments(system: String, schema: String, model: String, streaming: Bool) -> [String] {
        var args = ["-p",
                    "--safe-mode",
                    "--strict-mcp-config",
                    "--tools", "",
                    "--disable-slash-commands",
                    "--no-session-persistence",
                    "--system-prompt", system,
                    "--json-schema", schema]
        if streaming {
            args += ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        } else {
            args += ["--output-format", "json"]
        }
        let m = model.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { args += ["--model", m] }
        return args
    }

    /// One stream-json user message carrying the image and the prompt.
    static func streamMessage(text: String, png: Data) -> String {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                 "data": png.base64EncodedString()]],
                    ["type": "text", "text": text],
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    func translate(_ items: [TranslationItem], context: TranslationContext,
                   mode: VisionMode, image: Data?) async throws -> TranslationOutput {
        guard let path = CLIRunner.resolve("claude", override: pathOverride) else { throw CLIError.notFound("claude") }
        let useImage = mode != .none && image != nil
        let effectiveMode = useImage ? mode : .none
        let prompt = TranslationPrompt.user(items, mode: effectiveMode)
        let out = try await CLIRunner.run(
            path,
            args: Self.arguments(system: TranslationPrompt.system(context, mode: effectiveMode),
                                 schema: TranslationPrompt.schema(for: effectiveMode),
                                 model: model, streaming: useImage),
            stdin: useImage ? Self.streamMessage(text: prompt, png: image!) : prompt,
            timeout: timeout)
        return try TranslationParser.parseClaude(out)
    }
}
