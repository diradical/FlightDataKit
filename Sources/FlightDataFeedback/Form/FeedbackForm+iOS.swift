// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

#if !os(macOS)
import FlightData
import PhotosUI
import SwiftUI

/// The layout for iPhone, iPad and Apple Vision Pro, in a navigation stack: the headline in the bar with Cancel
/// and Submit Report, and the app's icon, the sections and any problem scrolling together in the form.
extension FeedbackForm {
    func layout(_ app: AppInfo) -> some View {
        NavigationStack {
            Form {
                Section {
                    FeedbackHeader(title: headline, showsTitle: false)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                sections(app)
                if let problem = draft.failure ?? draft.problem {
                    Section {
                        ProblemText(message: problem)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(draft.isSending)
            .navigationTitle(headline)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel, action: cancel)
                        .disabled(draft.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.isSending {
                        ProgressView()
                    } else {
                        submitButton
                            .fontWeight(.semibold)
                            .disabled(!draft.canSubmit)
                    }
                }
            }
            .confirmsDiscard(isPresented: $confirmsDiscard, discard: discard)
        }
        .interactiveDismissDisabled(draft.hasChanges || draft.isSending || draft.isImporting)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) {
            draft.addFiles($0)
        }
        .photosPicker(isPresented: $showsPhotos, selection: $pickedPhotos, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            let first = draft.photoCount + 1
            draft.startImport(photos: true) { budget in
                try await PickedPhotos.files(from: items, first: first, budget: budget)
            }
        }
    }

    /// What is included, with a row at the end to add more: photos or files.
    var attachmentsSection: some View {
        Section {
            attachmentRows
            if draft.isImporting {
                ProgressView(String(localized: "Adding attachments…", bundle: .module))
            } else {
                Menu {
                    Button(String(localized: "Photo Library", bundle: .module), systemImage: "photo.on.rectangle") {
                        showsPhotos = true
                    }
                    Button(String(localized: "Files", bundle: .module), systemImage: "folder") {
                        showsImporter = true
                    }
                } label: {
                    Label(String(localized: "Add Attachments", bundle: .module), systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Included in This Report", bundle: .module)
        }
    }
}

#Preview("iPhone sheet") {
    @Previewable @State var showsFeedback = true
    Button { showsFeedback = true } label: { Text(verbatim: "Send Feedback…") }
        .feedbackSheet(isPresented: $showsFeedback, contact: .required, attachments: [
            FeedbackAttachment(ReportFile(name: "log.txt", contentType: "text/plain", data: Data("log".utf8)),
                               summary: "The app’s log"),
        ])
        .flightDataContainer(.preview(for: Feedback.self))
}
#endif
