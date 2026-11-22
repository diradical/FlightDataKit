// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import FlightData
@testable import FlightDataFeedback

struct FeedbackFormTests {
    @Test @MainActor func draftQuestionsAreInheritedAndCanBeExplicitlyReplacedOrCleared() {
        let question = ReportField(key: "area", label: "Area", required: true)
        let other = ReportField(key: "action", label: "Action")
        let draft = Feedback(title: "New feedback", questions: [question])
        #expect(FeedbackForm(draft: draft).questions == [question])
        #expect(FeedbackForm(draft: draft, asking: [other]).questions == [other])
        #expect(FeedbackForm(draft: draft, asking: []).questions.isEmpty)
    }

    @Test @MainActor func reviewAndRetryUseTheApprovedReportAndNotifyOnceAfterEnqueue() async throws {
        let submission = FeedbackSubmission()
        let draft = Feedback(title: "Export", body: "An export failed.")
        let log = ReportFile(name: "log.txt", contentType: "text/plain", data: Data("details".utf8))
        let removed = ReportFile(name: "window.png", contentType: "image/png", data: Data())
        var hostValue = "first"
        var preparations = 0
        var queuedIDs: [UUID] = []
        var attempts: [Feedback] = []
        let id = UUID()
        func send(confirming: Bool) async throws -> Bool {
            try await submission.send(confirming: confirming, source: { draft }, excluding: [removed.name],
                                      contact: .none,
                prepare: { report in
                    preparations += 1
                    report.files = [removed, log]
                    report.contact = "test@example.invalid"
                    report.fields["extra"] = ReportValue(hostValue)
                }, queue: { report in
                    attempts.append(report)
                    if attempts.count == 1 { throw CocoaError(.fileWriteOutOfSpace) }
                    return id
                }, onQueued: { queuedIDs.append($0) })
        }

        #expect(try await !send(confirming: false))
        #expect(submission.review?.files == [log])
        #expect(submission.review?.contact == nil)
        #expect(queuedIDs.isEmpty)
        hostValue = "edited outside the Feedback value"
        submission.edit()
        #expect(try await !send(confirming: false))
        #expect(submission.review?.fields["extra"] == ReportValue(hostValue))
        #expect(preparations == 2)
        submission.removeFile(named: log.name)
        hostValue = "changed while retrying"
        await #expect(throws: CocoaError.self) { try await send(confirming: true) }
        #expect(queuedIDs.isEmpty)
        #expect(try await send(confirming: true))
        #expect(try await !send(confirming: true))
        #expect(attempts.count == 2 && attempts[0] == attempts[1])
        #expect(attempts.first?.files == [])
        #expect(preparations == 2 && queuedIDs == [id])
    }

    @Test @MainActor func aFailedEnqueueWithoutChangesRetainsTheSnapshotForAnActualRetry() async throws {
        let submission = FeedbackSubmission()
        let original = Feedback(title: "Title", body: "Original body.")
        await #expect(throws: CocoaError.self) {
            try await submission.send(confirming: false, source: { original }, excluding: [], contact: .optional,
                                      prepare: { _ in }, queue: { _ in throw CocoaError(.fileWriteOutOfSpace) },
                                      onQueued: { _ in Issue.record("The queue failed.") })
        }
        #expect(submission.review == original)
        var calls = 0
        let queued = try await submission.send(
            confirming: true, source: { Issue.record("The draft was read again."); return original },
            excluding: [], contact: .optional, prepare: { _ in Issue.record("Preparation ran again.") },
            queue: { report in #expect(report == original); return UUID() }, onQueued: { _ in calls += 1 })
        #expect(queued && calls == 1)
    }

    @Test func previewsReadTheAttachedImagePDFAndEntireText() async throws {
        let png = try #require(Data(base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQUDAAAACkAGE0Zn1yAAAAAElFTkSuQmCC
            """))
        let image = ReportFile(name: "window.png", contentType: "image/png", data: png)
        guard case .image(let preview) = await AttachmentPreviewContent.load(image) else {
            Issue.record("The attachment did not produce an image preview.")
            return
        }
        #expect(preview.width == 1 && preview.height == 1)
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.insert(PDFPage(), at: 1)
        let pdf = ReportFile(name: "document.pdf", contentType: "application/pdf",
                             data: try #require(document.dataRepresentation()))
        guard case .pdf(let pages) = AttachmentPreviewContent(pdf) else {
            Issue.record("The attachment did not produce a PDF preview.")
            return
        }
        #expect(pages.pageCount == 2)
        let message = String(repeating: "日", count: 12_000) + "end"
        let log = ReportFile(name: "log.txt", contentType: "text/plain", data: Data(message.utf8))
        guard case .text(let text) = AttachmentPreviewContent(log) else {
            Issue.record("The attachment did not produce a text preview.")
            return
        }
        #expect(text == message)
    }

    @Test func importingMultipleFilesSpendsOnlyTheRemainingBudget() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let one = directory.appending(path: "one.txt")
        let two = directory.appending(path: "two.txt")
        try Data("123".utf8).write(to: one)
        try Data("45".utf8).write(to: two)
        let original = ReportFile(name: "existing", contentType: "application/octet-stream",
                                  data: Data(count: ReportLimits.attachmentBytes - 5))
        let budget = try AttachmentImport(including: [original])
        #expect(try await budget.files(at: [one, two]).map(\.data) == [Data("123".utf8), Data("45".utf8)])
        try Data("456".utf8).write(to: two)
        let tooLarge = ReportValidationError(.limitExceeded, "Attachments must total at most 10 MB.", field: "files")
        await #expect(throws: tooLarge) {
            try await budget.files(at: [one, two])
        }
        await #expect(throws: ReportValidationError.self) {
            try await budget.files(at: Array(repeating: directory, count: ReportLimits.attachmentCount))
        }
    }
}
