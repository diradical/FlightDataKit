// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

/// Stands in for App Attest: keys are numbered, an attestation is the client data hash it was asked to attest, and
/// an assertion is the client data hash it was asked to sign, so a test can see exactly what was proven.
private final class FakeAttestor: AppAttestor, @unchecked Sendable {
    private let lock = NSLock()
    private var supported: Bool
    private var made = 0
    private var attestFailure: AttestorError?
    private var assertFailure: AttestorError?
    private var attested: [String] = []

    init(supported: Bool = true) { self.supported = supported }

    var isSupported: Bool { lock.withLock { supported } }
    var appIDPrefix: String? { "ABCDE12345" }
    var keysMade: Int { lock.withLock { made } }
    var keysAttested: [String] { lock.withLock { attested } }
    func failAttesting(_ error: AttestorError?) { lock.withLock { attestFailure = error } }
    func failAsserting(_ error: AttestorError?) { lock.withLock { assertFailure = error } }

    func generateKey() async throws -> String {
        lock.withLock {
            made += 1
            return "key-\(made)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if let attestFailure { throw attestFailure }
            attested.append(keyID)
            return clientDataHash
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if let assertFailure { throw assertFailure }
            return clientDataHash
        }
    }
}

/// A server that gives challenges, enrolls keys and takes reports, each answered as the test says.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var challenge = StubURLProtocol.Reply.status(201, body: #"{"challenge":"the-challenge","expires_in":300}"#)
    private var enrollment = StubURLProtocol.Reply.status(201, body: #"{"enrolled":true,"environment":"production"}"#)
    private var report = StubURLProtocol.Reply.status(201, body: #"{"received":true,"verified":true}"#)

    func answerChallenges(_ reply: StubURLProtocol.Reply) { lock.withLock { challenge = reply } }
    func answerEnrollments(_ reply: StubURLProtocol.Reply) { lock.withLock { enrollment = reply } }
    func answerReports(_ reply: StubURLProtocol.Reply) { lock.withLock { report = reply } }

    func reply(to sent: StubURLProtocol.Sent) -> StubURLProtocol.Reply {
        lock.withLock {
            let path = sent.request.url?.path() ?? ""
            if path.hasSuffix("/v1/attest/challenges") { return challenge }
            if path.hasSuffix("/v1/attest/keys") { return enrollment }
            return report
        }
    }
}

private struct Rig {
    let keys = Keys()
    let clock = TestClock()
    let directory = temporaryDirectory()
    let collector = Collector()
    let attestor: FakeAttestor
    let host: String
    /// What the endpoint's path starts with: nothing, or `/api` as the default endpoint's does.
    let prefix: String
    let appToken = FlightDataTests.appToken("b")

    init(supported: Bool = true, prefix: String = "") {
        self.prefix = prefix
        attestor = FakeAttestor(supported: supported)
        let collector = collector
        host = StubURLProtocol.host { collector.reply(to: $0) }
    }

    func container() -> FlightDataContainer {
        testContainer([Feedback.self], [FlightDataConfiguration(publicKey: keys.publicKey)], host: host,
                      directory: directory, clock: clock, token: appToken, path: prefix, attestor: attestor)
    }

    func sent(_ path: String) -> [StubURLProtocol.Sent] {
        StubURLProtocol.requests(to: host).filter { $0.request.url?.path() == prefix + path }
    }
    var challenges: Int { sent("/v1/attest/challenges").count }
    var enrollments: [StubURLProtocol.Sent] { sent("/v1/attest/keys") }
    var reports: [StubURLProtocol.Sent] { sent("/v1/reports") }
    var queue: ReportQueue { ReportQueue(root: directory) }
    var state: ReportProver.State? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: directory.appending(path: "attest.json")))
            .flatMap { try? decoder.decode(ReportProver.State.self, from: $0) }
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func feedback(files: [ReportFile] = []) -> Feedback {
    Feedback(title: "Arrows overlap", body: "They do.", fields: [:], files: files)
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A refusal whose errors name `field` with `code`, as the server writes one.
private func refusal(_ message: String, _ field: String, _ code: String) -> String {
    #"{"message":"\#(message)","errors":[{"field":"\#(field)","code":"\#(code)"}]}"#
}

private let required = StubURLProtocol.Reply.status(403, body: refusal("Verified copies only.", "proof", "required"))
private let unknownKey = StubURLProtocol.Reply.status(401, body: refusal("Not verified.", "proof", "unknown_key"))
private let unverified = StubURLProtocol.Reply.status(201, body: #"{"received":true,"verified":false}"#)
private let keyNotKnown = StubURLProtocol.Reply.status(
    201, body: #"{"received":true,"verified":false,"proof":"unknown_key"}"#)

@Test func aCopyEnrollsOnceAndSignsEveryReport() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    let document = ReportFile(name: "doc.txt", contentType: "text/plain", data: Data("doc".utf8))
    try await container.submit(feedback(files: [document]))
    await container.deliverPending()

    // One challenge to enroll with, and one for the report.
    #expect(rig.challenges == 2)
    let enrollment = try #require(rig.enrollments.first)
    #expect(enrollment.request.value(forHTTPHeaderField: "Authorization") == "Ingest " + rig.appToken)
    #expect(enrollment.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let enrolled = try #require(JSONSerialization.jsonObject(with: enrollment.body) as? [String: String])
    // The key is attested with the SHA-256 of the challenge, and the copy says what it is signed with.
    #expect(enrolled == ["key_id": "key-1", "challenge": "the-challenge", "app_id_prefix": "ABCDE12345",
                         "attestation": Data(SHA256.hash(data: Data("the-challenge".utf8))).base64EncodedString()])

    let report = try #require(rig.reports.first)
    #expect(report.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-1")
    #expect(report.request.value(forHTTPHeaderField: "X-Attest-Challenge") == "the-challenge")
    let parts = try Multipart(body: report.body,
                              contentType: try #require(report.request.value(forHTTPHeaderField: "Content-Type")))
    // What is signed is worked out from the bytes that are sent, as the server works it out from what arrives.
    let payloadHash = hex(try #require(parts.payload))
    let signedText = "FlightData report proof 1\nthe-challenge\n\(hex(parts.report))\n\(payloadHash)"
    let signed = Data(SHA256.hash(data: Data(signedText.utf8)))
    #expect(report.request.value(forHTTPHeaderField: "X-Attest-Assertion") == signed.base64EncodedString())
    #expect(rig.queue.entries().isEmpty)

    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.challenges == 3 && rig.enrollments.count == 1 && rig.attestor.keysMade == 1)
    let second = try #require(rig.reports.last)
    let secondParts = try Multipart(body: second.body,
                                    contentType: try #require(second.request.value(forHTTPHeaderField: "Content-Type")))
    let secondText = "FlightData report proof 1\nthe-challenge\n\(hex(secondParts.report))\n-"
    let secondSigned = Data(SHA256.hash(data: Data(secondText.utf8)))
    #expect(second.request.value(forHTTPHeaderField: "X-Attest-Assertion") == secondSigned.base64EncodedString())
    #expect(rig.state?.enrolled == true)
}

@Test func aCopyThatCannotProveItselfSendsWithoutAndDropsWhatIsRefusedForIt() async throws {
    let rig = Rig(supported: false)
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.challenges == 0 && rig.enrollments.isEmpty)
    #expect(rig.reports.first?.request.value(forHTTPHeaderField: "X-Attest-Assertion") == nil)
    #expect(rig.queue.entries().isEmpty)

    // The app takes verified reports only, and this device never can prove itself: waiting would not help.
    rig.collector.answerReports(required)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.count == 2)
    #expect(rig.queue.entries().isEmpty)
}

@Test func anAppWhoseCopiesCannotBeVerifiedIsAskedAgainADayLater() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    rig.collector.answerChallenges(.status(403, body: refusal("Not for this platform.", "app", "unsupported")))
    rig.collector.answerReports(unverified)
    let container = rig.container()
    for _ in 0..<2 {
        try await container.submit(feedback())
        await container.deliverPending()
    }
    #expect(rig.challenges == 1)
    #expect(rig.attestor.keysMade == 0)
    #expect(rig.reports.count == 2)
    #expect(rig.reports.allSatisfy { $0.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == nil })
    #expect(rig.queue.entries().isEmpty)

    rig.clock.advance(ReportProver.later + 1)
    rig.collector.answerChallenges(.status(201, body: #"{"challenge":"c2","expires_in":300}"#))
    rig.collector.answerReports(.status(201, body: #"{"received":true,"verified":true}"#))
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.challenges == 3)
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-1")
}

@Test func aReportWaitsWhenProofIsRequiredAndTheCopyHasNotEnrolledYet() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    rig.collector.answerChallenges(.failure)
    rig.collector.answerReports(required)
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.queue.entries().count == 1)
    #expect(rig.reports.first?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == nil)

    // The server can be reached again: the copy enrolls and the same report goes with its proof.
    rig.collector.answerChallenges(.status(201, body: #"{"challenge":"c","expires_in":300}"#))
    rig.collector.answerReports(.status(201, body: #"{"received":true,"verified":true}"#))
    rig.clock.advance(ReportProver.soon + 1)
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-1")
    #expect(rig.queue.entries().isEmpty)
}

@Test func aKeyTheServerNoLongerKnowsIsReplacedAtOnceThenAtMostOnceADay() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-1")

    // Taken, but the server doesn't know the key: the report is not sent twice, and the next one comes from a new key.
    rig.collector.answerReports(keyNotKnown)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.queue.entries().isEmpty)
    #expect(rig.state?.keyID == nil)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-2")
    #expect(rig.enrollments.count == 2)

    // Still not believed: no third key until a day has passed, and reports go without a proof meanwhile.
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.enrollments.count == 2)
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == nil)
    rig.clock.advance(ReportProver.later + 1)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.enrollments.count == 3)
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-3")
}

@Test func aRefusedProofKeepsTheReportAndEnrollsAnotherKey() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    rig.collector.answerReports(unknownKey)
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.queue.entries().count == 1)
    #expect(rig.state?.enrolled == false)

    rig.collector.answerReports(.status(201, body: #"{"received":true,"verified":true}"#))
    rig.clock.advance(60)
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-2")
    #expect(rig.queue.entries().isEmpty)
}

@Test func aKeyLostToAReinstallIsEnrolledAgain() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()

    rig.attestor.failAsserting(.invalidKey)
    rig.collector.answerReports(unverified)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == nil)
    #expect(rig.state?.keyID == nil)

    rig.attestor.failAsserting(nil)
    rig.collector.answerReports(.status(201, body: #"{"received":true,"verified":true}"#))
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-2")
}

@Test func aKeyAppleCouldNotBeReachedForIsAttestedLater() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    rig.attestor.failAttesting(.unavailable)
    rig.collector.answerReports(unverified)
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.state?.keyID == "key-1" && rig.state?.enrolled == false)
    #expect(rig.enrollments.isEmpty)

    rig.attestor.failAttesting(nil)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.challenges == 1, "not before a quarter of an hour has passed")
    rig.clock.advance(ReportProver.soon + 1)
    rig.collector.answerReports(.status(201, body: #"{"received":true,"verified":true}"#))
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.attestor.keysMade == 1 && rig.attestor.keysAttested == ["key-1"])
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-1")
}

@Test func anEnrollmentTheServerRefusesIsNotTriedAgainForADay() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    rig.collector.answerEnrollments(.status(403, body: refusal("Not verified.", "attestation", "app_id")))
    rig.collector.answerReports(unverified)
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    rig.clock.advance(ReportProver.soon + 1)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.enrollments.count == 1)
    #expect(rig.state?.keyID == nil)
    rig.clock.advance(ReportProver.later)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.enrollments.count == 2 && rig.attestor.keysMade == 2)
}

@Test func aRefusalOverTheProofIsToldApartFromTheOthers() {
    func outcome(_ status: Int, _ body: String) -> DeliveryOutcome {
        ReportSender.outcome(status: status, retryAfter: nil, body: Data(body.utf8))
    }
    #expect(outcome(201, #"{"received":true,"verified":true}"#) == .delivered(verified: true))
    #expect(outcome(201, #"{"received":true,"verified":false}"#) == .delivered(verified: false))
    #expect(outcome(201, #"{"received":true,"verified":false,"proof":"unknown_key"}"#)
            == .delivered(verified: false, unknownKey: true))
    #expect(outcome(201, #"{"received":true,"verified":false,"proof":"challenge"}"#) == .delivered(verified: false))
    #expect(outcome(202, #"{"received":true}"#) == .delivered(verified: nil))
    #expect(outcome(403, #"{"message":"m","errors":[{"field":"proof","code":"required"}]}"#) == .proofRequired)
    #expect(outcome(403, #"{"message":"This app is not accepting reports.","errors":[]}"#) == .retry(after: nil))
    #expect(outcome(401, refusal("m", "proof", "counter")) == .proofRefused(unknownKey: false))
    #expect(outcome(401, refusal("m", "proof", "unknown_key")) == .proofRefused(unknownKey: true))
    #expect(outcome(401, #"{"message":"Send Authorization.","errors":[]}"#) == .retry(after: nil))
}

@Test func enrollingIsTriedAgainSoonOnlyWhenTheServerMightAnswerDifferently() async throws {
    for (status, wait) in [(422, ReportProver.later), (429, ReportProver.soon), (503, ReportProver.soon)] {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.collector.answerEnrollments(.status(status, body: #"{"message":"m","errors":[]}"#))
        rig.collector.answerReports(unverified)
        let container = rig.container()
        try await container.submit(feedback())
        await container.deliverPending()
        #expect(rig.state?.notBefore == rig.clock.now.addingTimeInterval(wait), "after \(status)")
        #expect(rig.state?.keyID == nil)
    }
}

@Test func whatIsSignedIsTheSameHereAsOnTheServer() {
    // The server's tests hold the same two answers, for the same challenge, report and payload.
    let json = Data(#"{"id":"x"}"#.utf8)
    func signed(_ payload: Data?) -> String {
        ReportProver.clientDataHash(PreparedReport(id: UUID(), json: json, payload: payload),
                                    challenge: "the-challenge")
            .map { String(format: "%02x", $0) }.joined()
    }
    #expect(signed(Data("payload".utf8)) == "92893286dace53d9a30879a950fed0c2a5d61cda2219e3d793c83f46f5dd7e8d")
    #expect(signed(nil) == "13bccec569895461e0228fbe484f521fc965670bcae039303319240c62417679")
}

@Test func anEnrolledCopyWaitsForAChallengeRatherThanSendWithoutAProof() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.count == 1)

    rig.collector.answerChallenges(.failure)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.count == 1, "nothing is sent without a challenge to sign")
    #expect(rig.queue.entries().count == 1)

    rig.collector.answerChallenges(.status(201, body: #"{"challenge":"another","expires_in":300}"#))
    rig.clock.advance(60)
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Challenge") == "another")
    #expect(rig.queue.entries().isEmpty)
    #expect(rig.enrollments.count == 1)
}

@Test func anEnrolledCopyOfAnAppThatCanNoLongerBeVerifiedSendsWithoutAProof() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()

    rig.collector.answerChallenges(.status(403,
                                           body: #"{"message":"m","errors":[{"field":"app","code":"unsupported"}]}"#))
    rig.collector.answerReports(unverified)
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.reports.count == 2)
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == nil)
    #expect(rig.queue.entries().isEmpty)
}

@Test func aChallengeTheServerRefusesIsNoReasonToGiveUpTheKey() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    rig.collector.answerReports(.status(401, body: refusal("Not verified.", "proof", "challenge")))
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.queue.entries().count == 1)
    #expect(rig.state?.keyID == "key-1" && rig.state?.enrolled == true)

    rig.collector.answerReports(.status(201, body: #"{"received":true,"verified":true}"#))
    rig.clock.advance(60)
    await container.deliverPending()
    #expect(rig.reports.last?.request.value(forHTTPHeaderField: "X-Attest-Key-ID") == "key-1")
    #expect(rig.enrollments.count == 1 && rig.attestor.keysMade == 1)
    #expect(rig.queue.entries().isEmpty)
}

@Test func onlyABusyOrUnreachableChallengeServerHoldsTheReport() async throws {
    for (reply, held, early) in [(StubURLProtocol.Reply.status(401, body: problem(401, "ingest_token_invalid")), false,
                                  false),
                                 (.status(500, body: "<html>Error</html>"), false, false),
                                 (.status(201, body: "{}"), false, false),
                                 (.status(408), true, false), (.status(503), true, false),
                                 (.failure, true, true)] {
        let rig = Rig()
        defer { rig.cleanUp() }
        let container = rig.container()
        try await container.submit(feedback())
        await container.deliverPending()
        #expect(rig.reports.count == 1)

        rig.collector.answerChallenges(reply)
        rig.collector.answerReports(unverified)
        try await container.submit(feedback())
        await container.deliverPending()
        // Any other answer sends the report without a proof; the report's own answer says if one is needed.
        #expect(rig.reports.count == (held ? 1 : 2), "\(reply)")
        let waiting = rig.queue.entries()
        #expect(waiting.count == (held ? 1 : 0), "\(reply)")
        // Only a server that couldn't be reached is tried again as soon as the network comes back.
        #expect(waiting.first.map(\.state.retriesWhenReachable) == (held ? early : nil), "\(reply)")
    }
}

@Test func underTheDefaultEndpointsPathEveryRequestGoesToTheVersionedRoutes() async throws {
    let rig = Rig(prefix: "/api")
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    let paths = StubURLProtocol.requests(to: rig.host).compactMap { $0.request.url?.path() }
    #expect(paths == ["/api/v1/attest/challenges", "/api/v1/attest/keys", "/api/v1/attest/challenges",
                      "/api/v1/reports"])
    #expect(rig.queue.entries().isEmpty)
}

@Test func theDefaultEndpointUsesTheVersionedCollectorRoutes() {
    let endpoint = FlightDataContainer.defaultEndpoint
    #expect(endpoint.absoluteString == "https://flightdata.dev/api")
    #expect(endpoint.appending(path: "v1/reports").absoluteString == "https://flightdata.dev/api/v1/reports")
    #expect(endpoint.appending(path: "v1/attest/challenges").absoluteString
            == "https://flightdata.dev/api/v1/attest/challenges")
    #expect(endpoint.appending(path: "v1/attest/keys").absoluteString == "https://flightdata.dev/api/v1/attest/keys")
}

@Test func aChallengeThatIsRateLimitedHoldsTheReportForAsLongAsTheServerAsks() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()

    let limited = problem(429, "rate_limited", retryAfter: 900)
    rig.collector.answerChallenges(.status(429, headers: ["Retry-After": "900"], body: limited))
    try await container.submit(feedback())
    await container.deliverPending()
    let entry = try #require(rig.queue.entries().first)
    #expect(entry.state.notBefore == rig.clock.now.addingTimeInterval(900))
}

@Test func anEnrollmentTheServerRateLimitsIsTriedAgainWhenItSays() async throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    let limited = problem(429, "rate_limited", retryAfter: 3600)
    rig.collector.answerEnrollments(.status(429, headers: ["Retry-After": "3600"], body: limited))
    rig.collector.answerReports(unverified)
    let container = rig.container()
    try await container.submit(feedback())
    await container.deliverPending()
    #expect(rig.state?.notBefore == rig.clock.now.addingTimeInterval(3600))
}

@Test func collectorProblemResponsesDetermineTheDeliveryOutcome() {
    func outcome(_ status: Int, _ body: String) -> DeliveryOutcome {
        ReportSender.outcome(status: status, retryAfter: nil, body: Data(body.utf8))
    }
    #expect(outcome(403, problem(403, "proof_required", errors: [("proof", "required")])) == .proofRequired)
    #expect(outcome(401, problem(401, "proof_invalid", errors: [("proof", "unknown_key")]))
            == .proofRefused(unknownKey: true))
    #expect(outcome(401, problem(401, "proof_invalid", errors: [("proof", "signature")]))
            == .proofRefused(unknownKey: false))
    #expect(outcome(401, problem(401, "ingest_token_invalid")) == .retry(after: nil))
    #expect(outcome(403, problem(403, "app_not_accepting")) == .retry(after: nil))
    #expect(outcome(409, problem(409, "record_id_conflict")) == .drop(status: 409))
    #expect(outcome(422, problem(422, "invalid_envelope", errors: [("sealed", "invalid")])) == .drop(status: 422))
}

/// Builds an `application/problem+json` response for the stub collector.
func problem(_ status: Int, _ code: String, errors: [(String, String)] = [], retryAfter: Int? = nil) -> String {
    var members = ["\"type\":\"about:blank\"", "\"title\":\"t\"", "\"status\":\(status)", "\"code\":\"\(code)\"",
                   "\"detail\":\"d\"", "\"request_id\":\"6f1e9a52-8f55-4f0e-9d1c-2b3a4c5d6e7f\""]
    if !errors.isEmpty {
        let listed = errors.map { "{\"field\":\"\($0.0)\",\"code\":\"\($0.1)\"}" }
        members.append("\"errors\":[" + listed.joined(separator: ",") + "]")
    }
    if let retryAfter { members.append("\"retry_after_seconds\":\(retryAfter)") }
    return "{" + members.joined(separator: ",") + "}"
}
