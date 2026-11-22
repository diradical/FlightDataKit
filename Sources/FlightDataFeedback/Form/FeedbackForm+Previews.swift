// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI

/// What the previews below show: an app's questions and files, and a container that never sends anything.
@MainActor
private enum PreviewContent {
    static let questions = [
        ReportField(key: "area", label: "Area", kind: .choice([.init("editor", label: "Editor"),
                                                                .init("export", label: "Export")]),
                    required: true),
        ReportField(key: "copies", label: "Copies", kind: .integer, help: "How many copies you were exporting."),
        ReportField(key: "build", label: "Build", asked: false),
    ]
    static let log = FeedbackAttachment(ReportFile(name: "log.txt", contentType: "text/plain",
                                                   data: Data("Export started.\nExport stopped.".utf8)),
                                        summary: "The app’s log", required: true)
    static let document = FeedbackAttachment(ReportFile(name: "Résumé.pdf", contentType: "application/pdf",
                                                          data: Data()),
                                               summary: "The document you were working on")
    static let container = FlightDataContainer.preview(for: Feedback.self)

    static func form(_ model: FeedbackDraft) -> some View {
        FeedbackForm(model: model, header: nil, descriptionPrompt: nil, fixedKeys: [], extra: EmptyView(),
                     prepare: nil, onQueued: nil)
    }
}

#Preview("Feedback form") {
    FeedbackForm(draft: Feedback(title: "Export fails", fields: ["build": "1042"]),
                 asking: PreviewContent.questions,
                 attachments: [PreviewContent.log, PreviewContent.document])
        .flightDataContainer(PreviewContent.container)
}

#Preview("Reviewing a prepared report") {
    let review = Feedback(title: "Export fails", body: "The export stops halfway through the second page.",
                          fields: ["area": "export", "build": "1042"], files: PreviewContent.log.files,
                          questions: PreviewContent.questions)
    PreviewContent.form(FeedbackDraft(draft: review, questions: PreviewContent.questions, contact: .optional,
                                      attachments: [PreviewContent.log],
                                      submission: FeedbackSubmission(review: review)))
        .flightDataContainer(PreviewContent.container)
}

#Preview("A problem to fix") {
    // A whole number is what Copies asks for.
    let draft = Feedback(title: "Export fails", body: "The export stops halfway.",
                         fields: ["area": "export", "copies": "two"])
    PreviewContent.form(FeedbackDraft(draft: draft, questions: PreviewContent.questions, contact: .optional,
                                      attachments: []))
        .flightDataContainer(PreviewContent.container)
}

#Preview("Feedback isn’t set up") {
    FeedbackForm()
}

#Preview("Attachment rows") {
    Form {
        Section {
            FeedbackAttachmentRow(attachment: PreviewContent.log) {}
            FeedbackAttachmentRow(attachment: PreviewContent.document) {}
        }
    }
    .formStyle(.grouped)
}
