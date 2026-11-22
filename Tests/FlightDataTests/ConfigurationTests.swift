// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation
import Testing
@testable import FlightData
import FlightDataFeedback
@testable import FlightDataFormat

@Test func eachRoutingMistakeIsNamed() throws {
    let schema = ReportSchema([Feedback.self, BankingAnalytics.self])
    let key = Keys().publicKey
    let fallback = FlightDataConfiguration(publicKey: key)
    let feedback = FlightDataConfiguration(for: Feedback.self, publicKey: key)
    let periodic = FlightDataConfiguration(periodic: BankingAnalytics.self, every: .days(1), publicKey: key)
    let unregistered = FlightDataConfiguration(for: OtherReport.self, publicKey: key)

    func check(_ configurations: [FlightDataConfiguration], _ expected: FlightDataConfigurationError) {
        #expect(throws: expected) { try schema.routes(for: configurations) }
    }

    check([fallback, fallback, periodic], .duplicateFallback)
    check([feedback, periodic, unregistered], .unknownType(OtherReport.name))
    check([feedback, feedback, periodic], .duplicateRoute(Feedback.name))
    check([FlightDataConfiguration(for: Feedback.self, Feedback.self, publicKey: key), periodic],
          .duplicateRoute(Feedback.name))
    check([periodic], .missingRoute(Feedback.name))
    check([fallback], .periodicWithoutPeriod(BankingAnalytics.name))
    check([FlightDataConfiguration(for: BankingAnalytics.self, publicKey: key), feedback],
          .periodicWithoutPeriod(BankingAnalytics.name))
    check([fallback, FlightDataConfiguration(for: Feedback.self, publicKey: "")],
          .invalidPublicKey(channels: ["Feedback"]))
    check([FlightDataConfiguration(publicKey: "invalid")], .invalidPublicKey(channels: []))
    let zero = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(repeating: 0, count: 32))
    check([FlightDataConfiguration(publicKey: Envelope.publicKeyString(zero))], .invalidPublicKey(channels: []))

    struct Unnamed: FieldFlightDataReport {
        static let name = ""
        var reportFields: [String: ReportValue] { [:] }
    }
    #expect(throws: FlightDataConfigurationError.invalidChannel("")) {
        try ReportSchema([Unnamed.self]).routes(for: [fallback])
    }
    #expect(throws: FlightDataConfigurationError.duplicateChannel(Feedback.name)) {
        try ReportSchema([Feedback.self, Feedback.self]).routes(for: [fallback])
    }
    #expect(try schema.routes(for: [periodic, fallback]).count == 2)
}

@Test func aSetupThatCannotWorkSaysWhyAndMakesAContainerThatSendsNothing() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let keys = Keys()
    let host = StubURLProtocol.host { _ in .status(201) }
    for (token, key) in [("test", keys.publicKey), (appToken(), "fdpk2_mistyped")] {
        let problems = Problems()
        let container = testContainer([Feedback.self, BankingAnalytics.self],
                                      [FlightDataConfiguration(publicKey: key),
                                       FlightDataConfiguration(periodic: BankingAnalytics.self, every: .days(1),
                                                               publicKey: keys.publicKey)],
                                      host: host, directory: directory, clock: TestClock(), token: token,
                                      problems: problems)
        #expect(problems.messages.count == 1)
        await #expect(throws: FlightDataError.notConfigured) {
            try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
        }
        container.record(BankingAnalytics(transfers: 1))
        await container.deliverPending()
        #expect(await container.pendingCount == 0)
        #expect(problems.messages.count == 1, "a container that sends nothing says so once, when it is made")
    }
    #expect(StubURLProtocol.requests(to: host).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing is written for it")
}

@Test func aReportTypeOutsideTheSchemaIsRefusedOrReported() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let problems = Problems()
    let container = rig.container(problems: problems)
    await #expect(throws: FlightDataError.unsupportedReportType(OtherReport.name)) {
        try await container.submit(OtherReport(value: 1))
    }
    await #expect(throws: FlightDataError.unsupportedReportType(BankingAnalytics.name)) {
        try await container.submit(BankingAnalytics(transfers: 1))
    }
    struct Elsewhere: PeriodicFlightDataReport, FieldFlightDataReport {
        var reportFields: [String: ReportValue] { [:] }
        mutating func merge(_ newer: Self) {}
    }
    container.record(Elsewhere())
    #expect(problems.messages.count == 1)
}

@Test func aViewWithNoContainerAboveItGetsAStandInThatSendsNothing() async throws {
    let placeholder = FlightDataContainer.placeholder
    #expect(placeholder.schema.types.isEmpty)
    #expect(await placeholder.pendingCount == 0)
}

@Test func thePreviewTakesPeriodicTypesAsWell() async throws {
    let container = FlightDataContainer.preview(for: Feedback.self, BankingAnalytics.self)
    #expect(container.configurations.count == 2)
    container.record(BankingAnalytics(transfers: 1))
    #expect(try await container.submit(Feedback(title: "Arrows overlap", body: "They do.")) != UUID())
    #expect(await container.pendingCount == 0)
}

private struct OtherReport: FieldFlightDataReport {
    static let name = "stable-channel"
    let value: Int
    var reportFields: [String: ReportValue] { ["stable_field": ReportValue(value)] }
}
