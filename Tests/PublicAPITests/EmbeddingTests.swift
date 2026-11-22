// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import FlightData
import FlightDataFeedback
import FlightDataFormat
import Foundation
import SwiftUI
import Testing

private struct CheckoutEvent: FieldFlightDataReport {
    static let name = "checkout"
    let count: Int
    private let note = "local fixture"
    var reportFields: [String: ReportValue] { ["checkout_count": ReportValue(count)] }
}

private struct WeeklyTotal: PeriodicFlightDataReport, FieldFlightDataReport {
    var count: Int
    var reportFields: [String: ReportValue] { ["count": ReportValue(count)] }
    mutating func merge(_ newer: Self) { count += newer.count }
}

/// A view an app writes: it gets the container from the environment and records as things happen.
private struct CheckoutButton: View {
    @Environment(\.flightDataContainer) private var flightData

    var body: some View {
        Button("Check Out") { flightData.record(WeeklyTotal(count: 1)) }
    }
}

@Test func outboundFieldsAndRecipientAreChosenByTheEmbeddingApp() throws {
    let report = CheckoutEvent(count: 1)
    #expect(report.content().fields == ["checkout_count": 1])
    let key = Curve25519.KeyAgreement.PrivateKey()
    let prepared = try PreparedReport.make(report.content(), kind: CheckoutEvent.kind, channel: CheckoutEvent.name,
                                           app: AppInfo(version: "1.0"), test: true, recipient: key.publicKey)
    let wire = try #require(JSONSerialization.jsonObject(with: prepared.json) as? [String: Any])
    #expect(wire["channel"] as? String == "checkout")
    #expect(wire["kind"] as? String == "telemetry")
    #expect(wire["key_id"] as? String == Envelope.keyID(for: key.publicKey))
    #expect(!String(decoding: prepared.json, as: UTF8.self).contains("checkout_count"))
}

@Test @MainActor func anAppSetsUpWithoutHandlingErrorsAndSubmitsOrRecords() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let publicKey = Envelope.publicKeyString(Curve25519.KeyAgreement.PrivateKey().publicKey)
    // Nothing is listening at this address, so nothing leaves the machine.
    let container = FlightDataContainer(
        for: ReportSchema([CheckoutEvent.self, WeeklyTotal.self]), appToken: "fdk_" + String(repeating: "c", count: 32),
        endpoint: URL(string: "http://127.0.0.1:9/api")!,
        configurations: FlightDataConfiguration(for: CheckoutEvent.self, publicKey: publicKey),
                        FlightDataConfiguration(periodic: WeeklyTotal.self, every: .days(7), publicKey: publicKey),
        marksReportsAsTests: true, directory: directory, telemetryEnabled: false)
    #expect(!container.telemetryEnabled)
    await #expect(throws: FlightDataError.telemetryDisabled) { try await container.submit(CheckoutEvent(count: 1)) }
    container.record(WeeklyTotal(count: 1))
    #expect(await container.pendingCount == 0)
    await container.setTelemetryEnabled(true)
    #expect(container.telemetryEnabled)

    let preview = FlightDataContainer.preview(for: Feedback.self, WeeklyTotal.self)
    preview.record(WeeklyTotal(count: 2))
    let id = try await preview.submit(Feedback(title: "Arrows overlap", body: "They do."))
    #expect(id.uuidString.isEmpty == false)
    do {
        try await preview.submit(Feedback(title: "", body: "No title"))
        Issue.record("A report without a title isn’t taken.")
    } catch let error as ReportValidationError {
        #expect(error.reason == .required && error.field == "title")
    }
    _ = CheckoutButton().flightDataContainer(preview)
}
