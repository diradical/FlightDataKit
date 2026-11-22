// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

#if os(macOS)
import FlightData
import SwiftUI

/// The Mac layout: the header above a grouped form, and a bar below it with any problem, Cancel and Submit Report.
extension FeedbackForm {
    func layout(_ app: AppInfo) -> some View {
        VStack(spacing: 0) {
            FeedbackHeader(title: headline)
                .padding(.horizontal, 24)
                .padding(.top, 18)
            Form {
                sections(app)
            }
            .formStyle(.grouped)
            .environment(\.defaultMinListRowHeight, 24)
            .disabled(draft.isSending)
            HStack {
                if let problem = draft.failure ?? draft.problem {
                    ProblemText(message: problem)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if draft.isSending { ProgressView().controlSize(.small) }
                Button(String(localized: "Cancel", bundle: .module), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.isSending)
                submitButton
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSubmit)
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .modifier(FormSize())
        .confirmsDiscard(isPresented: $confirmsDiscard, discard: discard)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) {
            draft.addFiles($0)
        }
    }

    /// What is included, with the control to add more in the header.
    var attachmentsSection: some View {
        Section {
            attachmentRows
            if draft.isImporting { ProgressView(String(localized: "Adding attachments…", bundle: .module)) }
        } header: {
            HStack {
                Text("Included in This Report", bundle: .module)
                Spacer()
                Button(String(localized: "Add Attachments", bundle: .module), systemImage: "plus.circle") {
                    showsImporter = true
                }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

}

/// Wide enough for the labels and fields side by side, and tall enough to show most sections without scrolling,
/// at the person's text size. A sheet opens at the ideal size; a window can be made larger or smaller, down to
/// the minimum.
private struct FormSize: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var minWidth: CGFloat = 460
    @ScaledMetric(relativeTo: .body) private var idealWidth: CGFloat = 560
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 420
    @ScaledMetric(relativeTo: .body) private var idealHeight: CGFloat = 720

    func body(content: Content) -> some View {
        content.frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: .infinity,
                      minHeight: minHeight, idealHeight: idealHeight, maxHeight: .infinity)
    }
}
#endif
