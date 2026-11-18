import Foundation

enum CLIError: LocalizedError {
    case notFound(String)
    case failed(String, Int32, String)
    case timeout(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return "Couldn't find the `\(n)` CLI. Install it or set its path in Settings."
        case .failed(let n, let code, let err): return "\(n) exited with code \(code): \(err.prefix(400))"
        case .timeout(let n): return "\(n) timed out."
        case .badOutput(let s): return "Couldn't parse translation output: \(s)"
        }
    }
}

enum CLIRunner {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPATH: String?

    /// PATH from the user's login shell (GUI apps get a minimal PATH).
    static func loginPATH() -> String {
        lock.lock(); defer { lock.unlock() }
        if let p = cachedPATH { return p }
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                      NSHomeDirectory() + "/.npm-global/bin", NSHomeDirectory() + "/.bun/bin",
                      "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            parts = String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
        }
        for e in extras where !parts.contains(e) { parts.append(e) }
        let joined = parts.joined(separator: ":")
        cachedPATH = joined
        return joined
    }

    static func resolve(_ name: String, override: String) -> String? {
        let fm = FileManager.default
        let o = (override as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty { return fm.isExecutableFile(atPath: o) ? o : nil }
        for dir in loginPATH().split(separator: ":") {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private final class Box: @unchecked Sendable { var out = Data(); var err = Data() }

    static func run(_ path: String, args: [String], stdin: String, timeout: TimeInterval) async throws -> Data {
        let name = (path as NSString).lastPathComponent
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("Snipas", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.currentDirectoryURL = workDir
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = loginPATH()
                env["NO_COLOR"] = "1"
                p.environment = env
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = errPipe
                do { try p.run() } catch {
                    cont.resume(throwing: CLIError.notFound(name)); return
                }
                let box = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()

                if group.wait(timeout: .now() + timeout) == .timedOut {
                    p.terminate()
                    _ = group.wait(timeout: .now() + 2)
                    cont.resume(throwing: CLIError.timeout(name)); return
                }
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let err = String(decoding: box.err.isEmpty ? box.out : box.err, as: UTF8.self)
                    cont.resume(throwing: CLIError.failed(name, p.terminationStatus, err.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
                cont.resume(returning: box.out)
            }
        }
    }
}
