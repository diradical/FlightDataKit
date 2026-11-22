// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation

/// Says why feedback can't be sent, or files can't be added, in words for the person and in the app's language.
enum ProblemMessage {
    /// The message for an error thrown while checking, preparing or queuing feedback, or adding attachments.
    ///
    /// A `ReportValidationError` is described from its reason and the field it names, and a `FlightDataError`
    /// from why the container didn't take the report; their English messages are never shown. Any other error,
    /// such as one an app's `prepare` hook throws with words of its own, describes itself.
    static func text(for error: any Error, questions: [ReportField]) -> String {
        switch error {
        case let error as ReportValidationError: text(for: error, questions: questions)
        case let error as FlightDataError: text(for: error)
        default: error.localizedDescription
        }
    }

    /// `title`, `body`, `contact` and `files` are the form's own fields, and any other field is a question, named
    /// by its label.
    private static func text(for error: ReportValidationError, questions: [ReportField]) -> String {
        let question = error.field.flatMap { key in questions.first { $0.key == key } }
        let label = question?.label ?? error.field ?? ""
        switch (error.reason, error.field) {
        case (.required, "title"):
            return String(localized: "Add a title.", bundle: .module)
        case (.required, "body"):
            return String(localized: "Add a description.", bundle: .module)
        case (.required, "contact"):
            return String(localized: "Add an email address so we can reply.", bundle: .module)
        case (.required, _):
            return String(localized: "Answer “\(label)”.", bundle: .module,
                          comment: "A required question is unanswered. The label is the question's.")
        case (.tooLong, "title"):
            return String(localized: """
                Shorten the title to \(ReportLimits.titleLength.formatted()) characters or fewer.
                """, bundle: .module)
        case (.tooLong, "body"):
            return String(localized: """
                Shorten the description to \(ReportLimits.descriptionLength.formatted()) characters or fewer.
                """, bundle: .module)
        case (.tooLong, "contact"):
            return String(localized: """
                Shorten the email address to \(ReportLimits.contactLength.formatted()) characters or fewer.
                """, bundle: .module)
        case (.tooLong, _):
            return String(localized: """
                Shorten “\(label)” to \(ReportLimits.fieldValueLength.formatted()) characters or fewer.
                """, bundle: .module, comment: "The first value is a question's label.")
        case (.limitExceeded, "files"):
            let size = Int64(ReportLimits.attachmentBytes).formatted(.byteCount(style: .file))
            return String(localized: """
                These attachments are too large to send together. A report can include \
                \(ReportLimits.attachmentCount.formatted()) files and \(size) in all.
                """, bundle: .module, comment: "The first value is a number of files, the second a size such as 10 MB.")
        case (.limitExceeded, nil):
            return String(localized: "This report’s text is too long to send. Shorten the description.",
                          bundle: .module)
        case (.invalidValue, _) where question?.kind == .integer:
            return String(localized: "Enter a whole number for “\(label)”.", bundle: .module)
        case (.invalidValue, _) where question?.kind == .number:
            return String(localized: "Enter a number for “\(label)”.", bundle: .module)
        case (.invalidValue, _) where question != nil:
            return String(localized: "Choose an answer for “\(label)” from its list.", bundle: .module)
        case (.unrepresentableNumber, _):
            return String(localized: "“\(label)” is too large a number to send.", bundle: .module)
        case (.duplicate, "files"):
            return String(localized: """
                Two attachments have the same name. Leave one out, or rename it and add it again.
                """, bundle: .module)
        case (.invalidName, "files"):
            return String(localized: "An attachment’s name can’t be used. Rename the file and add it again.",
                          bundle: .module)
        case (.limitExceeded, _), (.invalidValue, _), (.duplicate, _), (.invalidName, _), (.invalidDescription, _):
            // Questions or values the app set up wrongly, which FeedbackForm reports to the developer as it
            // starts in a debug build.
            return String(localized: """
                This app’s feedback form isn’t set up correctly, so the feedback can’t be sent.
                """, bundle: .module)
        }
    }

    /// The container is the stand-in a view gets without one above it, its setup was invalid, or its schema
    /// doesn't list Feedback. Feedback isn't telemetry, so turning telemetry off doesn't stop it.
    private static func text(for error: FlightDataError) -> String {
        switch error {
        case .notConfigured, .unsupportedReportType, .telemetryDisabled:
            String(localized: "This app hasn’t been set up to send feedback.", bundle: .module)
        }
    }
}
