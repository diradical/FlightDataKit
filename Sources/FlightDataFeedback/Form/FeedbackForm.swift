// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI
#if !os(macOS)
import PhotosUI
#endif

/// The form a person fills in to send feedback. Under the app's icon and name: a title, the app's own questions
/// and an email address if the app asks for one; the details of the app and the device; a description; and the
/// files included with it. Submit Report submits this feedback to the environment's container. When a submission
/// hook changes the report, the person reviews those changes and confirms the final contents first. Where what
/// presents it keeps it after it closes, as a window does, it is back as it started the next time it is shown.
///
/// `feedbackSheet(isPresented:)` presents it as a sheet. Use the form itself to place it elsewhere, such as in a
/// window of its own.
///
/// The form reads `draft`, `questions`, `contact` and `attachments` when it is first shown, and keeps what the
/// person types from then on: making it again with other values doesn't change what it shows. To start over,
/// give it a new identity with `id(_:)`:
///
/// ```swift
/// FeedbackForm(draft: Feedback(title: "", fields: ["document": .text(document.name)]))
///     .id(document.id)
/// ```
///
/// The kit's own text is localized. Give `header` and `descriptionPrompt` from your app's string catalog.
public struct FeedbackForm<Extra: View>: View {
    let header: LocalizedStringResource?
    let descriptionPrompt: LocalizedStringResource?
    let fixedKeys: Set<String>
    let extra: Extra
    let prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)?
    let onQueued: (@MainActor @Sendable (UUID) -> Void)?
    @Environment(\.flightDataContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @State var draft: FeedbackDraft
    @State var showsImporter = false
    @State var confirmsDiscard = false
    #if !os(macOS)
    @State var showsPhotos = false
    @State var pickedPhotos: [PhotosPickerItem] = []
    #endif

    /// - Parameters:
    ///   - draft: What the form starts with. Its files become rows the person can leave out.
    ///   - questions: Overrides the draft’s questions when supplied. An empty array clears them.
    ///   - contact: Whether the form asks how to reach the person.
    ///   - header: The line at the top of the form. Unless you give one, "Provide Feedback to" and the app's name.
    ///   - descriptionPrompt: What the empty description says. Unless you give one, it asks what the person
    ///     expected and what happened instead.
    ///   - fixedKeys: Keys of questions the person sees but can't change.
    ///   - attachments: Files the app offers. The person can look at each and leave out any that isn't required.
    ///   - extra: Sections of your own, placed above what is included.
    ///   - prepare: Prepare the feedback before submission. Changes are shown for confirmation. Throw to keep the
    ///     form open with an error. Returning to edit runs preparation again on the next submission.
    ///   - onQueued: Called once with the UUID after the report is queued locally. A preview simulates success.
    public init(
        draft: Feedback = Feedback(),
        asking questions: [ReportField]? = nil,
        contact: Feedback.Contact = .optional,
        header: LocalizedStringResource? = nil,
        descriptionPrompt: LocalizedStringResource? = nil,
        fixedKeys: Set<String> = [],
        attachments: [FeedbackAttachment] = [],
        @ViewBuilder extra: () -> Extra,
        prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)? = nil,
        onQueued: (@MainActor @Sendable (UUID) -> Void)? = nil
    ) {
        let questions = questions ?? draft.questions
        FeedbackDraft.assertValid(questions: questions)
        self.init(model: FeedbackDraft(draft: draft, questions: questions, contact: contact, attachments: attachments),
                  header: header, descriptionPrompt: descriptionPrompt, fixedKeys: fixedKeys, extra: extra(),
                  prepare: prepare, onQueued: onQueued)
    }

    /// The form around a draft made elsewhere, as for a preview of the review.
    init(model: FeedbackDraft, header: LocalizedStringResource?, descriptionPrompt: LocalizedStringResource?,
         fixedKeys: Set<String>, extra: Extra,
         prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)?,
         onQueued: (@MainActor @Sendable (UUID) -> Void)?) {
        self.header = header
        self.descriptionPrompt = descriptionPrompt
        self.fixedKeys = fixedKeys
        self.extra = extra
        self.prepare = prepare
        self.onQueued = onQueued
        _draft = State(initialValue: model)
    }

    /// The questions the form asks and the values the app sets.
    var questions: [ReportField] { draft.questions }

    /// The form, or a note that the app isn't set up to send feedback when no container above it lists
    /// ``Feedback`` in its schema.
    public var body: some View {
        if container.schema.types.contains(where: { $0 == Feedback.self }) {
            layout(container.app)
                .onDisappear(perform: closed)
        } else {
            ContentUnavailableView {
                Label(String(localized: "Feedback Isn’t Set Up", bundle: .module),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text("This app hasn’t been set up to send feedback.", bundle: .module)
            } actions: {
                Button(String(localized: "Close", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
    }

    /// The line at the top of the form: the app's own, or "Provide Feedback to" and the app's name.
    var headline: Text {
        header.map { Text($0) } ?? Text("Provide Feedback to \(AppIdentity.name)", bundle: .module)
    }

    /// What the empty description says: the app's own, or a question about what went wrong.
    var prompt: Text {
        descriptionPrompt.map { Text($0) }
            ?? Text("What did you expect, and what happened instead?", bundle: .module)
    }

    var submitButton: some View {
        let confirming = draft.isReviewing
        return Button {
            Task { await send(confirming: confirming) }
        } label: {
            confirming ? Text("Confirm Submission", bundle: .module) : Text("Submit Report", bundle: .module)
        }
    }

    /// Closes the form, first asking whether to discard what the person typed.
    func cancel() {
        if draft.hasChanges { confirmsDiscard = true } else { discard() }
    }

    func discard() {
        draft.discard()
        finish()
    }

    private func send(confirming: Bool) async {
        let queued = await draft.send(confirming: confirming, prepare: prepare,
                                      queue: { try await container.submit($0) }, onQueued: onQueued)
        if queued { finish() }
    }

    /// Dismisses the form once it has sent or discarded its feedback. A presented form is put back as it started
    /// when it has left the screen, in `closed()`, so it doesn't change while it animates away. One shown in place
    /// has nothing to dismiss and is put back at once.
    private func finish() {
        dismiss()
        if !isPresented { draft.reset() }
    }

    /// A window keeps its form after it closes, so a form that sent or discarded its feedback is put back as it
    /// started; one closed some other way keeps what the person typed. An import in progress stops either way.
    private func closed() {
        if draft.isFinished { draft.reset() } else { draft.importTask?.cancel() }
    }
}

extension FeedbackForm where Extra == EmptyView {
    /// The form with no sections of your own.
    ///
    /// - Parameters:
    ///   - draft: What the form starts with. Its files become rows the person can leave out.
    ///   - questions: Overrides the draft’s questions when supplied. An empty array clears them.
    ///   - contact: Whether the form asks how to reach the person.
    ///   - header: The line at the top of the form. Unless you give one, "Provide Feedback to" and the app's name.
    ///   - descriptionPrompt: What the empty description says. Unless you give one, it asks what the person
    ///     expected and what happened instead.
    ///   - fixedKeys: Keys of questions the person sees but can't change.
    ///   - attachments: Files the app offers. The person can look at each and leave out any that isn't required.
    ///   - prepare: Prepare the feedback before submission. Changes are shown for confirmation. Throw to keep the
    ///     form open with an error. Returning to edit runs preparation again on the next submission.
    ///   - onQueued: Called once with the UUID after the report is queued locally. A preview simulates success.
    public init(
        draft: Feedback = Feedback(),
        asking questions: [ReportField]? = nil,
        contact: Feedback.Contact = .optional,
        header: LocalizedStringResource? = nil,
        descriptionPrompt: LocalizedStringResource? = nil,
        fixedKeys: Set<String> = [],
        attachments: [FeedbackAttachment] = [],
        prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)? = nil,
        onQueued: (@MainActor @Sendable (UUID) -> Void)? = nil
    ) {
        self.init(draft: draft, asking: questions, contact: contact, header: header,
                  descriptionPrompt: descriptionPrompt, fixedKeys: fixedKeys, attachments: attachments,
                  extra: { EmptyView() }, prepare: prepare, onQueued: onQueued)
    }
}
