// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Why a container didn't take a report. What is wrong with a report's own content is a ``ReportValidationError``.
public enum FlightDataError: Error, Equatable, Sendable, LocalizedError {
    /// The container can't send reports: its setup was invalid, or it is the stand-in a view gets when no
    /// `flightDataContainer(_:)` is above it. A debug build stops where that happened, with the reason.
    case notConfigured
    /// The report type isn't in the container's schema, or it is periodic, which ``FlightDataContainer/record(_:)``
    /// is for.
    case unsupportedReportType(String)
    /// The report is telemetry, and the person has turned telemetry off.
    case telemetryDisabled

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This app isn’t set up to send reports."
        case .unsupportedReportType(let name): "‘\(name)’ isn’t a report type this app submits."
        case .telemetryDisabled: "Telemetry is turned off."
        }
    }
}
