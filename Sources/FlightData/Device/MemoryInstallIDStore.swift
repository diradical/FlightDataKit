// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Keeps the install ID in memory: for previews and tests.
@_spi(Testing) public final class MemoryInstallIDStore: InstallIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?

    /// A store holding `id`, or an ID made on first use when it is nil.
    public init(_ id: String? = nil) { self.id = id }

    /// The ID given, or the one made the first time it was asked for.
    public func installID() throws -> String {
        lock.withLock {
            if let id { return id }
            let made = InstallID.make()
            id = made
            return made
        }
    }
}
