// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI

/// One of the app's questions in Basic Information: a text field or a pop-up under the question's label, with a
/// red asterisk when it is required.
struct FeedbackFieldControl: View {
    let field: ReportField
    let fixed: Bool
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            control.disabled(fixed)
            if let help = field.help {
                Text(help).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var label: Text { .required(Text(field.label), field.required) }
    private var spokenLabel: Text { .spoken(Text(field.label), required: field.required) }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .text, .integer, .number:
            LabeledContent {
                TextField(field.label, text: $value)
                    .labelsHidden()
                    .accessibilityLabel(spokenLabel)
                    #if !os(macOS)
                    // Number pads have no minus sign, and these numbers can be negative.
                    .keyboardType(field.kind == .text ? .default : .numbersAndPunctuation)
                    #endif
            } label: {
                label
            }
        case .choice(let options):
            Picker(selection: $value) {
                Text("Choose…", bundle: .module).tag("")
                ForEach(options) { option in Text(option.label).tag(option.value) }
            } label: {
                label
            }
            .accessibilityLabel(spokenLabel)
        case .boolean:
            Picker(selection: $value) {
                Text("Choose…", bundle: .module).tag("")
                Text("Yes", bundle: .module).tag("true")
                Text("No", bundle: .module).tag("false")
            } label: {
                label
            }
            .accessibilityLabel(spokenLabel)
        }
    }
}
