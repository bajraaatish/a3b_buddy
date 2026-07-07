//
//  HistoryView.swift
//  Whisper — Workstream B
//

import SwiftUI

struct HistoryView: View {
    let store: any DictationStore

    @State private var query = ""
    @State private var records: [DictationRecord] = []
    @State private var copiedID: UUID?

    var body: some View {
        Group {
            if records.isEmpty {
                emptyState
            } else {
                List(records) { record in
                    HistoryRow(
                        record: record,
                        justCopied: copiedID == record.id,
                        onCopy: { copy(record) },
                        onDelete: { delete(record) }
                    )
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcripts")
        .navigationTitle("History")
        .task { reload() }
        .onChange(of: query) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .dictationDidSave)) { _ in reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            query.isEmpty ? "No dictations yet" : "No matches",
            systemImage: query.isEmpty ? "mic.slash" : "magnifyingglass",
            description: Text(query.isEmpty
                ? "Hold the hotkey, speak, release. Everything you dictate lands here."
                : "No transcript contains “\(query)”.")
        )
    }

    private func reload() {
        records = (try? store.search(query)) ?? []
    }

    private func copy(_ record: DictationRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        copiedID = record.id
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == record.id { copiedID = nil }
        }
    }

    private func delete(_ record: DictationRecord) {
        try? store.delete(id: record.id)
        reload()
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let justCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.text)
                .font(.body)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                metaDot
                Text(record.targetAppName)
                metaDot
                Text("\(Int(record.duration.rounded()))s · \(Int(record.wpm.rounded())) WPM")
                Spacer()
                Button(action: onCopy) {
                    Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy transcript")
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Delete from history")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var metaDot: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

#Preview {
    NavigationStack {
        HistoryView(store: MockDictationStore())
    }
    .frame(width: 560, height: 480)
}
