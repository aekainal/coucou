import Foundation

// MARK: - Typed error for Claude Code calls

enum ClaudeCodeChatError: Error {
    /// The `claude` CLI could not be found on this Mac.
    case cliNotFound
    /// The CLI ran but reported an error (not logged in, rate limit, unknown model…).
    case cliError(String)

    var localizedDescription: String {
        switch self {
        case .cliNotFound:       return "Claude Code isn't installed. Install it, run `claude` once to log in, then ask again."
        case .cliError(let msg): return msg
        }
    }
}

// MARK: - Chat through the local Claude Code CLI (`claude -p`)

/// Runs the user's own Claude Code CLI in print mode, so the chat uses their Claude
/// subscription the way Claude Code itself does. Coucou never reads, stores or sends
/// any Claude credential: the CLI handles its own login.
enum ClaudeCodeChat {

    /// Model aliases understood by `claude --model`; they always point at the latest version.
    static let models: [(id: String, label: String)] = [
        (id: "sonnet", label: "Sonnet"),
        (id: "opus",   label: "Opus"),
        (id: "haiku",  label: "Haiku"),
    ]

    // MARK: CLI lookup

    /// Apps launched from Finder get a minimal PATH, so look in the usual install places.
    nonisolated static func findCLI() -> String? {
        #if APPSTORE
        return nil  // The App Store sandbox cannot launch other programs
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        #endif
    }

    static var isAvailable: Bool { findCLI() != nil }

    /// Empty working directory for the chat: no project CLAUDE.md, no repo files in reach.
    private nonisolated static var workDir: URL {
        let dir = HookServer.supportDir.appendingPathComponent("claude-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Streaming chat

    /// Sends one user turn to `claude -p` and streams the reply.
    ///
    /// - Parameters:
    ///   - prompt: The user's message, sent on stdin (never on the command line).
    ///   - model: A model alias from `models`.
    ///   - systemPrompt: Appended to Claude Code's own system prompt.
    ///   - resumeSessionID: The session of the previous turn, to keep the conversation going.
    ///   - onText: Called on the **main actor** with the visible text so far.
    /// - Returns: The final reply and the session ID to resume next turn.
    /// - Throws: `ClaudeCodeChatError`
    static func streamChat(
        prompt: String,
        model: String,
        systemPrompt: String,
        resumeSessionID: String?,
        onText: @MainActor @escaping (String) -> Void
    ) async throws -> (text: String, sessionID: String?) {
        guard let cli = findCLI() else { throw ClaudeCodeChatError.cliNotFound }

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--append-system-prompt", systemPrompt,
            // Chat only: web search, no file, shell or MCP tools.
            "--tools", "WebSearch",
            "--allowedTools", "WebSearch",
            "--strict-mcp-config",
            // Don't let our own hooks report this chat as an agent session in the notch.
            "--settings", #"{"disableAllHooks":true}"#,
        ]
        if let resumeSessionID { args += ["--resume", resumeSessionID] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        process.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        // An API key in the environment would make the CLI bill the API instead of the subscription.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let cliDir = (cli as NSString).deletingLastPathComponent
        env["PATH"] = [cliDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ClaudeCodeChatError.cliError("Couldn't start Claude Code: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        var accumulated = ""
        var finalText: String?
        var sessionID: String?
        var errorMessage: String?
        var lastUpdate = Date.distantPast
        let minInterval: TimeInterval = 1.0 / 15.0

        do {
            try await withTaskCancellationHandler {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let id = json["session_id"] as? String { sessionID = id }

                    switch json["type"] as? String {
                    case "stream_event":
                        guard let event = json["event"] as? [String: Any],
                              event["type"] as? String == "content_block_delta",
                              let delta = event["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let text = delta["text"] as? String else { continue }
                        accumulated += text
                        let now = Date()
                        if now.timeIntervalSince(lastUpdate) >= minInterval {
                            lastUpdate = now
                            let visible = accumulated
                            await MainActor.run { onText(visible) }
                        }
                    case "result":
                        let result = json["result"] as? String
                        if json["is_error"] as? Bool == true {
                            errorMessage = result ?? "Claude Code returned an error."
                        } else {
                            finalText = result
                        }
                    default:
                        continue
                    }
                }
            } onCancel: {
                process.terminate()
            }
        } catch {
            process.terminate()
            throw ClaudeCodeChatError.cliError("Lost the connection to Claude Code.")
        }
        process.waitUntilExit()

        if let errorMessage { throw ClaudeCodeChatError.cliError(errorMessage) }
        let text = (finalText ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ClaudeCodeChatError.cliError(errText.isEmpty
                ? "Claude Code didn't answer. Run `claude` in a terminal to check you're logged in."
                : String(errText.prefix(300)))
        }
        await MainActor.run { onText(text) }
        return (text, sessionID)
    }
}
