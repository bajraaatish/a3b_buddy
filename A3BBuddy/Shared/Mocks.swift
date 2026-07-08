//
//  Mocks.swift
//  Whisper
//
//  Stand-ins for Workstream A (engine) and C (store) so the frontend is
//  buildable and previewable before the real implementations exist.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Mock engine

final class MockDictationEngine: DictationEngine {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var audioLevel: Float = 0

    /// Transcription delay so the pill's "transcribing" state is visible in previews.
    var transcribeDelay: TimeInterval = 0.8

    private var levelTimer: Timer?
    private var recordingStart: Date?
    private var cannedIndex = 0

    private static let cannedTranscripts = [
        "Hey, just checking in on the portfolio site — can you send me the latest Figma link when you get a chance?",
        "Add a task to review the insertion edge cases in Terminal and VS Code tomorrow morning.",
        "The pill overlay should fade out in about 150 milliseconds, anything slower feels laggy.",
        "Order more coffee beans, the light roast from the place on the corner.",
        "Reminder that WPM is words divided by recording minutes, computed once at save time.",
    ]

    /// Mirrors `RealDictationEngine`'s prewarm pair so `typealias ActiveEngine`
    /// can still flip. There is no mic to warm.
    func prewarmRecording() {}
    func discardPrewarm() {}

    func startRecording() {
        guard case .idle = state else { return }
        recordingStart = .now
        state = .recording(startedAt: recordingStart!)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Smoothed noise that looks like speech: mostly mid, occasional peaks and dips.
                let target = Float.random(in: 0 ... 1) < 0.15 ? Float.random(in: 0 ... 0.1) : Float.random(in: 0.2 ... 0.95)
                self.audioLevel = self.audioLevel * 0.7 + target * 0.3
            }
        }
    }

    /// Preview helper: enter `.recording` without the simulated-speech
    /// timer, so `PillView` previews can show the held-but-silent state
    /// distinctly from the talking state.
    func startRecordingSilently() {
        guard case .idle = state else { return }
        recordingStart = .now
        state = .recording(startedAt: recordingStart!)
    }

    func stopAndTranscribe() async -> DictationResult? {
        guard case .recording = state, let start = recordingStart else { return nil }
        stopLevelTimer()
        state = .transcribing
        try? await Task.sleep(nanoseconds: UInt64(transcribeDelay * 1_000_000_000))
        let text = Self.cannedTranscripts[cannedIndex % Self.cannedTranscripts.count]
        cannedIndex += 1
        state = .idle
        return DictationResult(
            text: text,
            duration: max(Date.now.timeIntervalSince(start), 1.5),
            targetAppBundleID: "com.apple.Notes",
            targetAppName: "Notes"
        )
    }

    func cancel() {
        stopLevelTimer()
        state = .idle
    }

    /// Preview helper: force a specific state.
    func setState(_ newState: DictationState) { state = newState }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }
}

// MARK: - Mock store

final class MockDictationStore: DictationStore {
    private var records: [DictationRecord]

    init(seeded: Bool = true) {
        records = seeded ? Self.generateHistory() : []
    }

    func save(_ result: DictationResult) throws {
        let words = result.text.split(whereSeparator: \.isWhitespace).count
        let record = DictationRecord(
            id: UUID(),
            text: result.text,
            createdAt: .now,
            duration: result.duration,
            wordCount: words,
            wpm: result.duration > 0 ? Double(words) / (result.duration / 60) : 0,
            targetAppName: result.targetAppName
        )
        records.insert(record, at: 0)
    }

    func all() throws -> [DictationRecord] {
        records.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) throws {
        records.removeAll { $0.id == id }
    }

    func search(_ query: String) throws -> [DictationRecord] {
        guard !query.isEmpty else { return try all() }
        return try all().filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    // MARK: 90 days of plausible history

    private static let phraseBank = [
        "Follow up with the client about the motion design deliverables for next week.",
        "Can we push the review to Thursday afternoon instead? I have a conflict.",
        "Note to self: the waveform animation needs easing, linear looks robotic.",
        "Thanks for sending that over, I'll take a look tonight and get back to you.",
        "Draft an outline for the portfolio case study, three sections max.",
        "The build failed again on the signing step, need to check the team ID.",
        "Let's lock the color palette before we touch any of the layout work.",
        "Pick up groceries after the gym: eggs, spinach, oat milk, and rice.",
        "The latency feels fine under a second but anything more breaks the flow.",
        "Send the invoice for the February retainer before the end of the day.",
    ]

    private static let apps = ["Notes", "Safari", "Slack", "Messages", "Mail", "VS Code", "Terminal"]

    private static func generateHistory() -> [DictationRecord] {
        var result: [DictationRecord] = []
        let calendar = Calendar.current
        for daysAgo in 0 ..< 90 {
            // ~1 in 5 days idle, so streaks and the heatmap look real.
            if daysAgo != 0, Int.random(in: 0 ..< 5) == 0 { continue }
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now)!
            for _ in 0 ..< Int.random(in: 1 ... 8) {
                let text = phraseBank.randomElement()!
                let words = text.split(whereSeparator: \.isWhitespace).count
                // Speaking pace 110–190 WPM back-solves a believable duration.
                let wpm = Double.random(in: 110 ... 190)
                let duration = Double(words) / wpm * 60
                let timestamp = calendar.date(
                    bySettingHour: Int.random(in: 8 ... 22),
                    minute: Int.random(in: 0 ... 59),
                    second: Int.random(in: 0 ... 59),
                    of: day
                )!
                result.append(DictationRecord(
                    id: UUID(),
                    text: text,
                    createdAt: min(timestamp, .now),
                    duration: duration,
                    wordCount: words,
                    wpm: wpm,
                    targetAppName: apps.randomElement()!
                ))
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }
}
