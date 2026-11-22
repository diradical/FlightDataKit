// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI

/// One row under Included in This Report: an icon for the kind of file, its name and what it is, a magnifier
/// that shows what is sent, and a lock when it is required or a trash button that leaves it out.
struct FeedbackAttachmentRow: View {
    let attachment: FeedbackAttachment
    let remove: () -> Void
    @State private var showsPreview = false
    @State private var selectedFile = 0
    /// The width of the file's icon, which grows with the person's text size.
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(names).fontWeight(.medium)
                    if !attachment.summary.isEmpty {
                        Text(attachment.summary).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                let preview = String(localized: "Preview \(names)", bundle: .module,
                                     comment: "A button that shows what is sent of the named files.")
                Button(preview, systemImage: "magnifyingglass") { showsPreview.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(preview)
                    .touchTarget()
                if attachment.required {
                    Label(String(localized: "Required", bundle: .module), systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(String(localized: "This report always includes this file", bundle: .module))
                } else {
                    let remove = String(localized: "Remove \(names)", bundle: .module,
                                        comment: "A button that leaves the named files out of the report.")
                    Button(remove, systemImage: "trash", action: self.remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(remove)
                        .touchTarget()
                }
            }
        }
        .sheet(isPresented: $showsPreview) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if attachment.files.indices.contains(selectedFile) {
                        Text(attachment.files[selectedFile].name).font(.headline)
                    }
                    Spacer()
                    Button(String(localized: "Done", bundle: .module)) { showsPreview = false }
                        .keyboardShortcut(.defaultAction)
                }
                if attachment.files.count > 1 {
                    Picker(String(localized: "File", bundle: .module), selection: $selectedFile) {
                        ForEach(attachment.files.indices, id: \.self) { index in
                            Text(attachment.files[index].name).tag(index)
                        }
                    }
                }
                if attachment.files.indices.contains(selectedFile) {
                    AttachmentPreview(file: attachment.files[selectedFile])
                        .id(selectedFile)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            #if os(macOS)
            .frame(minWidth: 450, idealWidth: 640, minHeight: 340, idealHeight: 500)
            #endif
        }
    }

    /// The names of the row's files, in a list as the person's language writes one.
    private var names: String {
        attachment.files.map(\.name).formatted(.list(type: .and, width: .narrow))
    }

    /// A picture, a text document, or another file, by the first file's type.
    private var symbol: String {
        let type = attachment.files.first?.contentType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        return AttachmentPreviewContent.isText(type) ? "doc.text" : "doc"
    }
}

private extension View {
    /// On a touch screen, a hit area of at least 44 points; on the Mac, as it is.
    func touchTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        #else
        self
        #endif
    }
}
