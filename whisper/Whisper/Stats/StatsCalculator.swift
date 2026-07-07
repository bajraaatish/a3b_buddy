//
//  StatsCalculator.swift
//  Whisper — Workstream C
//
//  Pure logic over DictationRecord values. No UI, no system APIs.
//  Scoping: totalWords / avgWPM / activeDays honor the `days` window;
//  currentStreak and the month comparison are global by definition.
//

import Foundation

struct StatsCalculator: StatsProviding {
    var records: () -> [DictationRecord]
    var calendar: Calendar = .current
    /// Injectable clock so streak/month edges are testable.
    var now: () -> Date = { .now }

    func summary(days: Int) -> StatsSummary {
        let all = records()
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now())!
        let window = all.filter { $0.createdAt >= cutoff }

        let totalWords = window.reduce(0) { $0 + $1.wordCount }
        let totalMinutes = window.reduce(0.0) { $0 + $1.duration } / 60
        // Weighted mean: total words over total speaking time, not a mean of per-row WPMs.
        let avgWPM = totalMinutes > 0 ? Double(totalWords) / totalMinutes : 0
        let activeDays = Set(window.map { calendar.startOfDay(for: $0.createdAt) }).count

        let thisMonthStart = calendar.dateInterval(of: .month, for: now())!.start
        let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
        let wordsThisMonth = all
            .filter { $0.createdAt >= thisMonthStart }
            .reduce(0) { $0 + $1.wordCount }
        let wordsLastMonth = all
            .filter { $0.createdAt >= lastMonthStart && $0.createdAt < thisMonthStart }
            .reduce(0) { $0 + $1.wordCount }

        return StatsSummary(
            totalWords: totalWords,
            avgWPM: avgWPM,
            activeDays: activeDays,
            currentStreak: currentStreak(in: all),
            wordsThisMonth: wordsThisMonth,
            wordsLastMonth: wordsLastMonth
        )
    }

    func dailyActivity(weeksBack: Int) -> [DayActivity] {
        let all = records()
        let today = calendar.startOfDay(for: now())
        var wordsByDay: [Date: Int] = [:]
        var appWordsByDay: [Date: [String: Int]] = [:]
        for record in all {
            let day = calendar.startOfDay(for: record.createdAt)
            wordsByDay[day, default: 0] += record.wordCount
            appWordsByDay[day, default: [:]][record.targetAppName, default: 0] += record.wordCount
        }
        // Oldest → newest, ending today, zero-filled so heatmap cells align.
        return (0 ..< weeksBack * 7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayActivity(
                date: day,
                words: wordsByDay[day] ?? 0,
                topApp: appWordsByDay[day]?.max { $0.value < $1.value }?.key
            )
        }
    }

    func appBreakdown(days: Int) -> [AppUsage] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now())!
        var byApp: [String: Int] = [:]
        for record in records() where record.createdAt >= cutoff {
            byApp[record.targetAppName, default: 0] += record.wordCount
        }
        return byApp
            .map { AppUsage(appName: $0.key, words: $0.value) }
            .sorted { $0.words > $1.words }
    }

    /// Consecutive active days ending today — or ending yesterday when today
    /// has no dictation yet (the streak isn't broken until the day is over).
    private func currentStreak(in all: [DictationRecord]) -> Int {
        let activeDays = Set(all.map { calendar.startOfDay(for: $0.createdAt) })
        guard !activeDays.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now())
        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  activeDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
