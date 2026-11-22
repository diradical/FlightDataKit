// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Why a report can't be sent as it is, in words for the person writing it.
///
/// Switch on ``reason`` and ``field`` to handle a failure, or to show text of your own; the ``message`` is English
/// and may change.
public struct ReportValidationError: LocalizedError, Equatable, Sendable {
    /// What kind of problem it is. This is the stable part of the error.
    ///
    /// More reasons may come in later versions, so a `switch` over them needs a `default` case.
    public enum Reason: String, Sendable {
        /// Something that has to be there is empty: the title, the app version, an answer that is required.
        case required
        /// A text is longer than its limit.
        case tooLong
        /// There are too many of something, or together they are too large: fields, files, the whole text.
        case limitExceeded
        /// A value isn't one the field or the format takes.
        case invalidValue
        /// A name isn't one the format takes: a file's name, a field's key, a channel.
        case invalidName
        /// The same name is used twice.
        case duplicate
        /// A whole number doesn't fit 64 bits.
        case unrepresentableNumber
        /// What the app says of its fields is invalid: a label is too long, or a description names no field.
        case invalidDescription
    }

    /// What kind of problem it is.
    public let reason: Reason
    /// The field's key, or the name of the part of the report (`title`, `body`, `files`…), when one caused it.
    public let field: String?
    /// What is wrong, in English.
    public let message: String
    public var errorDescription: String? { message }

    package init(_ reason: Reason, _ message: String, field: String? = nil) {
        self.reason = reason
        self.field = field
        self.message = message
    }
}
