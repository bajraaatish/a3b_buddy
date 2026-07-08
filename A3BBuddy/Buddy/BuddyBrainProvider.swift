//
//  BuddyBrainProvider.swift
//  Pluggable "brain" layer — Conductor-style multi-model support.
//
//  The buddy's brain is whichever coding-agent CLI the user already pays for:
//  Claude Code (Anthropic subscription), Codex CLI (ChatGPT subscription), or
//  Gemini CLI (Google AI subscription). Each provider spawns its vendor's CLI
//  headlessly and rides that login — the app itself never holds a key and
//  never talks to a model API directly.
//
//  All providers share SubscriptionClaudeProvider's calling contract:
//  labeled screenshot images + system prompt + history + user prompt in,
//  accumulated-text chunks + final text out. CompanionManager picks the
//  provider from the model identifier via BuddyBrainProviderFactory.
//

import Foundation

/// A screen-aware conversational brain the buddy can use for responses.
protocol BuddyBrainProvider: AnyObject {
    /// Human-readable name for logs and the panel UI (e.g. "Claude (sonnet)").
    var displayName: String { get }

    /// Sends labeled screenshots + prompt, returns the full response text.
    /// `onTextChunk` receives the ACCUMULATED text so far whenever new text
    /// arrives; providers that cannot stream call it once with the full text.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

// MARK: - Shared helpers for CLI-backed providers

enum BuddyBrainCLISupport {
    /// Finds a CLI binary, checking well-known install locations first because
    /// GUI apps launch with a minimal PATH, then falling back to a login shell.
    static func discoverBinaryPath(named binaryName: String) -> String? {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let candidateBinaryPaths = [
            "\(homeDirectoryPath)/.local/bin/\(binaryName)",
            "\(homeDirectoryPath)/.npm-global/bin/\(binaryName)",
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)"
        ]
        for candidateBinaryPath in candidateBinaryPaths {
            if FileManager.default.isExecutableFile(atPath: candidateBinaryPath) {
                return candidateBinaryPath
            }
        }
        let loginShellLookup = Process()
        loginShellLookup.executableURL = URL(fileURLWithPath: "/bin/zsh")
        loginShellLookup.arguments = ["-lc", "command -v \(binaryName)"]
        let lookupOutputPipe = Pipe()
        loginShellLookup.standardOutput = lookupOutputPipe
        loginShellLookup.standardError = Pipe()
        do {
            try loginShellLookup.run()
            loginShellLookup.waitUntilExit()
            let resolvedPath = String(
                data: lookupOutputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !resolvedPath.isEmpty, FileManager.default.isExecutableFile(atPath: resolvedPath) {
                return resolvedPath
            }
        } catch {
            // Fall through to nil — callers surface a "not installed" error.
        }
        return nil
    }

    /// Writes screenshot data to temp files for CLIs that take image paths
    /// (Codex, Gemini) rather than inline base64. Returns the file URLs;
    /// callers must delete them after the request completes.
    static func writeImagesToTemporaryFiles(
        _ images: [(data: Data, label: String)]
    ) throws -> [URL] {
        var temporaryImageFileURLs: [URL] = []
        for (imageIndex, image) in images.enumerated() {
            let isPNG = image.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
            let fileExtension = isPNG ? "png" : "jpg"
            let temporaryImageFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("buddy-frame-\(ProcessInfo.processInfo.globallyUniqueString)-\(imageIndex + 1).\(fileExtension)")
            try image.data.write(to: temporaryImageFileURL)
            temporaryImageFileURLs.append(temporaryImageFileURL)
        }
        return temporaryImageFileURLs
    }

    static func deleteTemporaryFiles(_ fileURLs: [URL]) {
        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Builds the combined prompt for CLIs without a separate system-prompt
    /// flag: system rules + prior exchanges + image labels + the user's words.
    static func buildCombinedPrompt(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        imageLabels: [String],
        userPrompt: String
    ) -> String {
        var promptSections: [String] = []
        promptSections.append("<system rules — follow these exactly>\n\(systemPrompt)\n</system rules>")
        if !conversationHistory.isEmpty {
            var transcriptLines: [String] = []
            for exchange in conversationHistory {
                transcriptLines.append("user: \(exchange.userPlaceholder)")
                transcriptLines.append("you: \(exchange.assistantResponse)")
            }
            promptSections.append("conversation so far (continue it naturally):\n" + transcriptLines.joined(separator: "\n"))
        }
        if !imageLabels.isEmpty {
            promptSections.append("attached screenshot(s), in order: " + imageLabels.joined(separator: " | "))
        }
        promptSections.append("the user just said: \(userPrompt)")
        return promptSections.joined(separator: "\n\n")
    }
}

enum BuddyBrainProviderError: LocalizedError {
    case cliNotInstalled(cliName: String, installHint: String)
    case cliNotLoggedIn(cliName: String, loginHint: String)
    case cliFailed(cliName: String, exitCode: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled(let cliName, let installHint):
            return "\(cliName) not found. \(installHint)"
        case .cliNotLoggedIn(let cliName, let loginHint):
            return "\(cliName) isn't logged in. \(loginHint)"
        case .cliFailed(let cliName, let exitCode, let detail):
            return "\(cliName) failed (exit \(exitCode)). \(detail)"
        }
    }
}

// MARK: - Claude conformance

/// SubscriptionClaudeProvider already implements the exact method shape the
/// protocol requires; this just declares the conformance and display name.
extension SubscriptionClaudeProvider: BuddyBrainProvider {
    var displayName: String { "Claude (\(model))" }
}

// MARK: - Codex (ChatGPT subscription)

/// Brain via the Codex CLI (`codex exec`), riding the user's ChatGPT
/// login. Codex takes images as file paths and emits JSONL events; it does
/// not stream text deltas, so `onTextChunk` fires once with the full text.
final class SubscriptionCodexProvider: BuddyBrainProvider {

    private static let discoveredCodexBinaryPath: String? =
        BuddyBrainCLISupport.discoverBinaryPath(named: "codex")

    static var isInstalled: Bool { discoveredCodexBinaryPath != nil }

    /// Optional model override after "gpt-codex:" in the identifier; empty
    /// string means the CLI's default model (recommended).
    var model: String

    init(model: String = "") {
        self.model = model
    }

    var displayName: String { model.isEmpty ? "GPT (Codex)" : "GPT (\(model))" }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartTime = Date()

        guard let codexBinaryPath = Self.discoveredCodexBinaryPath else {
            throw BuddyBrainProviderError.cliNotInstalled(
                cliName: "Codex CLI",
                installHint: "Install with `npm install -g @openai/codex`, then run `codex` once to log in with ChatGPT."
            )
        }

        let temporaryImageFileURLs = try BuddyBrainCLISupport.writeImagesToTemporaryFiles(images)
        defer { BuddyBrainCLISupport.deleteTemporaryFiles(temporaryImageFileURLs) }

        let combinedPrompt = BuddyBrainCLISupport.buildCombinedPrompt(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            imageLabels: images.map { $0.label },
            userPrompt: userPrompt
        )

        var codexArguments = [
            "exec",
            // Never persist sessions, never load the user's personal config,
            // never let the agent run shell commands — answer from the image.
            "--ephemeral",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "-s", "read-only",
            "-C", FileManager.default.temporaryDirectory.path,
            "--json"
        ]
        if !model.isEmpty {
            codexArguments.append(contentsOf: ["-m", model])
        }
        for temporaryImageFileURL in temporaryImageFileURLs {
            // --image=PATH form: the variadic -i/--image flag would otherwise
            // swallow the prompt argument that follows.
            codexArguments.append("--image=\(temporaryImageFileURL.path)")
        }
        codexArguments.append("-") // read the prompt from stdin

        let codexProcess = Process()
        codexProcess.executableURL = URL(fileURLWithPath: codexBinaryPath)
        codexProcess.arguments = codexArguments

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        codexProcess.standardInput = standardInputPipe
        codexProcess.standardOutput = standardOutputPipe
        codexProcess.standardError = standardErrorPipe

        print("🧠 Codex request: \(images.count) image(s)\(model.isEmpty ? "" : ", model \(model)")")

        return try await withTaskCancellationHandler(operation: {
            try codexProcess.run()
            try standardInputPipe.fileHandleForWriting.write(contentsOf: Data(combinedPrompt.utf8))
            try standardInputPipe.fileHandleForWriting.close()

            var agentMessageText: String?
            for try await outputLine in standardOutputPipe.fileHandleForReading.bytes.lines {
                guard let eventData = outputLine.data(using: .utf8),
                      let eventPayload = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                    continue
                }
                // Final answer arrives as {"type":"item.completed","item":{"type":"agent_message","text":...}}
                if (eventPayload["type"] as? String) == "item.completed",
                   let completedItem = eventPayload["item"] as? [String: Any],
                   (completedItem["type"] as? String) == "agent_message",
                   let messageText = completedItem["text"] as? String {
                    agentMessageText = messageText
                }
            }
            codexProcess.waitUntilExit()

            guard let responseText = agentMessageText else {
                let standardErrorText = String(
                    data: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if standardErrorText.lowercased().contains("login") || standardErrorText.lowercased().contains("auth") {
                    throw BuddyBrainProviderError.cliNotLoggedIn(
                        cliName: "Codex CLI",
                        loginHint: "Run `codex` in a terminal and log in with your ChatGPT account."
                    )
                }
                throw BuddyBrainProviderError.cliFailed(
                    cliName: "Codex CLI",
                    exitCode: codexProcess.terminationStatus,
                    detail: standardErrorText
                )
            }

            await onTextChunk(responseText)
            let requestDuration = Date().timeIntervalSince(requestStartTime)
            print("🧠 Codex response: \(responseText.count) chars in \(String(format: "%.1f", requestDuration))s")
            return (text: responseText, duration: requestDuration)
        }, onCancel: {
            codexProcess.terminate()
        })
    }
}

// MARK: - Gemini (Google Antigravity subscription)

/// Brain via Google's Antigravity CLI (`agy --print`), riding the user's
/// Google login. Images are referenced with @path syntax inside the prompt.
/// Output is plain text on stdout; no streaming, so `onTextChunk` fires once.
final class SubscriptionGeminiProvider: BuddyBrainProvider {

    private static let discoveredGeminiBinaryPath: String? =
        BuddyBrainCLISupport.discoverBinaryPath(named: "agy")

    static var isInstalled: Bool { discoveredGeminiBinaryPath != nil }

    /// Optional model display name passed to `--model` (e.g. "Gemini 3.5
    /// Flash (Medium)", as listed by `agy models`); empty string uses the
    /// CLI default.
    var model: String

    init(model: String = "") {
        self.model = model
    }

    var displayName: String { model.isEmpty ? "Gemini" : "Gemini (\(model))" }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartTime = Date()

        guard let geminiBinaryPath = Self.discoveredGeminiBinaryPath else {
            throw BuddyBrainProviderError.cliNotInstalled(
                cliName: "Antigravity CLI",
                installHint: "Install the Antigravity CLI so `agy` is on your PATH, then run `agy` once to log in with Google."
            )
        }

        let temporaryImageFileURLs = try BuddyBrainCLISupport.writeImagesToTemporaryFiles(images)
        defer { BuddyBrainCLISupport.deleteTemporaryFiles(temporaryImageFileURLs) }

        // @path references make the CLI attach the image files to the prompt.
        let imageReferences = temporaryImageFileURLs.map { "@\($0.path)" }.joined(separator: " ")
        let combinedPrompt = imageReferences + "\n\n" + BuddyBrainCLISupport.buildCombinedPrompt(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            imageLabels: images.map { $0.label },
            userPrompt: userPrompt
        )

        // Sandbox = restricted: the buddy answers from the screenshot, it must
        // never edit files or run commands. Flags go before the prompt because
        // the CLI stops parsing flags after the first positional argument.
        var geminiArguments = ["--sandbox"]
        if !model.isEmpty {
            geminiArguments.append(contentsOf: ["--model", model])
        }
        geminiArguments.append(contentsOf: ["--print", combinedPrompt])

        let geminiProcess = Process()
        geminiProcess.executableURL = URL(fileURLWithPath: geminiBinaryPath)
        geminiProcess.arguments = geminiArguments
        // Neutral working directory so the CLI never ingests a project's
        // AGENTS.md or workspace files as context.
        geminiProcess.currentDirectoryURL = FileManager.default.temporaryDirectory

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        geminiProcess.standardOutput = standardOutputPipe
        geminiProcess.standardError = standardErrorPipe

        print("🧠 Gemini request: \(images.count) image(s)\(model.isEmpty ? "" : ", model \(model)")")

        return try await withTaskCancellationHandler(operation: {
            try geminiProcess.run()
            let outputData = await Task.detached {
                standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
            }.value
            geminiProcess.waitUntilExit()

            let responseText = (String(data: outputData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard geminiProcess.terminationStatus == 0, !responseText.isEmpty else {
                let standardErrorText = String(
                    data: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if standardErrorText.contains("Auth method") || standardErrorText.lowercased().contains("login") {
                    throw BuddyBrainProviderError.cliNotLoggedIn(
                        cliName: "Antigravity CLI",
                        loginHint: "Run `agy` in a terminal and log in with your Google account."
                    )
                }
                throw BuddyBrainProviderError.cliFailed(
                    cliName: "Antigravity CLI",
                    exitCode: geminiProcess.terminationStatus,
                    detail: standardErrorText
                )
            }

            await onTextChunk(responseText)
            let requestDuration = Date().timeIntervalSince(requestStartTime)
            print("🧠 Gemini response: \(responseText.count) chars in \(String(format: "%.1f", requestDuration))s")
            return (text: responseText, duration: requestDuration)
        }, onCancel: {
            geminiProcess.terminate()
        })
    }
}

// MARK: - Factory

enum BuddyBrainProviderFactory {
    /// Model identifiers the panel can offer. Claude identifiers keep their
    /// legacy "claude-…" form; other brains use a "vendor" or "vendor:model" form.
    ///   claude-sonnet-4-6 → Claude CLI, sonnet alias
    ///   claude-opus-4-1   → Claude CLI, opus alias
    ///   gpt-codex         → Codex CLI, default model
    ///   gpt-codex:MODEL   → Codex CLI, explicit model
    ///   gemini            → Antigravity CLI (agy), default model
    ///   gemini:MODEL      → Antigravity CLI (agy), explicit model display name
    static func makeProvider(forModelIdentifier modelIdentifier: String) -> any BuddyBrainProvider {
        let lowercasedIdentifier = modelIdentifier.lowercased()
        if lowercasedIdentifier.hasPrefix("gpt-codex") {
            let explicitModel = explicitModelSuffix(in: modelIdentifier)
            return SubscriptionCodexProvider(model: explicitModel)
        }
        if lowercasedIdentifier.hasPrefix("gemini") {
            let explicitModel = explicitModelSuffix(in: modelIdentifier)
            return SubscriptionGeminiProvider(model: explicitModel)
        }
        return SubscriptionClaudeProvider(model: modelIdentifier)
    }

    /// Which brains are usable on this machine right now (CLI installed).
    /// The panel uses this to grey out options the user hasn't installed.
    static var installedBrainSummary: String {
        var installedBrains = ["claude: \(SubscriptionClaudeProvider.isClaudeCodeInstalled)"]
        installedBrains.append("codex: \(SubscriptionCodexProvider.isInstalled)")
        installedBrains.append("gemini: \(SubscriptionGeminiProvider.isInstalled)")
        return installedBrains.joined(separator: ", ")
    }

    private static func explicitModelSuffix(in modelIdentifier: String) -> String {
        guard let colonIndex = modelIdentifier.firstIndex(of: ":") else { return "" }
        return String(modelIdentifier[modelIdentifier.index(after: colonIndex)...])
    }
}
