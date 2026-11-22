// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

private struct Rig {
    let keys = Keys()
    let clock = TestClock()
    let directory = temporaryDirectory()
    let host: String
    let appToken = FlightDataTests.appToken()

    init(reply: @escaping @Sendable (StubURLProtocol.Sent) -> StubURLProtocol.Reply = { _ in .status(201) }) {
        host = StubURLProtocol.host(reply)
    }

    func container(triggers: DeliveryTriggers.Inputs = .none) -> FlightDataContainer {
        testContainer([Feedback.self], [FlightDataConfiguration(publicKey: keys.publicKey)], host: host,
                      directory: directory, clock: clock, token: appToken, triggers: triggers)
    }

    /// A container whose triggers are the ones given, and which is watching them when this returns.
    func watchingContainer(triggers: DeliveryTriggers.Inputs) async throws -> FlightDataContainer {
        let container = container(triggers: triggers)
        try await waitUntil { await container.isWatching }
        return container
    }

    var sent: [StubURLProtocol.Sent] { StubURLProtocol.requests(to: host) }
    var queue: ReportQueue { ReportQueue(root: directory) }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func feedback(files: [ReportFile] = []) -> Feedback {
    Feedback(title: "Arrows overlap", body: "They do.", fields: ["area": "arrows"], files: files)
}

/// A type an app defines for itself, saved explicitly here.
private struct Sighting: ReflectedFlightDataReport {
    var species = ""
    var count = 1
}

@Test func aSentReportReachesTheServerSealedWithTheRightHeaders() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    let files = [ReportFile(name: "doc.cdxml", contentType: "text/xml", data: Data("<doc/>".utf8))]
    let id = try await container.submit(feedback(files: files))
    await container.deliverPending()

    let request = try #require(rig.sent.first)
    #expect(rig.sent.count == 1)
    #expect(request.request.httpMethod == "POST")
    #expect(request.request.url?.path() == "/v1/reports")
    #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Ingest " + rig.appToken)
    #expect(request.request.value(forHTTPHeaderField: "X-Install-ID") == "install-0123456789")
    #expect(request.request.value(forHTTPHeaderField: "User-Agent") == "FlightDataKit/\(FlightDataKit.version)")
    let contentType = try #require(request.request.value(forHTTPHeaderField: "Content-Type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))

    let parts = try Multipart(body: request.body, contentType: contentType)
    #expect(parts.payloadFilename == "payload.bin")
    let json = try #require(JSONSerialization.jsonObject(with: parts.report) as? [String: Any])
    #expect(json["id"] as? String == id.uuidString.lowercased())
    #expect(try openText(json, keys: rig.keys).title == "Arrows overlap")
    let payload = try #require(parts.payload)
    let opened = try Envelope.open(payload, using: rig.keys.privateKey, reportID: id, part: .payload)
    #expect(try Payload.unpack(opened) == files)
    // Nothing readable on the wire or on disk was written by the person.
    #expect(!String(decoding: request.body, as: UTF8.self).contains("Arrows overlap"))
    #expect(rig.queue.entries().isEmpty)
}

@Test func eachTypeGoesToItsOwnChannelSealedToItsConfigurationsKey() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let other = Keys()
    let container = testContainer([Feedback.self, Sighting.self],
                                  [FlightDataConfiguration(publicKey: rig.keys.publicKey),
                                   FlightDataConfiguration(for: Sighting.self, publicKey: other.publicKey)],
                                  host: rig.host, directory: rig.directory, clock: rig.clock)
    try await container.submit(feedback())
    await container.deliverPending()
    try await container.submit(Sighting(species: "heron", count: 2))
    await container.deliverPending()
    let reports = try rig.sent.map { sent in
        let parts = try Multipart(body: sent.body,
                                  contentType: try #require(sent.request.value(forHTTPHeaderField: "Content-Type")))
        return try #require(JSONSerialization.jsonObject(with: parts.report) as? [String: Any])
    }
    // A type's name is its channel, and a type an app defines is telemetry to the server unless it says otherwise.
    #expect(reports.map { $0["channel"] as? String } == ["Feedback", "Sighting"])
    #expect(reports.map { $0["kind"] as? String } == ["feedback", "telemetry"])
    #expect(reports.map { $0["key_id"] as? String }
        == [Envelope.keyID(for: rig.keys.privateKey.publicKey), Envelope.keyID(for: other.privateKey.publicKey)])
    let text = try openText(reports[1], keys: other)
    #expect(text.title == "Sighting" && text.fields == ["species": "heron", "count": 2])
}

@Test func aReportWithoutAttachmentsSendsNoPayloadPart() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    let request = try #require(rig.sent.first)
    let parts = try Multipart(body: request.body,
                              contentType: try #require(request.request.value(forHTTPHeaderField: "Content-Type")))
    #expect(parts.payload == nil)
}

@Test func submittingReturnsTheIDTheReportIsSentUnder() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    let id = try await container.submit(feedback())
    await #expect(throws: FlightDataError.unsupportedReportType(Sighting.name)) {
        try await container.submit(Sighting())
    }
    await container.deliverPending()
    #expect(rig.sent.count == 1)
    let request = try #require(rig.sent.first)
    let parts = try Multipart(body: request.body,
                              contentType: try #require(request.request.value(forHTTPHeaderField: "Content-Type")))
    let json = try #require(JSONSerialization.jsonObject(with: parts.report) as? [String: Any])
    #expect(json["id"] as? String == id.uuidString.lowercased())
}

@Test func theQueueHoldsOnlySealedBytes() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let container = rig.container()
    let attachment = ReportFile(name: "a.txt", contentType: "text/plain", data: Data("secret attachment".utf8))
    try await container.submit(feedback(files: [attachment]))
    await container.deliverPending()
    let files = try FileManager.default.subpathsOfDirectory(atPath: rig.directory.path)
    #expect(!files.isEmpty)
    for path in files {
        let url = rig.directory.appending(path: path)
        guard let data = try? Data(contentsOf: url) else { continue }
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Arrows overlap") && !text.contains("secret attachment"))
    }
}

@Test func aFailedSendIsRetriedWithBackoffAndThenDelivered() async throws {
    let calls = Counter()
    let rig = Rig(reply: { _ in calls.next() < 2 ? .status(503) : .status(201) })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.sent.count >= 1)
    let after = rig.sent.count
    #expect(await container.pendingCount == 1)
    // Not due yet: nothing is sent.
    rig.clock.advance(10)
    await container.deliverPending()
    #expect(rig.sent.count == after)
    // Due after the first backoff of 30 seconds.
    rig.clock.advance(30)
    await container.deliverPending()
    #expect(rig.sent.count == after + 1)
    #expect(await container.pendingCount == 1)
    // The second backoff doubles to 60 seconds.
    rig.clock.advance(59)
    await container.deliverPending()
    #expect(rig.sent.count == after + 1)
    rig.clock.advance(2)
    await container.deliverPending()
    #expect(await container.pendingCount == 0)
}

@Test func theServersRetryAfterIsHonored() async throws {
    let rig = Rig(reply: { _ in .status(429, headers: ["Retry-After": "600"]) })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    let entry = try #require(rig.queue.entries().first)
    #expect(entry.state.notBefore.timeIntervalSince(rig.clock.now) == 600)
}

@Test func theOutcomeDependsOnWhatTheServerSays() {
    func outcome(_ status: Int, _ retryAfter: String? = nil) -> DeliveryOutcome {
        ReportSender.outcome(status: status, retryAfter: retryAfter)
    }
    // A success without a receipt, such as a captive portal's page, isn't taken for one.
    #expect(outcome(200) == .retry(after: nil))
    #expect(outcome(201) == .retry(after: nil))
    #expect(outcome(202) == .retry(after: nil))
    for status in [400, 409, 413, 415, 422] { #expect(outcome(status) == .drop(status: status)) }
    // Not refused as it is: a later attempt can succeed (a key that isn't known yet, an app paused, a busy server).
    for status in [401, 403, 404, 408, 429, 500, 502, 503] { #expect(outcome(status) == .retry(after: nil)) }
    #expect(outcome(503, " 120 ") == .retry(after: 120))
    #expect(outcome(503, "Wed, 21 Oct 2026 07:28:00 GMT") == .retry(after: nil))
}

@Test func onlyAReceiptAcknowledgesAQueuedReport() async throws {
    for body in ["", "<html>Maintenance</html>", #"{"received":false}"#, #"{"received":"true"}"#, #"{"received":1}"#] {
        for status in [200, 201, 202] {
            #expect(ReportSender.outcome(status: status, retryAfter: "60", body: Data(body.utf8)) == .retry(after: 60))
        }
    }
    // Any success that says it was received delivers the report, whatever else it says.
    let quietReceipt = Data(#"{"received":true}"#.utf8)
    for status in [200, 201, 202, 204] {
        #expect(ReportSender.outcome(status: status, retryAfter: nil, body: quietReceipt) == .delivered(verified: nil))
    }

    let rig = Rig { _ in .status(200, body: "<html>Maintenance</html>") }
    defer { rig.cleanUp() }
    let container = rig.container()
    let id = try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.queue.entries().map(\.id) == [id])
    StubURLProtocol.setReply(rig.host) { _ in .status(201) }
    rig.clock.advance(31)
    await container.deliverPending()
    #expect(rig.queue.entries().isEmpty)
    let reports = try rig.sent.map { request in
        try Multipart(body: request.body,
                      contentType: #require(request.request.value(forHTTPHeaderField: "Content-Type"))).report
    }
    #expect(reports.count == 2 && reports.first == reports.last)
}

@Test func howLongToWaitComesFromRetryAfterOrTheProblemsOwnField() {
    func outcome(_ retryAfter: String?, _ body: String) -> DeliveryOutcome {
        ReportSender.outcome(status: 429, retryAfter: retryAfter, body: Data(body.utf8))
    }
    let limited = problem(429, "rate_limited", retryAfter: 90)
    #expect(outcome(nil, limited) == .retry(after: 90))
    #expect(outcome("30", limited) == .retry(after: 30))
    #expect(outcome(nil, problem(503, "temporarily_unavailable")) == .retry(after: nil))
}

@Test func aRateLimitedReportWaitsAsLongAsTheServerAsks() async throws {
    let limited = problem(429, "rate_limited", retryAfter: 1800)
    let rig = Rig(reply: { _ in .status(429, headers: ["Retry-After": "1800"], body: limited) })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    let entry = try #require(rig.queue.entries().first)
    #expect(entry.state.notBefore.timeIntervalSince(rig.clock.now) == 1800)
}

@Test func aMalformedReportIsDroppedNotRetried() async throws {
    let rig = Rig(reply: { _ in .status(422) })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.sent.count >= 1)
    #expect(await container.pendingCount == 0)
}

@Test func aRefusalThatMayPassIsKeptForLater() async throws {
    let rig = Rig(reply: { _ in .status(401) })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(await container.pendingCount == 1)
}

@Test func aReportUnsentAfterThirtyDaysIsDropped() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(await container.pendingCount == 1)
    rig.clock.advance(ReportQueue.maximumAge - 60)
    await container.deliverPending()
    #expect(await container.pendingCount == 1)
    let before = rig.sent.count
    rig.clock.advance(120)
    await container.deliverPending()
    #expect(await container.pendingCount == 0)
    #expect(rig.sent.count == before)
}

@Test func aQueuedReportSurvivesARelaunch() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let first = rig.container()
    let id = try await first.submit(feedback())
    await first.deliverPending()
    #expect(rig.queue.entries().map(\.id) == [id])
    StubURLProtocol.setReply(rig.host) { _ in .status(201) }
    rig.clock.advance(60)
    let relaunched = rig.container()
    await relaunched.deliverPending()
    #expect(await relaunched.pendingCount == 0)
    #expect(rig.sent.last.flatMap { String(decoding: $0.body,
                                           as: UTF8.self) }?.contains(id.uuidString.lowercased()) == true)
}

@Test func makingAContainerSendsWhatAnEarlierRunLeft() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let first = rig.container()
    try await first.submit(feedback())
    await first.deliverPending()
    #expect(rig.queue.entries().count == 1)
    StubURLProtocol.setReply(rig.host) { _ in .status(201) }
    rig.clock.advance(60)
    // Nothing asks this one to deliver.
    let relaunched = rig.container()
    for _ in 0..<200 where await relaunched.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await relaunched.pendingCount == 0)
}

@Test func theSameReportIsNeverQueuedTwice() throws {
    let queue = ReportQueue(root: temporaryDirectory())
    defer { try? FileManager.default.removeItem(at: queue.root) }
    let report = try PreparedReport.make(try feedback().content(), kind: .feedback, channel: "billing", app: testApp,
                                         test: false, recipient: Keys().recipient)
    try queue.enqueue(report, now: Date())
    try queue.enqueue(report, now: Date().addingTimeInterval(100))
    #expect(queue.entries().count == 1)
    #expect(try queue.report(try #require(queue.entries().first)) == report)
}

@Test func reportsAreSentOldestFirstAndDamagedFoldersAreCleanedUp() throws {
    let queue = ReportQueue(root: temporaryDirectory())
    defer { try? FileManager.default.removeItem(at: queue.root) }
    let keys = Keys()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var ids: [UUID] = []
    for offset in [20.0, 0, 10] {
        let report = try PreparedReport.make(try feedback().content(), kind: .feedback, channel: "billing",
                                             app: testApp, test: false, recipient: keys.recipient)
        try queue.enqueue(report, now: start.addingTimeInterval(offset))
        ids.append(report.id)
    }
    #expect(queue.entries().map(\.id) == [ids[1], ids[2], ids[0]])
    let empty = queue.root.appending(path: UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let leftover = queue.root.appending(path: ".new-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    let listing = queue.listing(at: start)
    #expect(listing.entries.count == 3 && listing.leftovers.count == 2)
    #expect(FileManager.default.fileExists(atPath: empty.path) && FileManager.default.fileExists(atPath: leftover.path))
    queue.tidy(listing)
    #expect(!FileManager.default.fileExists(atPath: empty.path))
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
}

@Test func backoffDoublesFromThirtySecondsToSixHours() {
    #expect([1, 2, 3, 4].map(ReportQueue.backoff(attempts:)) == [30, 60, 120, 240])
    #expect(ReportQueue.backoff(attempts: 40) == 6 * 60 * 60)
    #expect(ReportQueue.backoff(attempts: 0) == 30)
}

@Test func reportsThatCannotBeSealedAreRefusedAtSendAndNothingIsQueued() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    await #expect(throws: ReportValidationError.self) { try await container.submit(Feedback(title: "", body: "")) }
    #expect(await container.pendingCount == 0)
    #expect(rig.sent.isEmpty)
}

@Test func aStateThatCannotBeSavedIsNotRetriedEverySecond() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let container = rig.container()
    let id = try await container.submit(feedback())
    await container.deliverPending()
    // A folder that can be read but not written to: the report is there, and its next attempt can't be saved.
    let folder = rig.directory.appending(path: id.uuidString.lowercased())
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    var waits: [TimeInterval] = []
    for _ in 0..<3 {
        rig.clock.advance(6 * 60 * 60)
        await container.deliverPending()
        let retry = try #require(await container.retryAt)
        waits.append(retry.timeIntervalSince(rig.clock.now))
    }
    #expect(waits == [30, 60, 120])
}

@Test func anUnreadableReportBacksTheNextPassOff() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    await container.deliverPending()
    // A report folder that can't be listed.
    let folder = rig.directory.appending(path: UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    var waits: [TimeInterval] = []
    for _ in 0..<3 {
        await container.deliverPending()
        waits.append(try #require(await container.retryAt).timeIntervalSince(rig.clock.now))
    }
    #expect(waits == [30, 60, 120])
    #expect(await container.pendingCount == 1)
}

@Test func countingWhatIsPendingChangesNothingOnDisk() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let container = rig.container()
    let id = try await container.submit(feedback())
    await container.deliverPending()
    let leftover = rig.directory.appending(path: ".new-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    let state = rig.directory.appending(path: id.uuidString.lowercased()).appending(path: "state.json")
    try FileManager.default.removeItem(at: state)
    #expect(await container.pendingCount == 1)
    #expect(FileManager.default.fileExists(atPath: leftover.path))
    #expect(!FileManager.default.fileExists(atPath: state.path))
    await container.deliverPending()
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(FileManager.default.fileExists(atPath: state.path))
}

@Test func passesAskedForDuringAPassBecomeOneMore() async throws {
    let gate = Gate()
    let rig = Rig(reply: { _ in
        gate.wait()
        return .status(201)
    })
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    try await waitUntil { !rig.sent.isEmpty }
    let running = await container.passCount
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 { group.addTask { await container.deliverPending() } }
        try? await waitUntil { await container.passRequested }
        gate.open()
    }
    #expect(await container.passCount == running + 1)
    #expect(rig.sent.count == 1)
}

/// Holds a reply until the test opens it.
private final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    func open() {
        condition.withLock { isOpen = true }
        condition.broadcast()
    }
    func wait() {
        condition.withLock { while !isOpen { condition.wait() } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            defer { count += 1 }
            return count
        }
    }
}

// MARK: - Triggers

private let comeBack = Notification.Name("FlightDataTests.comeBack")

private func inputs(_ center: NotificationCenter,
                    paths: AsyncStream<Bool> = AsyncStream { _ in }) -> DeliveryTriggers.Inputs {
    DeliveryTriggers.Inputs(center: center, foreground: [comeBack], suspension: [], reachability: { paths })
}

@Test func comingBackToTheForegroundSendsAReportThatCouldNotReachTheServer() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let center = NotificationCenter()
    let container = try await rig.watchingContainer(triggers: inputs(center))
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(await container.pendingCount == 1)
    let before = rig.sent.count
    // Well before the 30 second backoff ends.
    StubURLProtocol.setReply(rig.host) { _ in .status(201) }
    rig.clock.advance(6)
    center.post(name: comeBack, object: nil)
    try await waitUntil { await container.pendingCount == 0 }
    #expect(await container.pendingCount == 0)
    #expect(rig.sent.count == before + 1)
}

@Test func theNetworkReturningSendsAReportThatCouldNotReachTheServer() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let (paths, changes) = AsyncStream<Bool>.makeStream()
    let container = try await rig.watchingContainer(triggers: inputs(NotificationCenter(), paths: paths))
    changes.yield(false)
    try await container.submit(feedback())
    await container.deliverPending()
    StubURLProtocol.setReply(rig.host) { _ in .status(201) }
    rig.clock.advance(6)
    changes.yield(true)
    try await waitUntil { await container.pendingCount == 0 }
    #expect(await container.pendingCount == 0)
}

@Test func onlyANetworkThatComesBackTriggers() {
    var network = DeliveryTriggers.NetworkReturn()
    let answers = [true, true, false, false, true, true, false, true]
    #expect(answers.map { network.update($0) } == [false, false, false, false, true, false, false, true])
}

@Test func aWaitTheServerAskedForSurvivesATrigger() async throws {
    let rig = Rig(reply: { _ in .status(429, headers: ["Retry-After": "600"]) })
    defer { rig.cleanUp() }
    let container = try await rig.watchingContainer(triggers: inputs(NotificationCenter()))
    try await container.submit(feedback())
    await container.deliverPending()
    let before = rig.sent.count
    rig.clock.advance(60)
    await container.retryNow()
    #expect(rig.sent.count == before)
    #expect(rig.queue.entries().first?.state.notBefore.timeIntervalSince(rig.clock.now) == 540)
}

@Test func aTriggerDoesNotSendAgainAReportThatJustFailed() async throws {
    let rig = Rig(reply: { _ in .failure })
    defer { rig.cleanUp() }
    let container = try await rig.watchingContainer(triggers: inputs(NotificationCenter()))
    try await container.submit(feedback())
    await container.deliverPending()
    let before = rig.sent.count
    await container.retryNow()
    await container.retryNow()
    #expect(rig.sent.count == before)
    rig.clock.advance(6)
    await container.retryNow()
    #expect(rig.sent.count == before + 1)
}

@Test func onlyAFailureToReachTheServerIsMarkedForAnEarlyRetry() async throws {
    let queue = ReportQueue(root: temporaryDirectory())
    defer { try? FileManager.default.removeItem(at: queue.root) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var ids: [UUID] = []
    for _ in 0..<3 {
        let report = try PreparedReport.make(try feedback().content(), kind: .feedback, channel: "billing",
                                             app: testApp,
                                         test: false, recipient: Keys().recipient)
        try queue.enqueue(report, now: start)
        ids.append(report.id)
    }
    let entries = queue.entries()
    let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    queue.recordFailure(byID[ids[0]]!, retryAfter: nil, unreachable: true, now: start)
    queue.recordFailure(byID[ids[1]]!, retryAfter: 600, unreachable: true, now: start)
    queue.recordFailure(byID[ids[2]]!, retryAfter: nil, now: start)
    queue.makeDue(now: start.addingTimeInterval(10))
    let after = Dictionary(uniqueKeysWithValues: queue.entries().map { ($0.id, $0.state.notBefore) })
    #expect(after[ids[0]] == start.addingTimeInterval(10))
    #expect(after[ids[1]] == start.addingTimeInterval(600))
    #expect(after[ids[2]] == start.addingTimeInterval(30))
}

// MARK: - Background time

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func raise() { lock.withLock { value += 1 } }
}

@Test func backgroundWorkRunsOnceAndIsFinishedOnce() async {
    let ran = Flag(), finished = Flag()
    let job = BackgroundTime.Job({ ran.raise() }, finished: { finished.raise() })
    await Task.detached { job.handle(expired: false) }.value
    job.handle(expired: true)
    #expect(ran.count == 1 && finished.count == 1)
}

@Test func backgroundWorkIsCancelledWhenTheTimeRunsOut() async throws {
    let started = Flag(), cancelled = Flag(), finished = Flag()
    let job = BackgroundTime.Job({
        started.raise()
        for _ in 0..<500 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        if Task.isCancelled { cancelled.raise() }
    }, finished: { finished.raise() })
    let waiting = Task.detached { job.handle(expired: false) }
    try await waitUntil { started.count == 1 }
    job.handle(expired: true)
    await waiting.value
    #expect(cancelled.count == 1 && finished.count == 1)
}

@Test func backgroundWorkStillRunsWhenTheSystemGivesNoTime() async throws {
    let ran = Flag()
    let job = BackgroundTime.Job({ ran.raise() }, finished: {})
    job.handle(expired: true)
    try await waitUntil { ran.count == 1 }
    #expect(ran.count == 1)
}
