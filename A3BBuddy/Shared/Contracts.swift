// Contracts.swift — FROZEN. Any change requires owner approval (see WORKSTREAMS.md).
// Workstream A implements DictationEngine. Workstream C implements DictationStore + StatsProviding.
// Workstream B consumes everything here and implements nothing from it.

import Foundation
import Combine

// ── State machine every UI element observes ──────────────
enum DictationState: Equatable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case failed(DictationError)
}

enum DictationError: Error, Equatable {
    case micDenied, accessibilityDenied
    case modelNotReady, transcriptionFailed, insertionFailed
}

// ── Workstream A implements these ────────────────────────
protocol DictationEngine: ObservableObject {
    var state: DictationState { get }          // @Published
    var audioLevel: Float { get }              // @Published, 0–1, drives waveform
    func startRecording()
    func stopAndTranscribe() async -> DictationResult?
    func cancel()
}

struct DictationResult {
    let text: String
    let duration: TimeInterval
    let targetAppBundleID: String
    let targetAppName: String
}

// ── Workstream C implements these ────────────────────────
protocol DictationStore {
    func save(_ result: DictationResult) throws
    func all() throws -> [DictationRecord]      // newest first
    func delete(id: UUID) throws
    func search(_ query: String) throws -> [DictationRecord]
}

struct DictationRecord: Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
    let duration: TimeInterval
    let wordCount: Int
    let wpm: Double
    let targetAppName: String
}

protocol StatsProviding {
    func summary(days: Int) -> StatsSummary
    func dailyActivity(weeksBack: Int) -> [DayActivity]   // heatmap
    func appBreakdown(days: Int) -> [AppUsage]            // bar chart
}

struct StatsSummary { let totalWords: Int; let avgWPM: Double; let activeDays: Int; let currentStreak: Int; let wordsThisMonth: Int; let wordsLastMonth: Int }
struct DayActivity { let date: Date; let words: Int; let topApp: String? }
struct AppUsage { let appName: String; let words: Int }
