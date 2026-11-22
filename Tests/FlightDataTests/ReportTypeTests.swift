// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

/// A type an app defines for itself, saved on a period.
struct BankingAnalytics: PeriodicFlightDataReport, ReflectedFlightDataReport {
    var transfers = 0
    var usesBillPay = false
    var duration: Double?

    mutating func merge(_ newer: BankingAnalytics) {
        transfers += newer.transfers
        usesBillPay = usesBillPay || newer.usesBillPay
        duration = newer.duration ?? duration
    }
}

private enum Plan: String, Codable { case free, pro }

private struct Everything: ReflectedFlightDataReport {
    var documentName = "Untitled 3"
    var pages = 12
    var zoom = 1.5
    var usesBillPay = true
    var plan = Plan.pro
    var note: String?
    var copies: Int? = 2
}

/// A crash report of an app's own: the server is told it is a crash, and which build it happened in.
private struct Crash: FlightDataReport {
    var summary = ""
    var log = ""

    static var kind: ReportKind { .crash }

    func content() throws -> ReportContent {
        ReportContent(title: summary,
                      files: [ReportFile(name: "crash.txt", contentType: "text/plain", data: Data(log.utf8))],
                      app: AppInfo(version: "1.1", build: "30", platform: "macOS", osVersion: "26.0.0",
                                   binaryUUID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
    }
}

struct ReportTypeRig {
    let keys = Keys()
    let clock = TestClock()
    let directory = temporaryDirectory()
    let host = StubURLProtocol.host { _ in .status(201) }

    func container(period: TimeInterval = 3_600, now: (@Sendable () -> Date)? = nil,
                   problems: Problems? = nil) -> FlightDataContainer {
        testContainer([Feedback.self, BankingAnalytics.self, Crash.self],
                      [FlightDataConfiguration(publicKey: keys.publicKey),
                       FlightDataConfiguration(periodic: BankingAnalytics.self, every: .seconds(period),
                                               publicKey: keys.publicKey)],
                      host: host, directory: directory, clock: clock, token: appToken("e"), now: now,
                      problems: problems)
    }

    /// The reports the server was sent, as their readable JSON.
    func sent() throws -> [[String: Any]] {
        try StubURLProtocol.requests(to: host).map { request in
            let contentType = try #require(request.request.value(forHTTPHeaderField: "Content-Type"))
            let parts = try Multipart(body: request.body, contentType: contentType)
            return try #require(JSONSerialization.jsonObject(with: parts.report) as? [String: Any])
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Test func aReflectedTypesPropertiesAreItsFieldsCalledByTheirNamesInWords() throws {
    let content = try Everything().content()
    #expect(content.title == "Everything" && content.body.isEmpty && content.files.isEmpty)
    #expect(content.fields == ["documentName": "Untitled 3", "pages": 12, "zoom": 1.5, "usesBillPay": true,
                               "plan": "pro",
                               "copies": 2])
    // In the order they are declared; an empty optional is left out.
    #expect(content.fieldDescriptions == [
        FieldDescription(key: "documentName", label: "Document Name", kind: .text),
        FieldDescription(key: "pages", label: "Pages", kind: .integer),
        FieldDescription(key: "zoom", label: "Zoom", kind: .number),
        FieldDescription(key: "usesBillPay", label: "Uses Bill Pay", kind: .boolean),
        FieldDescription(key: "plan", label: "Plan", kind: .text),
        FieldDescription(key: "copies", label: "Copies", kind: .integer)])
    #expect(BankingAnalytics.name == "BankingAnalytics" && BankingAnalytics.kind == .telemetry)
    #expect(try BankingAnalytics().content().title == "Banking Analytics")
    #expect(ReportProperty.words("experimentsRun") == "Experiments Run")
    #expect(ReportProperty.words("os_version") == "Os Version")
}

@Test func propertiesAFieldCannotHoldAreNamed() throws {
    struct Mixed {
        var count = 1
        var opened = Date(timeIntervalSince1970: 0)
        var link: URL? = URL(string: "https://example.test")
        var missing: URL?
        var plan = Plan.free
        var inner = Everything()
    }
    let reflected = try ReportProperty.fields(of: Mixed())
    #expect(reflected.fields == ["count": 1, "plan": "free"])
    #expect(reflected.unsupported == ["opened", "link", "inner"])
}

@Test func aTypeSavedOnAPeriodIsFoldedTogetherAndSentWhenThePeriodEnds() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    container.record(BankingAnalytics(transfers: 1))
    container.record(BankingAnalytics(transfers: 2))
    container.record(BankingAnalytics(usesBillPay: true))
    await container.deliverPending()
    // Nothing is sent until the period ends.
    #expect(try rig.sent().isEmpty)
    #expect(await container.pendingCount == 0)

    rig.clock.advance(3_600)
    container.record(BankingAnalytics(transfers: 1))
    await container.deliverPending()
    let report = try #require(try rig.sent().first)
    #expect(try rig.sent().count == 1)
    #expect(report["kind"] as? String == "telemetry" && report["channel"] as? String == "BankingAnalytics")
    let text = try openText(report, keys: rig.keys)
    #expect(text.title == "Banking Analytics" && text.fields == ["transfers": 3, "usesBillPay": true])
    #expect(text.fieldDescriptions.map(\.label) == ["Transfers", "Uses Bill Pay"])

    // The event at the deadline began the next period.
    container.record(BankingAnalytics(transfers: 5))
    await container.deliverPending()
    #expect(try rig.sent().count == 1)
    rig.clock.advance(3_600)
    await container.deliverPending()
    let next = try #require(try rig.sent().last)
    #expect(try openText(next, keys: rig.keys).fields["transfers"] == 6)
}

@Test func whatWasGatheredSurvivesARelaunchAndIsSentByTheNextContainer() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let first = rig.container()
    first.record(BankingAnalytics(transfers: 3))
    await first.deliverPending()
    rig.clock.advance(7_200)
    let relaunched = rig.container()
    await relaunched.deliverPending()
    let text = try openText(try #require(try rig.sent().first), keys: rig.keys)
    #expect(text.fields == ["transfers": 3, "usesBillPay": false])
}

@Test func eachSubmittedReportIsSentOnItsOwn() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    let first = try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
    let second = try await container.submit(Feedback(title: "Export fails", body: "At page 3."))
    #expect(first != second)
    await container.deliverPending()
    let sent = try rig.sent()
    let ids = Set(sent.compactMap { $0["id"] as? String })
    #expect(ids == [first.uuidString.lowercased(), second.uuidString.lowercased()])
    #expect(try sent.map { try openText($0, keys: rig.keys).title }.sorted() == ["Arrows overlap", "Export fails"])
}

@Test func aReportCanNameTheBuildItIsAboutWhichAnUpdateMayHaveReplaced() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    try await container.submit(Crash(summary: "SIGABRT in Canvas.draw()", log: "Incident Identifier: …"))
    try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
    await container.deliverPending()
    let sent = try rig.sent()
    let crash = try #require(sent.first { $0["kind"] as? String == "crash" })
    #expect(crash["channel"] as? String == "Crash")
    let crashed = try #require(crash["app"] as? [String: String])
    #expect(crashed["version"] == "1.1")
    #expect(crashed["build"] == "30")
    #expect(crashed["binary_uuid"] == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
    #expect(try openText(crash, keys: rig.keys).title == "SIGABRT in Canvas.draw()")
    // A report that names none is about the running app, as the container describes it.
    let feedback = try #require(sent.first { $0["kind"] as? String == "feedback" })
    #expect((feedback["app"] as? [String: String])?["version"] == testApp.version)
    #expect((feedback["app"] as? [String: String])?["binary_uuid"] == testApp.binaryUUID)
}

@Test func aReportThatCannotBeSealedIsThrownBySubmitAndNotKept() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    await #expect(throws: ReportValidationError(.required, "A title of 1–200 characters is required.",
                                                field: "title")) {
        try await container.submit(Feedback(title: "", body: "No title."))
    }
    #expect(await container.pendingCount == 0)
    try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
    await container.deliverPending()
    #expect(try rig.sent().count == 1)
}

@Test func aPreviewContainerChecksAndSealsButNeitherKeepsNorSends() async throws {
    let container = FlightDataContainer.preview(for: Feedback.self)
    _ = try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
    #expect(await container.pendingCount == 0)
    await #expect(throws: ReportValidationError.self) { try await container.submit(Feedback(title: "", body: "b")) }
}

@Test func theSmallestContainerSendsToThePublicServer() {
    let container = FlightDataContainer(for: Feedback.self, appToken: appToken(), publicKey: Keys().publicKey)
    #expect(container.endpoint.absoluteString == "https://flightdata.dev/api")
    #expect(container.appToken == appToken() && container.configurations.count == 1)
    #expect(container.setup?.routes[ObjectIdentifier(Feedback.self)]?.saves == .explicitly)
}
