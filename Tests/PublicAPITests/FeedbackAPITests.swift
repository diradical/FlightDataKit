// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightDataFeedback
import Foundation
import SwiftUI
import Testing

@Test @MainActor func appsCanConfigureFeedbackUsingPublicLabelsAndTrailingClosures() {
    let draft = Feedback(title: "Export", questions: [ReportField(key: "app", label: "App", asked: false)])
    let prepare: @MainActor @Sendable (inout Feedback) async throws -> Void = { $0.fields["app"] = "Editor" }
    let queued: @MainActor @Sendable (UUID) -> Void = { _ in }
    _ = FeedbackForm(draft: draft)
    _ = FeedbackForm(draft: draft, onQueued: queued)
    _ = FeedbackForm(draft: draft, prepare: prepare, onQueued: queued)
    _ = FeedbackForm(draft: draft, extra: { Text("Details") }, prepare: prepare, onQueued: queued)
    _ = Text("Feedback").feedbackSheet(isPresented: .constant(true), draft: draft, prepare: prepare)
    _ = Text("Feedback").feedbackSheet(isPresented: .constant(true), draft: draft) { report in
        report.title = "Prepared"
    } onQueued: { id in queued(id) }
}

@Test @MainActor func theSheetTakesWhatTheFormTakes() {
    let header: LocalizedStringResource = "Report a Problem"
    let prompt: LocalizedStringResource = "What were you doing?"
    _ = FeedbackForm(header: header, descriptionPrompt: prompt)
    _ = FeedbackForm(header: "Report a Problem", descriptionPrompt: "What were you doing?") { Text("Details") }
    _ = Text("Feedback").feedbackSheet(isPresented: .constant(true), header: header, descriptionPrompt: prompt)
    _ = Text("Feedback").feedbackSheet(isPresented: .constant(true), contact: .required, header: "Report a Problem",
                                       descriptionPrompt: "What were you doing?", fixedKeys: ["area"]) {
        Section("Your Project") { Text("Untitled 3") }
    }
    _ = FeedbackAttachment(files: [ReportFile(name: "log.txt", contentType: "text/plain", data: Data())],
                           summary: "The app’s log", required: true)
}

@Test @MainActor func importingFlightDataFeedbackAloneSetsUpTheContainerAndShowsTheForm() {
    // Only FlightDataFeedback is imported here: the container and the report's values come with it.
    let container = FlightDataContainer.preview(for: Feedback.self)
    let file = ReportFile(name: "log.txt", contentType: "text/plain", data: Data())
    let draft = Feedback(title: "Export", fields: ["copies": ReportValue(2)], files: [file])
    _ = FeedbackForm(draft: draft).flightDataContainer(container)
    #expect(ReportLimits.attachmentCount > 0)
}
