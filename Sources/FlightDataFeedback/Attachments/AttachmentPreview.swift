// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the bytes kept in the report without writing a plaintext preview to disk.
struct AttachmentPreview: View {
    let file: ReportFile
    @State private var content: AttachmentPreviewContent?
    @State private var zoomed = false

    var body: some View {
        VStack {
            switch content {
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(image, scale: 1, label: Text(file.name))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // The scroll view's width, or the image's own width in points when it is enlarged.
                        .containerRelativeFrame(.horizontal) { length, _ in zoomed ? CGFloat(image.width) : length }
                }
                Button {
                    zoomed.toggle()
                } label: {
                    zoomed ? Text("Fit to Width", bundle: .module) : Text("Enlarge Image", bundle: .module)
                }
            case .pdf(let document):
                AttachmentPDFPreview(document: document)
            case .text(let text):
                AttachmentTextPreview(text: text)
            case .unavailable:
                ContentUnavailableView(String(localized: "Preview Unavailable", bundle: .module), systemImage: "doc",
                                       description: Text(verbatim: "\(file.contentType) · \(size)"))
            case nil:
                ProgressView()
            }
        }
        .task { content = await AttachmentPreviewContent.load(file) }
    }

    /// The file's size as the Finder writes it, such as 12 KB.
    private var size: String {
        Int64(file.data.count).formatted(.byteCount(style: .file))
    }
}

/// What a file shows as: an image, a PDF, text, or nothing the form can draw.
enum AttachmentPreviewContent {
    case image(CGImage)
    case pdf(PDFDocument)
    case text(String)
    case unavailable

    init(_ file: ReportFile) {
        let type = UTType(mimeType: file.contentType)
        if type?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithData(file.data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 3072,
           ] as CFDictionary) {
            self = .image(image)
        } else if type?.conforms(to: .pdf) == true, let document = PDFDocument(data: file.data) {
            self = .pdf(document)
        } else if Self.isText(file.contentType), let text = String(data: file.data, encoding: .utf8) {
            self = .text(text)
        } else {
            self = .unavailable
        }
    }

    /// Decodes the file away from the main actor, so a large image or PDF doesn't hold up the interface.
    @concurrent static func load(_ file: ReportFile) async -> sending AttachmentPreviewContent {
        AttachmentPreviewContent(file)
    }

    /// Whether a content type is text that can be shown as it is: plain text, JSON or XML.
    static func isText(_ type: String) -> Bool {
        type.hasPrefix("text/") || type.contains("json") || type.contains("xml")
    }
}

/// Pages long logs so the full text stays accessible without laying out megabytes at once.
private struct AttachmentTextPreview: View {
    let text: String
    @State private var starts: [String.Index] = []

    var body: some View {
        let start = starts.last ?? text.startIndex
        let end = text.index(start, offsetBy: 8_000, limitedBy: text.endIndex) ?? text.endIndex
        ScrollView {
            Text(verbatim: String(text[start..<end]))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(start)
        if !starts.isEmpty || end < text.endIndex {
            HStack {
                Button(String(localized: "Previous", bundle: .module)) { starts.removeLast() }.disabled(starts.isEmpty)
                Text("Page \(starts.count + 1)", bundle: .module)
                Button(String(localized: "Next", bundle: .module)) { starts.append(end) }.disabled(end == text.endIndex)
            }
        }
    }
}

#if os(macOS)
private struct AttachmentPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#else
private struct AttachmentPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif
