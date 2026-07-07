//
//  Dictation.swift
//  Whisper — Workstream C
//

import Foundation
import SwiftData

@Model
final class Dictation {
    var id: UUID
    var text: String
    var createdAt: Date
    var duration: TimeInterval
    var wordCount: Int
    /// Computed once at save time from wordCount and duration. Never recomputed (hard rule 4).
    var wpm: Double
    var targetAppName: String
    var targetAppBundleID: String

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = .now,
        duration: TimeInterval,
        wordCount: Int,
        wpm: Double,
        targetAppName: String,
        targetAppBundleID: String
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.duration = duration
        self.wordCount = wordCount
        self.wpm = wpm
        self.targetAppName = targetAppName
        self.targetAppBundleID = targetAppBundleID
    }

    var record: DictationRecord {
        DictationRecord(
            id: id,
            text: text,
            createdAt: createdAt,
            duration: duration,
            wordCount: wordCount,
            wpm: wpm,
            targetAppName: targetAppName
        )
    }
}
