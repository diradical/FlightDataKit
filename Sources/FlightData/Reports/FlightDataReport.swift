// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// A report an app sends: `Feedback`, or a type of the app's own. Its ``content()`` is exactly what leaves the
/// device, sealed so that only the developer can read it.
///
/// Adopt ``FieldFlightDataReport`` to list the fields, or ``ReflectedFlightDataReport`` to send every stored
/// property; add ``PeriodicFlightDataReport`` for a report that gathers events over a period.
public protocol FlightDataReport: Sendable {
    /// The report's channel: the name it is routed and shown under. 1 to 256 bytes. Defaults to the type's name;
    /// give a stable name of your own so that renaming the type keeps the reports together.
    static var name: String { get }

    /// What sort of report it is to the server. Defaults to ``ReportKind/telemetry``, which is sent only while the
    /// person allows telemetry.
    static var kind: ReportKind { get }

    /// The title, description, contact details, fields and files to seal.
    func content() throws -> ReportContent
}

extension FlightDataReport {
    /// The type's name.
    public static var name: String { String(describing: Self.self) }
    /// ``ReportKind/telemetry``.
    public static var kind: ReportKind { .telemetry }
}
