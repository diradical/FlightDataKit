// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback

struct ProblemMessageTests {
    private let questions = [
        ReportField(key: "area", label: "Area", kind: .choice([.init("canvas")]), required: true),
        ReportField(key: "copies", label: "Copies", kind: .integer),
        ReportField(key: "zoom", label: "Zoom", kind: .number),
    ]

    private func text(_ reason: ReportValidationError.Reason, field: String?) -> String {
        ProblemMessage.text(for: ReportValidationError(reason, "English message", field: field), questions: questions)
    }

    @Test func theFormsOwnFieldsAreNamedInFullSentences() {
        #expect(text(.required, field: "title") == "Add a title.")
        #expect(text(.required, field: "body") == "Add a description.")
        #expect(text(.required, field: "contact") == "Add an email address so we can reply.")
        #expect(text(.tooLong, field: "title")
                == "Shorten the title to \(ReportLimits.titleLength.formatted()) characters or fewer.")
        #expect(text(.limitExceeded, field: nil)
                == "This report’s text is too long to send. Shorten the description.")
        #expect(text(.limitExceeded, field: "files").contains("\(ReportLimits.attachmentCount.formatted()) files"))
        #expect(text(.duplicate, field: "files").hasPrefix("Two attachments have the same name."))
    }

    @Test func aQuestionIsNamedByItsLabelAndItsKindSaysWhatItNeeds() {
        #expect(text(.required, field: "area") == "Answer “Area”.")
        #expect(text(.invalidValue, field: "copies") == "Enter a whole number for “Copies”.")
        #expect(text(.invalidValue, field: "zoom") == "Enter a number for “Zoom”.")
        #expect(text(.invalidValue, field: "area") == "Choose an answer for “Area” from its list.")
        #expect(text(.unrepresentableNumber, field: "copies") == "“Copies” is too large a number to send.")
        #expect(text(.required, field: "undeclared") == "Answer “undeclared”.")
    }

    @Test func mistakesInTheAppsSetupAndOtherErrorsAreDescribedAsTheyCome() {
        let setup = "This app’s feedback form isn’t set up correctly, so the feedback can’t be sent."
        #expect(text(.duplicate, field: "area") == setup)
        #expect(text(.invalidDescription, field: nil) == setup)
        let notSetUp = "This app hasn’t been set up to send feedback."
        #expect(ProblemMessage.text(for: FlightDataError.notConfigured, questions: questions) == notSetUp)
        #expect(ProblemMessage.text(for: FlightDataError.unsupportedReportType("Feedback"), questions: questions)
                == notSetUp)
        let error = CocoaError(.fileReadNoPermission)
        #expect(ProblemMessage.text(for: error, questions: questions) == error.localizedDescription)
    }
}
