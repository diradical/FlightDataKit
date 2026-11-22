// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI

/// The sections both layouts share.
extension FeedbackForm {
    /// The report under review, or the sections the person fills in: the basic information, the details, the
    /// description, the app's own sections and what is included.
    @ViewBuilder
    func sections(_ app: AppInfo) -> some View {
        if let review = draft.submission.review {
            FeedbackReview(feedback: review,
                           requiredFiles: Set(draft.attachments.filter(\.required).flatMap(\.files).map(\.name)),
                           remove: draft.removeReviewedFile, edit: draft.editPreparedFeedback)
        } else {
            basicInformation
            Section {
                ForEach(details(app), id: \.label) { row in
                    LabeledContent(row.label) { Text(row.value).textSelection(.enabled) }
                }
            } header: {
                Text("Details", bundle: .module)
            }
            descriptionSection
            extra
            attachmentsSection
                .disabled(draft.isImporting)
        }
    }

    private var basicInformation: some View {
        Section {
            LabeledContent {
                TextField(String(localized: "Title", bundle: .module), text: $draft.feedback.title)
                    .labelsHidden()
                    .accessibilityLabel(Text.spoken(Text("Title", bundle: .module), required: true))
            } label: {
                Text.required(Text("Title", bundle: .module))
            }
            ForEach(questions.filter(\.asked)) { question in
                FeedbackFieldControl(field: question, fixed: fixedKeys.contains(question.key),
                                     value: entry(for: question))
            }
            if draft.contactRequirement != .none {
                LabeledContent {
                    TextField(String(localized: "Email", bundle: .module), text: contact, prompt: contactPrompt)
                        .labelsHidden()
                        .accessibilityLabel(Text.spoken(Text("Email", bundle: .module),
                                                        required: draft.contactRequirement == .required))
                        .textContentType(.emailAddress)
                        #if !os(macOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                } label: {
                    Text.required(Text("Email", bundle: .module), draft.contactRequirement == .required)
                }
            }
        } header: {
            Text("Basic Information", bundle: .module)
        }
    }

    private var descriptionSection: some View {
        Section {
            DescriptionEditor(text: $draft.feedback.body, prompt: prompt)
        } header: {
            Text.required(Text("Description", bundle: .module))
        }
    }

    /// The rows under Included in This Report, each with a button to leave it out unless it is required.
    var attachmentRows: some View {
        ForEach(draft.attachments) { attachment in
            FeedbackAttachmentRow(attachment: attachment) { draft.remove(attachment) }
        }
    }

    /// The Details section: what the report says about the app and the device, as the container describes them,
    /// then the values the app set itself, under their labels where a question gives one and by key where none does.
    private func details(_ app: AppInfo) -> [(label: String, value: String)] {
        let version = app.build.map {
            String(localized: "\(app.version) (\($0))", bundle: .module,
                   comment: "A value and, in brackets, more about it, such as a version and its build.")
        }
        var rows = [(label: AppIdentity.name, value: version ?? app.version)]
        if let system = app.osVersion {
            rows.append((label: app.platform ?? String(localized: "System", bundle: .module), value: system))
        }
        if let model = app.deviceModel {
            let label = app.platform == "macOS" ? String(localized: "Mac", bundle: .module)
                : String(localized: "Device", bundle: .module)
            rows.append((label: label, value: model))
        }
        if let locale = app.locale {
            rows.append((label: String(localized: "Language", bundle: .module), value: locale))
        }
        let fields = draft.feedback.fields
        let options = Dictionary(draft.feedback.fieldDescriptions.map { ($0.key, $0.option) },
                                 uniquingKeysWith: { first, _ in first })
        for question in questions where !question.asked {
            guard let value = fields[question.key] else { continue }
            rows.append((label: question.label, value: (options[question.key] ?? nil) ?? value.description))
        }
        let known = Set(questions.map(\.key))
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
            rows.append((label: key, value: value.description))
        }
        return rows
    }

    private var contactPrompt: Text {
        draft.contactRequirement == .required ? Text("So we can reply", bundle: .module)
            : Text("Optional, if you’d like a reply", bundle: .module)
    }

    private var contact: Binding<String> {
        Binding(get: { draft.feedback.contact ?? "" }, set: { draft.feedback.contact = $0.isEmpty ? nil : $0 })
    }

    private func entry(for question: ReportField) -> Binding<String> {
        Binding(get: { draft.entries[question.key] ?? "" },
                set: { draft.entries[question.key] = $0.isEmpty ? nil : $0 })
    }
}
