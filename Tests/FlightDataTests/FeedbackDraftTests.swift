// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback

@MainActor
struct FeedbackDraftTests {
    private let area = ReportField(key: "area", label: "Area", kind: .choice([.init("canvas"), .init("export")]),
                                   required: true)
    private let copies = ReportField(key: "copies", label: "Copies", kind: .integer)
    private let build = ReportField(key: "build", label: "Build", asked: false)
    private let log = ReportFile(name: "log.txt", contentType: "text/plain", data: Data("log".utf8))

    private func makeDraft(contact: Feedback.Contact = .optional) -> FeedbackDraft {
        FeedbackDraft(draft: Feedback(title: "", fields: ["build": "42"]), questions: [area, copies, build],
                      contact: contact, attachments: [FeedbackAttachment(log, summary: "The app’s log")])
    }

    @Test func feedbackIsCompleteOnceEveryRequiredAnswerIsGiven() {
        let draft = makeDraft(contact: .required)
        #expect(!draft.isComplete && !draft.canSubmit)
        draft.feedback.title = "Export fails"
        draft.feedback.body = "  \n"
        draft.entries["area"] = "export"
        draft.feedback.contact = "me@example.test"
        #expect(!draft.isComplete, "A description of only spaces is blank.")
        draft.feedback.body = "The export stops halfway."
        #expect(draft.isComplete && draft.canSubmit)
        draft.feedback.contact = nil
        #expect(!draft.isComplete, "The form asks for contact details it requires.")
        draft.feedback.contact = "me@example.test"
        draft.entries["area"] = nil
        #expect(!draft.isComplete, "A required question needs an answer.")
        draft.entries["area"] = "export"
        #expect(draft.isComplete)
    }

    @Test func aProblemIsReportedOnlyOnceTheFeedbackIsComplete() {
        let draft = makeDraft()
        draft.entries["copies"] = "two"
        #expect(draft.problem == nil, "Nothing is reported while something required is blank.")
        draft.feedback.title = "Export fails"
        draft.feedback.body = "The export stops halfway."
        draft.entries["area"] = "export"
        #expect(draft.problem == "Enter a whole number for “Copies”." && !draft.canSubmit)
        draft.entries["copies"] = "2"
        #expect(draft.problem == nil && draft.canSubmit)
        draft.feedback.title = String(repeating: "a", count: ReportLimits.titleLength + 1)
        #expect(draft.problem == "Shorten the title to \(ReportLimits.titleLength.formatted()) characters or fewer.")
        #expect(!draft.canSubmit)
    }

    @Test func theComposedFeedbackHasTheAnswersTheAppsValuesAndTheIncludedFiles() throws {
        let draft = makeDraft(contact: .none)
        draft.feedback.title = "Export fails"
        draft.feedback.body = "The export stops halfway."
        draft.feedback.contact = "me@example.test"
        draft.entries = ["area": "export", "copies": " 3 "]
        let feedback = try draft.composed()
        #expect(feedback.fields == ["area": "export", "copies": 3, "build": "42"])
        #expect(feedback.files == [log])
        #expect(feedback.contact == nil, "A form that doesn't ask for contact details sends none.")
        #expect(feedback.questions == [area, copies, build])
        draft.remove(draft.attachments[0])
        #expect(try draft.composed().files.isEmpty)
        #expect(draft.excludedFiles == [log.name])
    }

    @Test func changesAreNoticedAndResetPutsTheFormBackAsItStarted() {
        let draft = makeDraft()
        #expect(!draft.hasChanges)
        draft.feedback.title = "Export fails"
        #expect(draft.hasChanges)
        draft.feedback.title = ""
        #expect(!draft.hasChanges)
        draft.entries["copies"] = "2"
        draft.remove(draft.attachments[0])
        draft.failure = "The disk is full."
        draft.discard()
        #expect(draft.hasChanges && draft.isFinished)
        draft.reset()
        #expect(!draft.hasChanges && !draft.isFinished)
        #expect(draft.entries == ["build": "42"] && draft.attachments.map(\.files) == [[log]])
        #expect(draft.excludedFiles.isEmpty && draft.failure == nil)
    }

    @Test func aQueuedReportFinishesTheFormUntilItIsReset() async {
        let draft = makeDraft()
        draft.feedback.title = "Export fails"
        draft.feedback.body = "The export stops halfway."
        draft.entries["area"] = "canvas"
        var queued: [Feedback] = []
        let sent = await draft.send(confirming: false, prepare: nil, queue: { queued.append($0); return UUID() },
                                    onQueued: nil)
        #expect(sent && draft.isFinished && draft.isSending && queued.count == 1)
        #expect(!draft.canSubmit, "A queued form can't send again.")
        draft.reset()
        #expect(!draft.isSending && !draft.isFinished && draft.feedback.title.isEmpty)
    }

    @Test func aFailedQueueKeepsTheFormOpenWithTheReasonAndTheReportToRetry() async {
        let draft = makeDraft()
        draft.feedback.title = "Export fails"
        draft.feedback.body = "The export stops halfway."
        draft.entries["area"] = "canvas"
        let sent = await draft.send(confirming: false, prepare: nil,
                                    queue: { _ in throw CocoaError(.fileWriteOutOfSpace) }, onQueued: nil)
        #expect(!sent && !draft.isFinished && draft.failure != nil)
        #expect(draft.isReviewing && draft.canSubmit)
        draft.editPreparedFeedback()
        #expect(!draft.isReviewing && draft.failure == nil)
    }
}
