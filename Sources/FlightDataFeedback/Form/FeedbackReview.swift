// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI

/// The report a `prepare` hook changed, for the person to confirm: its text and values, and its files, which
/// they can still leave out unless required. Edit Feedback goes back to the form.
struct FeedbackReview: View {
    let feedback: Feedback
    let requiredFiles: Set<String>
    let remove: (String) -> Void
    let edit: () -> Void

    var body: some View {
        Section {
            LabeledContent(String(localized: "Title", bundle: .module), value: feedback.title)
            Text(feedback.body)
            if let contact = feedback.contact {
                LabeledContent(String(localized: "Contact", bundle: .module), value: contact)
            }
            ForEach(feedback.fields.keys.sorted(), id: \.self) { key in
                if let value = feedback.fields[key] {
                    let definition = feedback.fieldDescriptions.first { $0.key == key }
                    LabeledContent(definition?.label ?? key) {
                        Text(definition?.option.map {
                            String(localized: "\($0) (\(value.description))", bundle: .module,
                                   comment: "A value and, in brackets, more about it, such as a version and its build.")
                        } ?? value.description)
                    }
                }
            }
        } header: {
            Text("Review Final Report", bundle: .module)
        } footer: {
            Text("Review the report before confirming submission.", bundle: .module)
        }
        if !feedback.files.isEmpty {
            Section(String(localized: "Included in This Report", bundle: .module)) {
                ForEach(feedback.files.indices, id: \.self) { index in
                    let file = feedback.files[index]
                    let attachment = FeedbackAttachment(file, required: requiredFiles.contains(file.name))
                    FeedbackAttachmentRow(attachment: attachment) { remove(file.name) }
                }
            }
        }
        Section {
            Button(String(localized: "Edit Feedback", bundle: .module), action: edit)
        }
    }
}
