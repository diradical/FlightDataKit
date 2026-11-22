// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@_spi(Testing) @testable import FlightData
import FlightDataFeedback
@testable import FlightDataFormat

private struct Count: PeriodicFlightDataReport {
    var value: Int
    mutating func merge(_ newer: Self) { value += newer.value }
    func content() throws -> ReportContent { ReportContent(title: "Count", fields: ["value": ReportValue(value)]) }
}

private struct Incident: PeriodicFlightDataReport {
    static let kind = ReportKind.crash
    var occurrences: Int
    mutating func merge(_ newer: Self) { occurrences += newer.occurrences }
    func content() throws -> ReportContent { ReportContent(title: "Incident") }
}

private struct Metric: FlightDataReport {
    func content() throws -> ReportContent { ReportContent(title: "Metric") }
}

private extension ReportTypeRig {
    func policyContainer(_ enabled: Bool?, attestor: any AppAttestor = DeviceAttestor(),
                         installIDs: any InstallIDStore = MemoryInstallIDStore("install-0123456789"),
                         now: (@Sendable () -> Date)? = nil) -> FlightDataContainer {
        testContainer([Feedback.self, Metric.self, Count.self],
                      [.init(publicKey: keys.publicKey),
                       .init(periodic: Count.self, every: .hours(1), publicKey: keys.publicKey)],
                      host: host, directory: directory, clock: clock, telemetryEnabled: enabled, installIDs: installIDs,
                      attestor: attestor, now: now)
    }

    func prepared(_ kind: ReportKind) throws -> PreparedReport {
        try PreparedReport.make(ReportContent(title: "Example"), kind: kind, channel: "EarlierChannel", app: testApp,
                                test: true, recipient: keys.recipient)
    }

    var windowFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory.appending(path: "periodic"),
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "window" }
    }
}

@Test func turningTelemetryOffAtLaunchErasesWhatWasGatheredAndKeepsCrashesAndFeedback() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let now = rig.clock.now
    let queue = ReportQueue(root: rig.directory)
    let old = try rig.prepared(.telemetry)
    try queue.enqueue(old, now: now)
    queue.recordFailure(try #require(queue.entries().first), retryAfter: 3_600, now: now)
    try queue.enqueue(try rig.prepared(.feedback), now: now)
    try queue.enqueue(try rig.prepared(.crash), now: now)
    let incomplete = rig.directory.appending(path: ".new-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
    try old.json.write(to: incomplete.appending(path: "report.json"))
    let windows = PeriodicWindows(directory: rig.directory.appending(path: "periodic"), saveDelay: .zero)
    let consent = TelemetryConsent(directory: nil, choice: nil)
    _ = windows.record(Count(value: 4), name: Count.name, kind: .telemetry, period: 3_600, at: now, consent: consent)
    _ = windows.record(Count(value: 1), name: "RemovedType", kind: .telemetry, period: 3_600, at: now, consent: consent)
    _ = windows.record(Incident(occurrences: 1), name: Incident.name, kind: .crash, period: 3_600, at: now,
                       consent: consent)
    #expect(rig.windowFiles.count == 3)

    let clockGate = NSLock()
    let container = clockGate.withLock {
        let container = rig.policyContainer(false, now: { clockGate.withLock { now } })
        // The first delivery pass is waiting for its clock, so only making the container could have written these.
        #expect(FileManager.default.fileExists(atPath: rig.directory.appending(path: "telemetry-disabled").path))
        #expect(FileManager.default.fileExists(atPath: rig.directory.appending(path: "telemetry-erasure-pending").path))
        return container
    }
    await container.deliverPending()
    #expect(try rig.sent().compactMap { $0["kind"] as? String }.sorted() == ["crash", "feedback"])
    #expect(rig.windowFiles.count == 1, "the crash window of a type that left the schema is kept")
    #expect(!FileManager.default.fileExists(atPath: incomplete.path))
    #expect(!FileManager.default.fileExists(atPath: rig.directory.appending(path: "telemetry-erasure-pending").path))
    #expect(await container.pendingCount == 0)
}

@Test func theKitRemembersThePersonsChoiceAcrossLaunches() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    await rig.policyContainer(nil).setTelemetryEnabled(false)
    let relaunched = rig.policyContainer(nil)
    #expect(!relaunched.telemetryEnabled)
    await #expect(throws: FlightDataError.telemetryDisabled) { try await relaunched.submit(Metric()) }
    // The app's own record of the choice wins.
    let told = rig.policyContainer(true)
    #expect(told.telemetryEnabled)
    #expect(rig.policyContainer(nil).telemetryEnabled)
}

@Test func turningTelemetryOffAndOnAgainStartsFresh() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    // Nothing is sent until the end, so that what is erased is known.
    let installID = HeldInstallID()
    let container = rig.policyContainer(true, installIDs: installID)
    let previouslyAllowed = try #require(container.consent.permit(for: .telemetry))
    container.record(Count(value: 10))
    try await container.submit(Metric())
    try await container.submit(Feedback(title: "Feedback", body: "Kept"))
    await container.setTelemetryEnabled(false)
    #expect(!container.telemetryEnabled)
    container.record(Count(value: 5))
    await #expect(throws: FlightDataError.telemetryDisabled) { try await container.submit(Metric()) }
    #expect(rig.windowFiles.isEmpty)
    await container.setTelemetryEnabled(true)
    #expect(container.consent.permit(for: .telemetry) != previouslyAllowed)
    try await container.submit(Metric())
    container.record(Count(value: 2))
    installID.allow()
    rig.clock.advance(3_600)
    await container.deliverPending()
    let sent = try rig.sent()
    #expect(sent.compactMap { $0["kind"] as? String }.sorted() == ["feedback", "telemetry", "telemetry"])
    let total = try openText(try #require(sent.first { $0["channel"] as? String == Count.name }), keys: rig.keys)
    #expect(total.fields["value"] == 2)
}

@Test func anErasureCutShortIsFinishedBeforeAnyTelemetryIsSent() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let queue = ReportQueue(root: rig.directory)
    let waiting = try rig.prepared(.telemetry)
    try queue.enqueue(waiting, now: rig.clock.now)
    let json = rig.directory.appending(path: waiting.id.uuidString.lowercased()).appending(path: "report.json")
    let manager = FileManager.default
    // A folder in place of the report's JSON makes it impossible to read, and so to erase.
    try manager.removeItem(at: json)
    try manager.createDirectory(at: json, withIntermediateDirectories: false)
    let first = rig.policyContainer(false)
    await first.deliverPending()
    await first.setTelemetryEnabled(true)
    #expect(first.telemetryEnabled && first.consent.needsErasure)
    await #expect(throws: (any Error).self) { try await first.submit(Metric()) }
    #expect(try rig.sent().isEmpty)

    try manager.removeItem(at: json)
    try waiting.json.write(to: json)
    let next = rig.policyContainer(nil)
    await next.deliverPending()
    #expect(try rig.sent().isEmpty)
    #expect(await next.pendingCount == 0)
    try await next.submit(Metric())
    await next.deliverPending()
    #expect(try rig.sent().count == 1)
}

private actor WaitingAttestor: AppAttestor {
    nonisolated let isSupported = true
    nonisolated let appIDPrefix: String? = nil
    private var waiting: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting != nil }
    func resume() {
        waiting?.resume()
        waiting = nil
    }
    func generateKey() async throws -> String {
        await withCheckedContinuation { waiting = $0 }
        throw AttestorError.failed
    }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw AttestorError.failed }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { throw AttestorError.failed }
}

@Test func turningTelemetryOffWhileAProofIsPendingNeverSendsTheReport() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    StubURLProtocol.setReply(rig.host) { _ in .status(201, body: #"{"challenge":"test"}"#) }
    let attestor = WaitingAttestor()
    let container = rig.policyContainer(true, attestor: attestor)
    try await container.submit(Metric())
    try await waitUntil { await attestor.isWaiting }
    try #require(await attestor.isWaiting)
    await container.setTelemetryEnabled(false)
    await container.setTelemetryEnabled(true)
    await attestor.resume()
    await container.deliverPending()
    #expect(StubURLProtocol.requests(to: rig.host).map { $0.request.url?.path } == ["/v1/attest/challenges"])
    #expect(await container.pendingCount == 0)
}

@Test func turningTelemetryOffCancelsItsUploadAndLetsFeedbackThrough() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    StubURLProtocol.setReply(rig.host) { _ in .waitForCancellation }
    let container = rig.policyContainer(true)
    try await container.submit(Metric())
    try await waitUntil { !StubURLProtocol.requests(to: rig.host).isEmpty }
    try #require(!StubURLProtocol.requests(to: rig.host).isEmpty)
    await container.setTelemetryEnabled(false)
    try await waitUntil { StubURLProtocol.wasCancelled(rig.host) }
    try #require(StubURLProtocol.wasCancelled(rig.host))
    StubURLProtocol.setReply(rig.host) { _ in .status(201) }
    try await container.submit(Feedback(title: "Feedback", body: "Still allowed"))
    await container.deliverPending()
    #expect(try rig.sent().compactMap { $0["kind"] as? String } == ["telemetry", "feedback"])
    #expect(await container.pendingCount == 0)
}
