// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import SwiftUI

/// The top of the form: the app's icon, what the form is, and that nothing is sent until Submit Report.
struct FeedbackHeader: View {
    let title: Text
    /// Whether the title is part of the header; where the bar above shows it, it isn't.
    var showsTitle = true
    /// The size of the icon, which grows with the person's text size.
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 64

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let icon = AppIdentity.icon {
                icon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(.rect(cornerRadius: iconCornerRadius, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if showsTitle {
                    title
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Text("Tell us what went wrong or what would help. Nothing is sent until you press Submit Report.",
                     bundle: .module)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// A Mac icon draws its own shape; an iPhone's is a square the system rounds, by about a fifth of its size.
    private var iconCornerRadius: CGFloat {
        #if os(macOS)
        0
        #else
        iconSize * 0.22
        #endif
    }
}
