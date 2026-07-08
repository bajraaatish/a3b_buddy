//
//  SwiftDataStoreTests.swift
//  WhisperTests — Workstream C
//

import Foundation
import Testing
@testable import A3BBuddy

@MainActor
struct SwiftDataStoreTests {
    static func store() throws -> SwiftDataStore {
        try SwiftDataStore(inMemory: true)
    }

    static func result(_ text: String, duration: TimeInterval = 10, app: String = "Notes") -> DictationResult {
        DictationResult(text: text, duration: duration, targetAppBundleID: "test.\(app)", targetAppName: app)
    }

    @Test func saveComputesWordCountAndWPMOnce() throws {
        let store = try Self.store()
        // 30 words in 12 s → 150 WPM.
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        try store.save(Self.result(words, duration: 12))
        let record = try #require(try store.all().first)
        #expect(record.wordCount == 30)
        #expect(abs(record.wpm - 150) < 0.001)
    }

    @Test func zeroDurationYieldsZeroWPMNotCrash() throws {
        let store = try Self.store()
        try store.save(Self.result("hello there", duration: 0))
        let record = try #require(try store.all().first)
        #expect(record.wpm == 0)
    }

    @Test func allReturnsNewestFirst() throws {
        let store = try Self.store()
        try store.save(Self.result("first"))
        try store.save(Self.result("second"))
        let texts = try store.all().map(\.text)
        #expect(texts == ["second", "first"])
    }

    @Test func deleteRemovesOnlyThatRecord() throws {
        let store = try Self.store()
        try store.save(Self.result("keep me"))
        try store.save(Self.result("delete me"))
        let doomed = try #require(try store.all().first { $0.text == "delete me" })
        try store.delete(id: doomed.id)
        let texts = try store.all().map(\.text)
        #expect(texts == ["keep me"])
    }

    @Test func searchIsCaseInsensitive() throws {
        let store = try Self.store()
        try store.save(Self.result("Meeting notes about the Portfolio site"))
        try store.save(Self.result("grocery list"))
        let hits = try store.search("portfolio")
        #expect(hits.count == 1)
        #expect(hits.first?.text.contains("Portfolio") == true)
    }

    @Test func emptySearchReturnsEverything() throws {
        let store = try Self.store()
        try store.save(Self.result("one"))
        try store.save(Self.result("two"))
        #expect(try store.search("").count == 2)
    }

    @Test func purgeDropsOnlyOldRecords() throws {
        let store = try Self.store()
        try store.save(Self.result("recent"))
        try store.purge(olderThan: Date.now.addingTimeInterval(-3600))
        #expect(try store.all().count == 1)
        try store.purge(olderThan: Date.now.addingTimeInterval(3600))
        #expect(try store.all().isEmpty)
    }
}
