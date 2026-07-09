//
//  InsightsView.swift
//  Whisper — Workstream B
//
//  Dashboard rules applied: heatmap is a single-hue sequential ramp; app bars
//  share one hue with direct labels (magnitude, not identity — no legend);
//  numbers wear text colors, never the accent; month delta = icon + text.
//

import SwiftUI

struct InsightsView: View {
    let stats: any StatsProviding

    @State private var summary: StatsSummary?
    @State private var activity: [DayActivity] = []
    @State private var apps: [AppUsage] = []

    private let windowDays = 30
    private let heatmapWeeks = 16

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let summary {
                    HStack(alignment: .top, spacing: 16) {
                        WPMGauge(wpm: summary.avgWPM)
                        StatTile(
                            value: summary.totalWords.formatted(),
                            caption: "Words · last \(windowDays) days",
                            badge: monthBadge(summary)
                        )
                        StatTile(
                            value: "\(summary.currentStreak)",
                            caption: summary.currentStreak == 1 ? "Day streak" : "Days streak",
                            badge: summary.currentStreak > 0 ? Badge(icon: "flame.fill", text: "active") : nil
                        )
                        StatTile(
                            value: "\(summary.activeDays)",
                            caption: "Active days · \(windowDays)",
                            badge: nil
                        )
                    }
                }

                SectionBox(title: "Daily activity") {
                    StreakHeatmap(activity: activity)
                }

                SectionBox(title: "Where you dictate · last \(windowDays) days") {
                    AppBars(apps: apps)
                }
            }
            .padding(24)
        }
        .navigationTitle("Insights")
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .dictationDidSave)) { _ in reload() }
    }

    private func reload() {
        summary = stats.summary(days: windowDays)
        activity = stats.dailyActivity(weeksBack: heatmapWeeks)
        apps = stats.appBreakdown(days: windowDays)
    }

    private func monthBadge(_ summary: StatsSummary) -> Badge? {
        guard summary.wordsLastMonth > 0 else { return nil }
        let delta = Double(summary.wordsThisMonth - summary.wordsLastMonth) / Double(summary.wordsLastMonth) * 100
        let sign = delta >= 0 ? "+" : ""
        return Badge(
            icon: delta >= 0 ? "arrow.up.right" : "arrow.down.right",
            text: "\(sign)\(Int(delta.rounded()))% vs last month"
        )
    }
}

// MARK: - Tiles

struct Badge {
    let icon: String
    let text: String
}

private struct StatTile: View {
    let value: String
    let caption: String
    let badge: Badge?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let badge {
                Label(badge.text, systemImage: badge.icon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WPMGauge: View {
    let wpm: Double
    private let maxWPM = 220.0

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                arc(progress: 1, color: Color.secondary.opacity(0.18))
                arc(progress: min(wpm / maxWPM, 1), color: .accentColor)
                VStack(spacing: 0) {
                    Text("\(Int(wpm.rounded()))")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("WPM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .offset(y: 6)
            }
            .frame(width: 120, height: 74)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .help("Average speaking pace over the last 30 days (typing is ~45 WPM)")
    }

    private func arc(progress: Double, color: Color) -> some View {
        Circle()
            .trim(from: 0, to: progress * 0.5)
            .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            .rotationEffect(.degrees(180))
            .frame(width: 110, height: 110)
            .offset(y: 28)
            .clipped()
    }
}

// MARK: - Heatmap

private struct StreakHeatmap: View {
    let activity: [DayActivity]

    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    var body: some View {
        let weeks = weekColumns()
        HStack(alignment: .top, spacing: gap) {
            ForEach(weeks.indices, id: \.self) { w in
                VStack(spacing: gap) {
                    ForEach(0 ..< 7, id: \.self) { d in
                        if let day = weeks[w][d] {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(rampColor(day.words))
                                .frame(width: cell, height: cell)
                                .help(tooltip(day))
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Columns = weeks, rows = weekday. Leading pad aligns the first column.
    private func weekColumns() -> [[DayActivity?]] {
        guard let first = activity.first else { return [] }
        let weekdayOffset = (Calendar.current.component(.weekday, from: first.date) - Calendar.current.firstWeekday + 7) % 7
        var padded: [DayActivity?] = Array(repeating: nil, count: weekdayOffset) + activity.map { $0 }
        while padded.count % 7 != 0 { padded.append(nil) }
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0 ..< $0 + 7]) }
    }

    /// Single-hue sequential ramp; zero is a neutral well, not the lightest step.
    private func rampColor(_ words: Int) -> Color {
        switch words {
        case 0: Color.secondary.opacity(0.12)
        case 1 ..< 100: Color.accentColor.opacity(0.25)
        case 100 ..< 300: Color.accentColor.opacity(0.45)
        case 300 ..< 700: Color.accentColor.opacity(0.7)
        default: Color.accentColor
        }
    }

    private func tooltip(_ day: DayActivity) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard day.words > 0 else { return "\(date) — no dictation" }
        let top = day.topApp.map { " · mostly \($0)" } ?? ""
        return "\(date) — \(day.words) words\(top)"
    }
}

// MARK: - App bars

private struct AppBars: View {
    let apps: [AppUsage]
    private let maxRows = 6

    var body: some View {
        let shown = Array(apps.prefix(maxRows))
        let peak = shown.map(\.words).max() ?? 1
        return VStack(spacing: 8) {
            if shown.isEmpty {
                Text("Nothing yet — dictate somewhere and it shows up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(shown, id: \.appName) { app in
                HStack(spacing: 10) {
                    Text(app.appName)
                        .font(.caption)
                        .frame(width: 90, alignment: .trailing)
                        .lineLimit(1)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(geo.size.width * CGFloat(app.words) / CGFloat(peak), 4))
                    }
                    .frame(height: 14)
                    Text(app.words.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                }
                .help("\(app.appName): \(app.words) words")
            }
        }
    }
}

// MARK: - Section container

private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    let store = MockDictationStore()
    let stats = StatsCalculator(records: { (try? store.all()) ?? [] })
    return NavigationStack {
        InsightsView(stats: stats)
    }
    .frame(width: 720, height: 640)
}
