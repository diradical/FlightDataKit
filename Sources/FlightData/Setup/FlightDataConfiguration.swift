// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// How some of an app's report types are saved, and who can read them: whether each report is submitted on its
/// own or gathered over a period, and the public key the reports are sealed to.
///
/// A configuration that names no types covers every type the container's other configurations don't, except
/// periodic types, which each need a configuration of their own.
public struct FlightDataConfiguration: Sendable {
    /// How long a periodic type gathers before it is sent.
    public struct Period: Hashable, Sendable {
        /// The period's length. A negative or infinite length is zero, which sends each event on its own.
        public let seconds: TimeInterval

        private init(seconds: TimeInterval) {
            self.seconds = seconds.isFinite ? max(0, seconds) : 0
        }

        /// A period of whole days.
        public static func days(_ days: Int) -> Period { Period(seconds: TimeInterval(days) * 86_400) }
        /// A period of whole hours.
        public static func hours(_ hours: Int) -> Period { Period(seconds: TimeInterval(hours) * 3_600) }
        /// A period of any length.
        public static func seconds(_ seconds: TimeInterval) -> Period { Period(seconds: seconds) }
    }

    /// How a type's reports leave the app.
    public enum Saves: Hashable, Sendable {
        /// Each report is its own, sent when the app calls ``FlightDataContainer/submit(_:)``, as a form does when
        /// the person presses Submit.
        case explicitly
        /// Events the app records with ``FlightDataContainer/record(_:)`` are folded together with the type's
        /// ``PeriodicFlightDataReport/merge(_:)``, and one report is sent each period.
        case every(Period)
    }

    /// The types it covers. Empty for the configuration that covers every other type.
    public let types: [any FlightDataReport.Type]
    /// How the types' reports leave the app.
    public let saves: Saves
    /// `fdpk2_…`, which the reports are sealed to. Its private key is in Flight Data Recorder.
    public let publicKey: String

    /// For a periodic type: how a gathered report's JSON becomes what is sent.
    let periodicContent: (@Sendable (Data) throws -> ReportContent)?

    /// Types whose reports are submitted one by one, sealed to `publicKey`. With no types, it covers every type
    /// the other configurations don't.
    public init(for types: any FlightDataReport.Type..., publicKey: String) {
        self.init(for: types, publicKey: publicKey)
    }

    /// Types whose reports are submitted one by one, sealed to `publicKey`. With no types, it covers every type
    /// the other configurations don't.
    public init(for types: [any FlightDataReport.Type], publicKey: String) {
        self.types = types
        self.saves = .explicitly
        self.publicKey = publicKey
        self.periodicContent = nil
    }

    /// A periodic type, whose events are gathered and sent once each `period`, sealed to `publicKey`.
    public init<Report: PeriodicFlightDataReport>(periodic type: Report.Type, every period: Period, publicKey: String) {
        self.types = [type]
        self.saves = .every(period)
        self.publicKey = publicKey
        self.periodicContent = { try JSONDecoder().decode(Report.self, from: $0).content() }
    }
}
