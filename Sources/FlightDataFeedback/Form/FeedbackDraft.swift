// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation
import Observation

/// What the person has typed, chosen and included in the feedback form, and what follows from it: the feedback
/// as it stands, whether it is complete and why it can't be sent. The form owns one and binds its controls to it.
///
/// `problem` is worked out again only when something it depends on changes, so the form can read it as often as
/// it renders.
@MainActor @Observable
final class FeedbackDraft {
    /// The form's questions, including values the app sets and the person doesn't answer.
    let questions: [ReportField]
    let contactRequirement: Feedback.Contact
    /// The report awaiting confirmation or a retry.
    let submission: FeedbackSubmission

    /// The title, description and contact details as typed, with the values the app set. Its files are always
    /// empty; the files are in `attachments`.
    var feedback: Feedback { didSet { revalidate() } }
    /// What is typed or chosen for each question the form asks, by key. It becomes a value in `composed()`.
    var entries: [String: String] { didSet { revalidate() } }
    /// The rows under Included in This Report.
    var attachments: [FeedbackAttachment] { didSet { revalidate() } }
    /// Why the last submission or import failed, for the person to read.
    var failure: String?

    /// Why finished feedback can't be sent as it stands; nil while something required is still blank.
    private(set) var problem: String?
    /// Names of files the person left out. A `prepare` hook that adds one of them again doesn't bring it back.
    private(set) var excludedFiles: Set<String> = []
    /// How many photos the person has added, so the next one is numbered after them.
    private(set) var photoCount = 0
    /// True once the feedback was queued or discarded, until `reset()` puts the form back as it started.
    private(set) var isFinished = false
    private(set) var importTask: Task<Void, Never>?

    @ObservationIgnored private let start: (feedback: Feedback, entries: [String: String],
                                            attachments: [FeedbackAttachment])

    /// - Parameters:
    ///   - draft: What the form starts with. Its files become attachment rows.
    ///   - questions: The questions the form asks and the values the app sets.
    ///   - contact: Whether the form asks how to reach the person.
    ///   - attachments: Files the app offers, after the draft's own.
    init(draft: Feedback, questions: [ReportField], contact: Feedback.Contact, attachments: [FeedbackAttachment],
         submission: FeedbackSubmission = FeedbackSubmission()) {
        var initial = draft
        initial.files = []
        initial.questions = questions
        start = (initial, draft.fields.mapValues(\.description),
                 draft.files.map { FeedbackAttachment($0) } + attachments)
        self.questions = questions
        self.contactRequirement = contact
        self.submission = submission
        feedback = start.feedback
        entries = start.entries
        self.attachments = start.attachments
        revalidate()
    }

    /// Stops a debug build when the questions can't make a valid report, such as a key used twice or a choice
    /// question without choices. Otherwise the person would find out only after answering every question, from
    /// a problem they can't fix.
    nonisolated static func assertValid(questions: [ReportField]) {
        #if DEBUG
        do {
            try ReportField.validate(questions)
        } catch {
            assertionFailure("FlightDataFeedback: the feedback form's questions aren't valid. \(error)")
        }
        #endif
    }

    var isSending: Bool { submission.busy }
    var isReviewing: Bool { submission.review != nil }
    var isImporting: Bool { importTask != nil }

    /// The feedback as it stands: the draft, what was entered for the questions the form asks, and the files of
    /// every row still included. Throws when an entry isn't of its question's kind.
    func composed() throws -> Feedback {
        var composed = feedback
        if contactRequirement == .none { composed.contact = nil }
        for question in questions where question.asked {
            composed.fields[question.key] = try question.value(from: entries[question.key] ?? "")
        }
        composed.files = attachments.flatMap(\.files)
        return composed
    }

    /// Whether the person has given everything the form marks as required.
    var isComplete: Bool {
        !Self.isBlank(feedback.title) && !Self.isBlank(feedback.body)
            && (contactRequirement != .required || !Self.isBlank(feedback.contact ?? ""))
            && questions.filter { $0.asked && $0.required }.allSatisfy { !Self.isBlank(entries[$0.key] ?? "") }
    }

    /// Whether Submit Report, or Confirm Submission while reviewing, can be pressed.
    var canSubmit: Bool {
        (isReviewing || isComplete) && problem == nil && !isSending && !isImporting
    }

    /// Whether the person has typed or chosen anything, or changed what is included, since the form started.
    var hasChanges: Bool {
        isReviewing || feedback.title != start.feedback.title || feedback.body != start.feedback.body
            || feedback.contact != start.feedback.contact || entries != start.entries
            || attachments.map(\.id) != start.attachments.map(\.id)
    }

    /// Puts the form back as it started.
    func reset() {
        importTask?.cancel()
        importTask = nil
        feedback = start.feedback
        entries = start.entries
        attachments = start.attachments
        excludedFiles = []
        photoCount = 0
        failure = nil
        isFinished = false
        submission.reset()
        revalidate()
    }

    /// Ends the form without sending anything. `reset()` then puts it back as it started.
    func discard() {
        importTask?.cancel()
        isFinished = true
    }

    /// Prepares and queues the feedback, or shows what `prepare` changed for the person to confirm first.
    /// Returns true once the report is queued and the form can close; on failure, `failure` says why.
    func send(confirming: Bool, prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)?,
              queue: (Feedback) async throws -> UUID, onQueued: (@MainActor @Sendable (UUID) -> Void)?) async -> Bool {
        guard canSubmit, isReviewing == confirming else { return false }
        failure = nil
        defer { revalidate() }
        do {
            let queued = try await submission.send(confirming: confirming, source: composed, excluding: excludedFiles,
                                                   contact: contactRequirement, prepare: prepare, queue: queue,
                                                   onQueued: onQueued)
            if queued { isFinished = true }
            return queued
        } catch {
            failure = message(for: error)
            return false
        }
    }

    /// Leaves out one row and its files.
    func remove(_ attachment: FeedbackAttachment) {
        excludedFiles.formUnion(attachment.files.map(\.name))
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Leaves a file out of the report being reviewed.
    func removeReviewedFile(named name: String) {
        excludedFiles.insert(name)
        submission.removeFile(named: name)
        failure = nil
        revalidate()
    }

    /// Goes back from reviewing to editing, without the files the person left out while reviewing.
    func editPreparedFeedback() {
        attachments = attachments.compactMap { attachment in
            let files = attachment.files.filter { !excludedFiles.contains($0.name) }
            guard files.count != attachment.files.count else { return attachment }
            return files.isEmpty ? nil : FeedbackAttachment(files: files, summary: attachment.summary,
                                                            required: attachment.required)
        }
        submission.edit()
        failure = nil
        revalidate()
    }

    /// Reads the files the person chose in a file importer and adds them.
    func addFiles(_ result: Result<[URL], any Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            startImport { try await $0.files(at: urls) }
        } catch {
            failure = message(for: error)
        }
    }

    /// Reads new files in a task, within what earlier attachments leave of a report's budget, and adds them as
    /// rows. `photos` counts them toward the photos' numbering.
    func startImport(photos: Bool = false,
                     read: @escaping @Sendable (AttachmentImport) async throws -> [ReportFile]) {
        guard !isImporting, !isSending, !isReviewing else { return }
        failure = nil
        importTask = Task {
            defer { importTask = nil }
            do {
                let existing = attachments.flatMap(\.files)
                let files = try await read(AttachmentImport(including: existing))
                try Task.checkCancellation()
                try ReportContent(title: "Attachments", files: existing + files).validate()
                let summary = String(localized: "Added by you", bundle: .module,
                                     comment: "Describes a file the person attached themselves.")
                attachments += files.map { FeedbackAttachment($0, summary: summary) }
                excludedFiles.subtract(files.map(\.name))
                if photos { photoCount += files.count }
            } catch {
                if !Task.isCancelled { failure = message(for: error) }
            }
        }
    }

    /// Works out `problem` again: the reviewed report's, or the composed feedback's once it is complete.
    private func revalidate() {
        let problem: String?
        do {
            if let review = submission.review {
                try review.validate(contact: contactRequirement)
            } else if isComplete {
                try composed().validate(contact: contactRequirement)
            }
            problem = nil
        } catch {
            problem = message(for: error)
        }
        // Assigning an equal value would still notify the views that read it.
        if problem != self.problem { self.problem = problem }
    }

    private func message(for error: any Error) -> String {
        ProblemMessage.text(for: error, questions: questions)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
