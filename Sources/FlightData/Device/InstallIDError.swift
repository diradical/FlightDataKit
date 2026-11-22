// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Security

/// The keychain refused to keep or give the install ID.
enum InstallIDError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}
