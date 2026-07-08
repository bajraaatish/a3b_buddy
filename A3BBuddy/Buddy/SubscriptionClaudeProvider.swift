//
//  SubscriptionClaudeProvider.swift
//  Claude transport that rides the user's Claude Code subscription login.
//
//  Replaces the old HTTP streaming transport. Instead of
//  calling the Anthropic HTTP API with an API key, this spawns the local
//  `claude` CLI in headless mode (`claude -p`) and streams its stream-json
//  output. Authentication is whatever the user's Claude Code login already
//  has — no key ever touches this app.
//
//  Interface mirrors the previous analyzeImageStreaming contract so CompanionManager's
//  response pipeline (accumulated-text chunks, POINT-tag parsing, history)
//  does not need to know the transport changed.
//

import Foundation

/// Errors surfaced to the UI with actionable, user-readable messages.
enum SubscriptionClaudeProviderError: LocalizedError {
    /// The `claude` binary could not be found in any of the known install locations.
    case claudeCodeBinaryNotFound
    /// The CLI ran but reported an error result (e.g. not logged in, rate limited).
    case claudeCLIReportedError(String)
    /// The CLI exited without producing a result event.
    case claudeCLIProducedNoResult(exitCode: Int32, standardErrorText: String)

    var errorDescription: String? {
        switch self {
        case .claudeCodeBinaryNotFound:
            return "Claude Code not found. Install it from https://claude.com/claude-code, then run `claude` once in a terminal to log in."
        case .claudeCLIReportedError(let message):
            if message.lowercased().contains("log in") || message.lowercased().contains("login") || message.lowercased().contains("authent") {
                return "Claude Code isn't logged in. Run `claude` in a terminal to log in, then try again."
            }
            return "Claude Code error: \(message)"
        case .claudeCLIProducedNoResult(let exitCode, let standardErrorText):
            return "Claude Code exited (code \(exitCode)) without a response. \(standardErrorText)"
        }
    }
}

/// Streams Claude responses by spawning the local `claude` CLI per request.
///
/// Conversation memory: CompanionManager passes the (already trimmed) exchange
/// history explicitly, so each spawn is stateless — history is prepended to the
/// system prompt as a plain transcript instead of resuming a CLI session. This
/// keeps the 10-exchange trim authoritative, survives CLI session deletion, and
/// lets us pass --no-session-persistence so no conversation transcript is ever
/// written to disk (privacy requirement for Phase 4).
class SubscriptionClaudeProvider {

    /// Model identifier passed to `--model`. Accepts the same values the app's
    /// model picker already stores (e.g. "claude-sonnet-4-6"); mapped to CLI
    /// aliases in `commandLineModelArgument`.
    var model: String

    /// Resolved path to the `claude` binary. Discovered once, lazily, because
    /// GUI apps launch with a minimal PATH that does not include user bins.
    private static let discoveredClaudeBinaryPath: String? = discoverClaudeBinaryPath()

    init(model: String) {
        self.model = model
    }

    // MARK: - Binary discovery

    /// Looks for the `claude` binary in the standard install locations.
    /// GUI apps inherit PATH=/usr/bin:/bin:/usr/sbin:/sbin, so we cannot rely
    /// on the user's shell PATH. Checked in order of how the official
    /// installers place it.
    private static func discoverClaudeBinaryPath() -> String? {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let candidateBinaryPaths = [
            "\(homeDirectoryPath)/.local/bin/claude",      // native installer (current)
            "\(homeDirectoryPath)/.claude/local/claude",   // older native installer
            "/opt/homebrew/bin/claude",                    // Homebrew (Apple Silicon)
            "/usr/local/bin/claude",                       // Homebrew (Intel) / npm -g
            "\(homeDirectoryPath)/.npm-global/bin/claude"  // npm custom prefix
        ]
        for candidateBinaryPath in candidateBinaryPaths {
            if FileManager.default.isExecutableFile(atPath: candidateBinaryPath) {
                return candidateBinaryPath
            }
        }
        // Last resort: ask a login shell, which has the user's real PATH.
        let loginShellLookup = Process()
        loginShellLookup.executableURL = URL(fileURLWithPath: "/bin/zsh")
        loginShellLookup.arguments = ["-lc", "command -v claude"]
        let lookupOutputPipe = Pipe()
        loginShellLookup.standardOutput = lookupOutputPipe
        loginShellLookup.standardError = Pipe()
        do {
            try loginShellLookup.run()
            loginShellLookup.waitUntilExit()
            let lookupOutputData = lookupOutputPipe.fileHandleForReading.readDataToEndOfFile()
            let resolvedPath = String(data: lookupOutputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !resolvedPath.isEmpty, FileManager.default.isExecutableFile(atPath: resolvedPath) {
                return resolvedPath
            }
        } catch {
            // Fall through to nil — caller surfaces claudeCodeBinaryNotFound
        }
        return nil
    }

    /// True when the `claude` binary was found. CompanionManager can check this
    /// at startup to show the "Claude Code not found" panel state early.
    static var isClaudeCodeInstalled: Bool {
        return discoveredClaudeBinaryPath != nil
    }

    /// Maps the app's stored model identifiers to CLI `--model` arguments.
    /// The CLI accepts aliases ("sonnet", "opus") that track the latest models,
    /// which is what we want — no hardcoded dated model IDs.
    private var commandLineModelArgument: String {
        let lowercasedModelIdentifier = model.lowercased()
        if lowercasedModelIdentifier.contains("opus") { return "opus" }
        if lowercasedModelIdentifier.contains("sonnet") { return "sonnet" }
        return model
    }

    // MARK: - Image MIME detection

    /// Screen captures from ScreenCaptureKit are JPEG, pasted images are PNG.
    /// The API rejects mismatched media_type declarations.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    // MARK: - Streaming request

    /// Sends a vision request through the local `claude` CLI with streaming.
    /// Calls `onTextChunk` on the main actor with the ACCUMULATED text each
    /// time a new text delta arrives.
    /// Returns the full text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartTime = Date()

        guard let claudeBinaryPath = Self.discoveredClaudeBinaryPath else {
            throw SubscriptionClaudeProviderError.claudeCodeBinaryNotFound
        }

        // History goes into the system prompt as a transcript (see class doc).
        let systemPromptWithHistory = Self.buildSystemPromptWithHistory(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory
        )

        // Build the single stream-json user message: labeled images + prompt.
        var userMessageContentBlocks: [[String: Any]] = []
        for image in images {
            userMessageContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            userMessageContentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        userMessageContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        let streamJSONInputEnvelope: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": userMessageContentBlocks
            ]
        ]
        var streamJSONInputData = try JSONSerialization.data(withJSONObject: streamJSONInputEnvelope)
        streamJSONInputData.append(0x0A) // stream-json input is newline-delimited

        let payloadMegabytes = Double(streamJSONInputData.count) / 1_048_576.0
        print("🧠 SubscriptionClaude request: \(String(format: "%.1f", payloadMegabytes))MB, \(images.count) image(s), model \(commandLineModelArgument)")

        let claudeCLIProcess = Process()
        claudeCLIProcess.executableURL = URL(fileURLWithPath: claudeBinaryPath)
        claudeCLIProcess.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            // The buddy answers from the screenshot alone — no tools. This also
            // guarantees single-turn responses (no agent loop latency).
            "--disallowedTools", "*",
            "--max-turns", "1",
            // Do NOT load the user's ~/.claude settings: their personal hooks
            // and output styles would leak into (and corrupt) buddy responses.
            "--setting-sources", "",
            // Never write conversation transcripts (with screenshots) to disk.
            "--no-session-persistence",
            "--model", commandLineModelArgument,
            "--system-prompt", systemPromptWithHistory
        ]
        // Run from a neutral directory so the CLI never picks up a project's
        // CLAUDE.md or .claude/ directory as context.
        claudeCLIProcess.currentDirectoryURL = FileManager.default.temporaryDirectory

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        claudeCLIProcess.standardInput = standardInputPipe
        claudeCLIProcess.standardOutput = standardOutputPipe
        claudeCLIProcess.standardError = standardErrorPipe

        return try await withTaskCancellationHandler(operation: {
            try claudeCLIProcess.run()

            // Feed the request and close stdin so the CLI knows input is done.
            try standardInputPipe.fileHandleForWriting.write(contentsOf: streamJSONInputData)
            try standardInputPipe.fileHandleForWriting.close()

            var accumulatedResponseText = ""
            var finalResultText: String?
            var cliReportedErrorMessage: String?
            var hasLoggedFirstTextChunk = false

            // Read stdout line by line; every line is one stream-json event.
            for try await outputLine in standardOutputPipe.fileHandleForReading.bytes.lines {
                guard let eventData = outputLine.data(using: .utf8),
                      let eventPayload = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                      let eventType = eventPayload["type"] as? String else {
                    continue
                }

                switch eventType {
                case "stream_event":
                    // Partial message chunk — extract text deltas only
                    // (thinking deltas are skipped; they are not spoken).
                    if let innerEvent = eventPayload["event"] as? [String: Any],
                       let innerEventType = innerEvent["type"] as? String,
                       innerEventType == "content_block_delta",
                       let delta = innerEvent["delta"] as? [String: Any],
                       let deltaType = delta["type"] as? String,
                       deltaType == "text_delta",
                       let textChunk = delta["text"] as? String {
                        if !hasLoggedFirstTextChunk, !textChunk.isEmpty {
                            hasLoggedFirstTextChunk = true
                            let firstTextChunkDuration = Date().timeIntervalSince(requestStartTime)
                            print("🧠 SubscriptionClaude TTFT: \(String(format: "%.1f", firstTextChunkDuration))s")
                        }
                        accumulatedResponseText += textChunk
                        let currentAccumulatedText = accumulatedResponseText
                        await onTextChunk(currentAccumulatedText)
                    }
                case "result":
                    let resultIsError = (eventPayload["is_error"] as? Bool) ?? false
                    let resultText = eventPayload["result"] as? String
                    if resultIsError {
                        cliReportedErrorMessage = resultText ?? "unknown error"
                    } else {
                        finalResultText = resultText
                    }
                default:
                    break // system/init, rate_limit_event, assistant snapshots — not needed
                }
            }

            claudeCLIProcess.waitUntilExit()

            if let cliReportedErrorMessage {
                throw SubscriptionClaudeProviderError.claudeCLIReportedError(cliReportedErrorMessage)
            }

            // Prefer the result event's authoritative full text; fall back to
            // the accumulated deltas if the result event was missing text.
            guard let responseText = finalResultText ?? (accumulatedResponseText.isEmpty ? nil : accumulatedResponseText) else {
                let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let standardErrorText = String(data: standardErrorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw SubscriptionClaudeProviderError.claudeCLIProducedNoResult(
                    exitCode: claudeCLIProcess.terminationStatus,
                    standardErrorText: standardErrorText
                )
            }

            let requestDuration = Date().timeIntervalSince(requestStartTime)
            print("🧠 SubscriptionClaude response: \(responseText.count) chars in \(String(format: "%.1f", requestDuration))s")
            return (text: responseText, duration: requestDuration)
        }, onCancel: {
            // CompanionManager cancels the response task when a new push-to-talk
            // begins — kill the subprocess so it stops consuming the subscription.
            claudeCLIProcess.terminate()
        })
    }

    /// Non-streaming variant kept for interface parity with the streaming method.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        return try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: { _ in }
        )
    }

    // MARK: - History encoding

    /// Appends prior exchanges to the system prompt as a plain transcript.
    /// The CLI process is stateless per request, so this is how the buddy
    /// "remembers everything they've said before" (see system prompt).
    private static func buildSystemPromptWithHistory(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    ) -> String {
        guard !conversationHistory.isEmpty else { return systemPrompt }
        var transcriptLines: [String] = []
        for exchange in conversationHistory {
            transcriptLines.append("user: \(exchange.userPlaceholder)")
            transcriptLines.append("you: \(exchange.assistantResponse)")
        }
        let historyTranscript = transcriptLines.joined(separator: "\n")
        return systemPrompt + "\n\nconversation so far (for context — continue it naturally):\n" + historyTranscript
    }
}
