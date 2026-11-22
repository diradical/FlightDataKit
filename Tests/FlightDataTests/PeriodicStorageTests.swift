// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@_spi(Testing) @testable import FlightData
import FlightDataFeedback
@testable import FlightDataFormat

private func windowFiles(_ rig: ReportTypeRig) -> [URL] {
    let directory = rig.directory.appending(path: "periodic")
    return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "window" }
}

@Test func recordingAnEventDoesNotWriteUntilAMomentLater() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let windows = PeriodicWindows(directory: directory.appending(path: "periodic"), saveDelay: .seconds(600))
    let consent = TelemetryConsent(directory: nil, choice: nil)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for transfers in 1...3 {
        let change = windows.record(BankingAnalytics(transfers: transfers), name: "BankingAnalytics", kind: .telemetry,
                                    period: 3_600, at: start, consent: consent)
        #expect(change == (transfers == 1 ? .opened : .merged))
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    windows.save()
    let files = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "periodic"),
                                                            includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let saved = try JSONDecoder().decode(PeriodicWindows.Window.self, from: Data(contentsOf: try #require(files.first)))
    #expect(try JSONDecoder().decode(BankingAnalytics.self, from: saved.report).transfers == 6)
    #expect(saved.kind == .telemetry && saved.started == start && saved.name == "BankingAnalytics")
}

@Test func theAppGoingToTheBackgroundSavesWhatWasGathered() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let center = NotificationCenter()
    let suspended = Notification.Name("FlightDataTests.suspended")
    let inputs = DeliveryTriggers.Inputs(center: center, foreground: [], suspension: [suspended],
                                         reachability: { AsyncStream { $0.finish() } })
    let container = FlightDataContainer(
        schema: ReportSchema([BankingAnalytics.self]), appToken: appToken(),
        endpoint: URL(string: "https://\(rig.host)")!,
        configurations: [FlightDataConfiguration(periodic: BankingAnalytics.self, every: .hours(1),
                                                 publicKey: rig.keys.publicKey)],
        app: testApp, test: true, directory: rig.directory, telemetryEnabled: nil,
        installIDs: MemoryInstallIDStore(), session: StubURLProtocol.session(), now: { rig.clock.now },
        triggers: inputs, periodicSaveDelay: .seconds(600), problem: { Issue.record("\($0)") })
    for _ in 0..<500 where !(await container.isWatching) { try await Task.sleep(for: .milliseconds(10)) }
    container.record(BankingAnalytics(transfers: 2))
    #expect(windowFiles(rig).isEmpty)
    center.post(name: suspended, object: nil)
    #expect(windowFiles(rig).count == 1)
}

@Test func aWindowQueuedBeforeTheAppStoppedIsStillOneReport() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let first = rig.container()
    first.record(BankingAnalytics(transfers: 3))
    await first.deliverPending()
    rig.clock.advance(3_600)
    // The app stopped after queueing the window and before removing it.
    let windows = PeriodicWindows(directory: rig.directory.appending(path: "periodic"), saveDelay: .zero)
    let window = try #require(windows.closeDue(at: rig.clock.now, periods: [BankingAnalytics.name: 3_600]).first)
    let content = try JSONDecoder().decode(BankingAnalytics.self, from: window.report).content()
    let prepared = try PreparedReport.make(content, kind: .telemetry, channel: BankingAnalytics.name, app: testApp,
                                           test: true, recipient: rig.keys.recipient, id: window.id)
    try ReportQueue(root: rig.directory).enqueue(prepared, now: rig.clock.now)
    let relaunched = rig.container()
    await relaunched.deliverPending()
    let sent = try rig.sent()
    #expect(sent.count == 1)
    #expect(sent.first?["id"] as? String == window.id.uuidString.lowercased())
    #expect(windowFiles(rig).isEmpty)
}

@Test func aWindowThatCannotBeQueuedWaitsUntilTheDiskAcceptsIt() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    container.record(BankingAnalytics(transfers: 2))
    let window = try #require(windowFiles(rig).first)
    // A file where the report's folder would go makes queueing it fail.
    let blocker = rig.directory.appending(path: window.deletingPathExtension().lastPathComponent)
    try Data().write(to: blocker)
    rig.clock.advance(3_600)
    await container.deliverPending()
    #expect(try rig.sent().isEmpty)
    #expect(FileManager.default.fileExists(atPath: window.path))
    try FileManager.default.removeItem(at: blocker)
    await container.deliverPending()
    #expect(try rig.sent().map { try openText($0, keys: rig.keys).fields["transfers"] } == [2])
    #expect(windowFiles(rig).isEmpty)
}

@Test func aRemovedTypesWindowIsKeptForThirtyDaysThenDeleted() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let first = rig.container()
    first.record(BankingAnalytics(transfers: 2))
    await first.deliverPending()
    let feedbackOnly = testContainer([Feedback.self], [FlightDataConfiguration(publicKey: rig.keys.publicKey)],
                                     host: rig.host, directory: rig.directory, clock: rig.clock)
    rig.clock.advance(7_200)
    await feedbackOnly.deliverPending()
    #expect(windowFiles(rig).count == 1)
    rig.clock.advance(ReportQueue.maximumAge)
    await feedbackOnly.deliverPending()
    #expect(windowFiles(rig).isEmpty)
    #expect(try rig.sent().isEmpty)
}

@Test func aWindowFileThatCannotBeDecodedIsRemoved() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let directory = rig.directory.appending(path: "periodic")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let broken = directory.appending(path: UUID().uuidString.lowercased() + ".window")
    try Data("{".utf8).write(to: broken)
    let container = rig.container()
    container.record(BankingAnalytics(transfers: 1))
    #expect(!FileManager.default.fileExists(atPath: broken.path))
    #expect(windowFiles(rig).count == 1)
}

@Test func theKitsFilesAreLeftOutOfBackups() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
    let values = try rig.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
}
