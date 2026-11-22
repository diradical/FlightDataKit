// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import SwiftUI

extension View {
    /// Asks whether to throw away feedback the person has written, when they cancel it. Keep Editing is the
    /// cancel action, so Esc keeps the form open.
    func confirmsDiscard(isPresented: Binding<Bool>, discard: @escaping () -> Void) -> some View {
        confirmationDialog(Text("Discard this feedback?", bundle: .module), isPresented: isPresented,
                           titleVisibility: .visible) {
            Button(String(localized: "Discard Feedback", bundle: .module), role: .destructive, action: discard)
            Button(String(localized: "Keep Editing", bundle: .module), role: .cancel) {}
        } message: {
            Text("What you’ve written and attached won’t be sent.", bundle: .module)
        }
    }
}
