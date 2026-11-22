// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFormat

@Test func unreadableQueueStatePreservesTheReportAndTheOriginalDeadline() throws {
    let manager = FileManager.default
    let root = temporaryDirectory()
    defer { try? manager.removeItem(at: root) }
    let queue = ReportQueue(root: root)
    let report = PreparedReport(id: UUID(), json: Data("report".utf8), payload: nil)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try queue.enqueue(report, now: now)
    let original = try #require(queue.entries().first)
    let folder = root.appending(path: report.id.uuidString.lowercased())
    let state = folder.appending(path: "state.json")
    let saved = folder.appending(path: "state.saved")
    try manager.moveItem(at: state, to: saved)
    try manager.createDirectory(at: state, withIntermediateDirectories: false)

    let unreadable = queue.listing(at: now)
    #expect(unreadable.entries.isEmpty && unreadable.count == 1 && unreadable.hasStorageProblem)
    try manager.removeItem(at: state)
    try manager.moveItem(at: saved, to: state)
    #expect(queue.entries() == [original])
    #expect(try queue.report(original) == report)
}

@Test func aMissingOrMalformedQueueStateRecoversTheSameReport() throws {
    let manager = FileManager.default
    let root = temporaryDirectory()
    defer { try? manager.removeItem(at: root) }
    let queue = ReportQueue(root: root)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for missing in [false, true] {
        let report = PreparedReport(id: UUID(), json: Data("report".utf8), payload: nil)
        try queue.enqueue(report, now: now.addingTimeInterval(-60))
        let state = root.appending(path: report.id.uuidString.lowercased()).appending(path: "state.json")
        if missing { try manager.removeItem(at: state) } else { try Data("broken".utf8).write(to: state) }
        let listing = queue.listing(at: now)
        let repaired = try #require(listing.entries.first { $0.id == report.id })
        #expect(repaired.recovered && repaired.state.created == now && repaired.state.notBefore == now)
        #expect(try queue.report(repaired) == report)
        // Listing changes nothing; tidying saves the state it made.
        #expect(queue.listing(at: now.addingTimeInterval(10)).entries.first { $0.id == report.id }?.recovered == true)
        queue.tidy(listing)
        let saved = try #require(queue.listing(at: now.addingTimeInterval(10)).entries.first { $0.id == report.id })
        #expect(!saved.recovered && saved.state.created == now)
    }
}

@Test func anUnreadablePayloadMustWaitAndIsNeverSentAsTextOnly() throws {
    let manager = FileManager.default
    let root = temporaryDirectory()
    defer { try? manager.removeItem(at: root) }
    let queue = ReportQueue(root: root)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let report = PreparedReport(id: UUID(), json: Data("report".utf8), payload: Data("attachment".utf8))
    try queue.enqueue(report, now: now)
    let entry = try #require(queue.entries().first)
    let payload = root.appending(path: report.id.uuidString.lowercased()).appending(path: "payload.bin")
    try manager.removeItem(at: payload)
    #expect(throws: (any Error).self) { try queue.report(entry) }
    try manager.createDirectory(at: payload, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try queue.report(entry) }
    #expect(queue.listing(at: now).nextAttempt(excluding: [entry.id]) == nil)
    try manager.removeItem(at: payload)
    try #require(report.payload).write(to: payload)
    #expect(try queue.report(entry) == report)
}

@Test func anInaccessibleQueueIsAProblemAndAnAbsentOneIsNot() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = ReportQueue(root: root)
    #expect(!queue.listing(at: Date()).hasStorageProblem)
    try Data().write(to: root)
    #expect(queue.listing(at: Date()).hasStorageProblem)
}
