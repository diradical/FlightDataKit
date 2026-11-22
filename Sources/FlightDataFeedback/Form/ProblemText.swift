// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import SwiftUI

/// A line that reports a problem: red, or, with Differentiate Without Color on, in the ordinary color behind a
/// warning sign.
struct ProblemText: View {
    let message: String
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        if withoutColor {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // The text beside it already says what is wrong.
                Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                Text(message)
            }
        } else {
            Text(message).foregroundStyle(.red)
        }
    }
}

extension Text {
    /// `label` followed by a red asterisk, for what the form needs before it can be sent. VoiceOver reads it as
    /// the label and "required" instead of the asterisk.
    static func required(_ label: Text, _ isRequired: Bool = true) -> Text {
        guard isRequired else { return label }
        let asterisk = Text(verbatim: "*").foregroundStyle(.red)
        return Text("\(label) \(asterisk)", bundle: .module,
                    comment: "A label and the asterisk that marks it required.")
            .accessibilityLabel(spoken(label, required: true))
    }

    /// What VoiceOver says for a control's label: the label, and that the control is required when it is.
    static func spoken(_ label: Text, required: Bool) -> Text {
        required ? Text("\(label), required", bundle: .module, comment: "How VoiceOver names a required field.") : label
    }
}
