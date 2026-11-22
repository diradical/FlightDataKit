// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// How the kit keeps its files: in a directory left out of device backups, written whole or not at all and, on
/// iOS, readable from the device's first unlock after it starts.
enum Storage {
    /// Creates `directory`, and what is missing above it. When it was missing, it is left out of backups: what is
    /// in it belongs to this device, and its reports are sent from here.
    static func makeDirectory(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directory = directory
        try? directory.setResourceValues(excluded)
    }

    /// Writes `data` to `file` atomically.
    static func write(_ data: Data, to file: URL) throws {
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    /// Removes `item`, which may already be gone.
    static func remove(_ item: URL) throws {
        do { try FileManager.default.removeItem(at: item) } catch where isMissing(error) {}
    }

    static func exists(_ item: URL) -> Bool {
        FileManager.default.fileExists(atPath: item.path)
    }

    /// Whether the error says there was no such file.
    static func isMissing(_ error: any Error) -> Bool {
        guard let cocoa = error as? CocoaError else { return false }
        return cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile
    }
}
