//
//  StatsCalculatorTests.swift
//  WhisperTests — Workstream C
//

import Foundation
import Testing
@testable import A3BBuddy

@MainActor
struct StatsCalculatorTests {
    // Fixed clock + timezone so day-boundary math never depends on the machine.
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// 2026-07-05 15:00 in the fixed timezone.
    static let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 15))!

    static func date(daysAgo: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: fixedNow))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func record(
        words: Int,
        duration: TimeInterval,
        daysAgo: Int,
        hour: Int = 12,
        minute: Int = 0,
        app: String = "Notes"
    ) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            text: Array(repeating: "word", count: words).joined(separator: " "),
            createdAt: date(daysAgo: daysAgo, hour: hour, minute: minute),
            duration: duration,
            wordCount: words,
            wpm: duration > 0 ? Double(words) / (duration / 60) : 0,
            targetAppName: app
        )
    }

    static func calculator(_ records: [DictationRecord]) -> StatsCalculator {
        StatsCalculator(records: { records }, calendar: calendar, now: { fixedNow })
    }

    // MARK: WPM

    @Test func avgWPMIsWeightedMeanNotMeanOfWPMs() {
        // Uneven durations so weighted mean and mean-of-WPMs disagree.
        let records = [
            Self.record(words: 100, duration: 60, daysAgo: 0),
            Self.record(words: 90, duration: 30, daysAgo: 1), // 180 WPM
        ]
        let summary = Self.calculator(records).summary(days: 30)
        // 190 words / 1.5 min = 126.67, NOT (100+180)/2 = 140.
        #expect(abs(summary.avgWPM - 190.0 / 1.5) < 0.001)
        #expect(summary.totalWords == 190)
    }

    @Test func summaryHonorsDayWindow() {
        let records = [
            Self.record(words: 10, duration: 10, daysAgo: 0),
            Self.record(words: 20, duration: 10, daysAgo: 40), // outside 30-day window
        ]
        let summary = Self.calculator(records).summary(days: 30)
        #expect(summary.totalWords == 10)
        #expect(summary.activeDays == 1)
    }

    @Test func zeroRecordsMeansZeroEverything() {
        let summary = Self.calculator([]).summary(days: 30)
        #expect(summary.totalWords == 0)
        #expect(summary.avgWPM == 0)
        #expect(summary.currentStreak == 0)
    }

    // MARK: Streak edges

    @Test func streakCountsConsecutiveDaysEndingToday() {
        let records = [0, 1, 2, 4].map { Self.record(words: 5, duration: 5, daysAgo: $0) }
        #expect(Self.calculator(records).summary(days: 30).currentStreak == 3)
    }

    @Test func streakSurvivesEmptyToday() {
        // Nothing dictated *yet* today — streak ending yesterday still alive.
        let records = [1, 2, 3].map { Self.record(words: 5, duration: 5, daysAgo: $0) }
        #expect(Self.calculator(records).summary(days: 30).currentStreak == 3)
    }

    @Test func streakDiesAfterFullIdleDay() {
        let records = [2, 3].map { Self.record(words: 5, duration: 5, daysAgo: $0) }
        #expect(Self.calculator(records).summary(days: 30).currentStreak == 0)
    }

    @Test func lateNightAndEarlyMorningAreDifferentDays() {
        // 23:59 two days ago + 00:01 yesterday: distinct days in local tz → streak of 2.
        let records = [
            Self.record(words: 5, duration: 5, daysAgo: 2, hour: 23, minute: 59),
            Self.record(words: 5, duration: 5, daysAgo: 1, hour: 0, minute: 1),
        ]
        #expect(Self.calculator(records).summary(days: 30).currentStreak == 2)
    }

    // MARK: Month comparison

    @Test func monthComparisonUsesCalendarMonths() {
        // fixedNow = Jul 5. daysAgo 0..4 → July; daysAgo 10+ → June.
        let records = [
            Self.record(words: 100, duration: 60, daysAgo: 0),
            Self.record(words: 50, duration: 60, daysAgo: 4),
            Self.record(words: 70, duration: 60, daysAgo: 10),
            Self.record(words: 30, duration: 60, daysAgo: 33),
        ]
        let summary = Self.calculator(records).summary(days: 90)
        #expect(summary.wordsThisMonth == 150)
        #expect(summary.wordsLastMonth == 100)
    }

    // MARK: Daily activity / heatmap

    @Test func dailyActivityZeroFillsAndEndsToday() {
        let records = [Self.record(words: 12, duration: 10, daysAgo: 1)]
        let activity = Self.calculator(records).dailyActivity(weeksBack: 2)
        #expect(activity.count == 14)
        #expect(activity.last!.date == Self.calendar.startOfDay(for: Self.fixedNow))
        #expect(activity.last!.words == 0)
        #expect(activity[activity.count - 2].words == 12)
    }

    @Test func topAppIsMaxWordsThatDay() {
        let records = [
            Self.record(words: 30, duration: 10, daysAgo: 0, hour: 9, app: "Slack"),
            Self.record(words: 80, duration: 10, daysAgo: 0, hour: 10, app: "Notes"),
        ]
        let today = Self.calculator(records).dailyActivity(weeksBack: 1).last!
        #expect(today.topApp == "Notes")
        #expect(today.words == 110)
    }

    // MARK: App breakdown

    @Test func appBreakdownSortedByWordsDescending() {
        let records = [
            Self.record(words: 10, duration: 10, daysAgo: 0, app: "Slack"),
            Self.record(words: 90, duration: 10, daysAgo: 1, app: "Notes"),
            Self.record(words: 40, duration: 10, daysAgo: 2, app: "Slack"),
        ]
        let breakdown = Self.calculator(records).appBreakdown(days: 30)
        #expect(breakdown.map(\.appName) == ["Notes", "Slack"])
        #expect(breakdown.map(\.words) == [90, 50])
    }
}
