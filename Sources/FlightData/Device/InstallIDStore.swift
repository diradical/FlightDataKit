// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

/// Supplies the installation identifier sent in the `X-Install-ID` request header. The kit keeps its own in the
/// keychain; tests in other packages give their own through the `Testing` SPI.
@_spi(Testing) public protocol InstallIDStore: Sendable {
    /// The install ID: the same one each time.
    func installID() throws -> String
}
