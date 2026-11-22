// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// A report that sends every stored property as a field, under the property's Swift name and labelled with the
/// name in words: `usesBillPay` is labelled "Uses Bill Pay". Its title is its channel's name in words.
///
/// Reflection reads private properties too and ignores `CodingKeys`, so adopt it only for a type whose stored
/// properties are all meant for the developer. Renaming a property renames its field; where the keys must outlive
/// a refactor, adopt ``FieldFlightDataReport`` and name them yourself.
///
/// A property can be:
/// - `String`, `Bool`, a signed or unsigned integer up to 64 bits, or a floating-point number
/// - a `RawRepresentable` whose raw value is one of those, such as a `String` enum
/// - an `Optional` of one of those: an empty one is left out
///
/// Any other type, such as `Date`, `URL` or a nested struct, stops a debug build; a release build leaves it out.
public protocol ReflectedFlightDataReport: FlightDataReport {}

extension ReflectedFlightDataReport {
    /// The channel's name in words as the title, and the stored properties as fields.
    public func content() throws -> ReportContent {
        let reflected = try ReportProperty.fields(of: self)
        if !reflected.unsupported.isEmpty {
            assertionFailure("FlightData: \(Self.self) has properties a report can’t send: "
                             + "\(reflected.unsupported.joined(separator: ", ")). They were left out.")
        }
        return ReportContent(title: ReportProperty.words(Self.name), fields: reflected.fields,
                             fieldDescriptions: reflected.descriptions)
    }
}
