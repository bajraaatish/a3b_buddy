//
//  SwiftDataStore.swift
//  Whisper — Workstream C
//

import Foundation
import SwiftData

final class SwiftDataStore: DictationStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// - Parameter inMemory: true for unit tests and previews; nothing touches disk.
    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: Dictation.self, configurations: config)
        context = ModelContext(container)
    }

    func save(_ result: DictationResult) throws {
        let words = result.text.split(whereSeparator: \.isWhitespace).count
        let dictation = Dictation(
            text: result.text,
            duration: result.duration,
            wordCount: words,
            wpm: result.duration > 0 ? Double(words) / (result.duration / 60) : 0,
            targetAppName: result.targetAppName,
            targetAppBundleID: result.targetAppBundleID
        )
        context.insert(dictation)
        try context.save()
    }

    func all() throws -> [DictationRecord] {
        let descriptor = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).map(\.record)
    }

    func delete(id: UUID) throws {
        try context.delete(model: Dictation.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    func search(_ query: String) throws -> [DictationRecord] {
        guard !query.isEmpty else { return try all() }
        var descriptor = FetchDescriptor<Dictation>(
            predicate: #Predicate { $0.text.localizedStandardContains(query) }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor).map(\.record)
    }

    /// Retention (Phase 5): remove everything recorded before the cutoff.
    func purge(olderThan cutoff: Date) throws {
        try context.delete(model: Dictation.self, where: #Predicate { $0.createdAt < cutoff })
        try context.save()
    }
}
