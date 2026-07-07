//
//  MainWindowView.swift
//  Whisper — Workstream B
//
//  The one real window: sidebar with History and Insights.
//

import SwiftUI

struct MainWindowView: View {
    let store: any DictationStore
    let stats: any StatsProviding

    private enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case insights = "Insights"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .history: "clock.arrow.circlepath"
            case .insights: "chart.bar.fill"
            }
        }
    }

    @State private var selection: Section = .history

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selection {
            case .history:
                HistoryView(store: store)
            case .insights:
                InsightsView(stats: stats)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }
}

#Preview {
    let store = MockDictationStore()
    return MainWindowView(
        store: store,
        stats: StatsCalculator(records: { (try? store.all()) ?? [] })
    )
    .frame(width: 860, height: 600)
}
