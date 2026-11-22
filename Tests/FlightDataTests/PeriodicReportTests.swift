// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFormat

@Test func anIdleAppSendsAtThePeriodDeadline() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container(period: 0.1, now: { Date() })
    container.record(BankingAnalytics(transfers: 2))
    // Nothing asks for delivery: the period's own deadline does.
    for _ in 0..<500 where StubURLProtocol.requests(to: rig.host).isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    let report = try #require(try rig.sent().first)
    #expect(try openText(report, keys: rig.keys).fields["transfers"] == 2)
}

@Test func invalidPeriodicIntervalsBecomeImmediatelyDue() async throws {
    for seconds in [0.0, -1.0, .nan, .infinity, -.infinity] {
        #expect(FlightDataConfiguration.Period.seconds(seconds).seconds == 0)
        let rig = ReportTypeRig()
        defer { rig.cleanUp() }
        let container = rig.container(period: seconds)
        container.record(BankingAnalytics(transfers: 2))
        await container.deliverPending()
        #expect(try rig.sent().count == 1)
        #expect(await container.pendingCount == 0)
    }
}

@Test func anEventBelongsToThePeriodItWasRecordedIn() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    container.record(BankingAnalytics(transfers: 1))
    rig.clock.advance(3_599)
    container.record(BankingAnalytics(transfers: 4))
    rig.clock.advance(2)
    container.record(BankingAnalytics(transfers: 2))
    await container.deliverPending()
    let totals = try rig.sent().map { try openText($0, keys: rig.keys).fields["transfers"] }
    #expect(totals == [5])
    rig.clock.advance(3_600)
    await container.deliverPending()
    #expect(try rig.sent().map { try openText($0, keys: rig.keys).fields["transfers"] } == [5, 2])
}

@Test func anUnencodablePeriodicEventDoesNotBlockLaterValidEvents() async throws {
    let rig = ReportTypeRig()
    defer { rig.cleanUp() }
    let container = rig.container()
    container.record(BankingAnalytics(transfers: 1))
    container.record(BankingAnalytics(transfers: 20, duration: .infinity))
    container.record(BankingAnalytics(transfers: 4))
    rig.clock.advance(3_600)
    await container.deliverPending()
    let report = try #require(try rig.sent().first)
    #expect(try openText(report, keys: rig.keys).fields["transfers"] == 5)
}
