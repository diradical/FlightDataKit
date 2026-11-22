// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
@_spi(Testing) import FlightData
import FlightDataFeedback
import FlightDataFormat
import Foundation
import Testing

@Test func anotherPackagesTestsCanGiveTheSessionTheInstallIDAndTheClock() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let publicKey = Envelope.publicKeyString(Curve25519.KeyAgreement.PrivateKey().publicKey)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    // Nothing is listening at this address, so the report stays queued.
    let container = FlightDataContainer(
        for: ReportSchema([Feedback.self]), appToken: "fdk_" + String(repeating: "d", count: 32),
        endpoint: URL(string: "http://127.0.0.1:9/api")!,
        configurations: [FlightDataConfiguration(publicKey: publicKey)],
        marksReportsAsTests: true, directory: directory, session: URLSession(configuration: .ephemeral),
        installIDs: MemoryInstallIDStore("install-0123456789"), now: { start })
    let id = try await container.submit(Feedback(title: "Arrows overlap", body: "They do."))
    await container.deliverPending()
    #expect(await container.pendingCount == 1)
    let folder = directory.appending(path: id.uuidString.lowercased())
    let state = try Data(contentsOf: folder.appending(path: "state.json"))
    #expect(String(decoding: state, as: UTF8.self).contains("2027-01-15T08:00:00Z"))
    #expect(try MemoryInstallIDStore().installID().count == 32)
}
