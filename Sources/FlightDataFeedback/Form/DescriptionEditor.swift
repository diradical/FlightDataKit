// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import SwiftUI

/// The description: a text editor in a rounded field, with the prompt drawn where the text starts while it is
/// empty. VoiceOver hears the prompt as the editor's hint.
struct DescriptionEditor: View {
    @Binding var text: String
    let prompt: Text
    /// About three lines of body text, at the person's text size.
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 60

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: minHeight)
            .accessibilityLabel(Text.spoken(Text("Description", bundle: .module), required: true))
            .accessibilityHint(prompt)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    prompt
                        .foregroundStyle(.tertiary)
                        .padding(Self.textInsets)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(4)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    /// Where the editor's text view starts its first line: AppKit's text view has a 5-point line fragment
    /// padding and no inset; UIKit's adds an 8-point inset above. They are fixed, whatever the text size.
    private static var textInsets: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 1, leading: 5, bottom: 0, trailing: 5)
        #else
        EdgeInsets(top: 8, leading: 5, bottom: 0, trailing: 5)
        #endif
    }
}
