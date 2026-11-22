// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

/// What a container knows of one report type once its setup has been checked: its channel, its kind, how it is
/// saved and the key it is sealed to.
struct Route: Sendable {
    let name: String
    let kind: ReportKind
    let saves: FlightDataConfiguration.Saves
    let recipient: Curve25519.KeyAgreement.PublicKey
    /// For a periodic type: how a gathered report's JSON becomes what is sent.
    let periodicContent: (@Sendable (Data) throws -> ReportContent)?

    /// The period of a periodic type, in seconds; nil for one submitted on its own.
    var period: TimeInterval? {
        if case .every(let period) = saves { return period.seconds }
        return nil
    }
}
