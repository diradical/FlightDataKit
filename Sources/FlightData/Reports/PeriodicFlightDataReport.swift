// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

/// A report that gathers what an app records over a period, such as how often something was used this week.
///
/// The app records each event with ``FlightDataContainer/record(_:)``. The first event of a period starts it,
/// and each later one is folded into it with ``merge(_:)``; when the period ends, the result is sent as one report.
/// Between events the gathered value is kept on the device as JSON, so keep its `Codable` form stable across app
/// updates. Register the type with ``FlightDataConfiguration/init(periodic:every:publicKey:)``.
public protocol PeriodicFlightDataReport: FlightDataReport, Codable {
    /// Folds a later event of the same period into this one.
    mutating func merge(_ newer: Self)
}
