//
//  SubprocessOutputSupport.swift
//  a3b Buddy
//
//  Shared plumbing for the CLI brain providers (Claude Code, Codex, Antigravity).
//

import Foundation

/// Drains a child process's stderr *while it runs*, instead of after.
///
/// A pipe has a ~64 KB kernel buffer. Every provider reads the child's stdout to
/// completion and only then looks at stderr — so a child that writes more than
/// 64 KB of diagnostics blocks on the stderr write, stops producing stdout, the
/// stdout read never ends, `waitUntilExit()` is never reached, and the request
/// hangs until the user cancels.
///
/// Attach right after `run()`; call `text()` once the process has exited (it
/// reads to EOF, so calling it while the child is alive would block).
final class SubprocessErrorOutputAccumulator: @unchecked Sendable {
    private let readHandle: FileHandle
    private let lock = NSLock()
    private var accumulatedData = Data()

    init(draining errorPipe: Pipe) {
        readHandle = errorPipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil // EOF — the child closed stderr.
                return
            }
            self?.append(chunk)
        }
    }

    /// Everything the child wrote to stderr, trimmed. Call after it has exited.
    func text() -> String {
        stopDraining()
        if let remainingData = try? readHandle.readToEnd(), !remainingData.isEmpty {
            append(remainingData)
        }
        lock.lock()
        defer { lock.unlock() }
        return String(data: accumulatedData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Detaches the dispatch source without reading. The success paths never look
    /// at stderr, and the handler must not outlive the request.
    func stopDraining() {
        readHandle.readabilityHandler = nil
    }

    private func append(_ chunk: Data) {
        lock.lock()
        accumulatedData.append(chunk)
        lock.unlock()
    }
}
