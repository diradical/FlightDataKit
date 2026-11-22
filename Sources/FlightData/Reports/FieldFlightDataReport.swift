// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// A report that is a set of fields with keys the app chooses. Its title is its channel's name in words: a type
/// named `BankingAnalytics` is titled "Banking Analytics".
public protocol FieldFlightDataReport: FlightDataReport {
    /// The values the report sends, by key: at most 50, with keys of 1 to 64 characters.
    var reportFields: [String: ReportValue] { get }
}

extension FieldFlightDataReport {
    /// The channel's name in words as the title, and ``reportFields``.
    public func content() -> ReportContent {
        ReportContent(title: ReportProperty.words(Self.name), fields: reportFields)
    }
}
