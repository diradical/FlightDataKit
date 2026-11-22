// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import FlightDataFormat
import Foundation

/// The report types an app sends, as a SwiftData schema lists an app's model types. Each type's name is its
/// channel, so the names must differ.
public struct ReportSchema: Sendable {
    /// The types, in the order given.
    public let types: [any FlightDataReport.Type]

    /// A schema of `types`, such as `ReportSchema([Feedback.self, BankingAnalytics.self])`.
    public init(_ types: [any FlightDataReport.Type]) {
        self.types = types
    }

    /// Checks the schema against the configurations, and resolves which configuration covers each type.
    func routes(for configurations: [FlightDataConfiguration]) throws -> [ObjectIdentifier: Route] {
        var names: Set<String> = []
        for type in types {
            do { try ReportLimits.validateChannel(type.name) } catch {
                throw FlightDataConfigurationError.invalidChannel(type.name)
            }
            guard names.insert(type.name).inserted else {
                throw FlightDataConfigurationError.duplicateChannel(type.name)
            }
        }
        let registered = Set(types.map(ObjectIdentifier.init))
        var named: [ObjectIdentifier: (FlightDataConfiguration, Curve25519.KeyAgreement.PublicKey)] = [:]
        var fallback: (FlightDataConfiguration, Curve25519.KeyAgreement.PublicKey)?
        for configuration in configurations {
            let recipient = try Self.recipient(configuration)
            if configuration.types.isEmpty {
                guard fallback == nil else { throw FlightDataConfigurationError.duplicateFallback }
                fallback = (configuration, recipient)
            }
            for type in configuration.types {
                let id = ObjectIdentifier(type)
                guard registered.contains(id) else { throw FlightDataConfigurationError.unknownType(type.name) }
                guard named[id] == nil else { throw FlightDataConfigurationError.duplicateRoute(type.name) }
                named[id] = (configuration, recipient)
            }
        }
        var routes: [ObjectIdentifier: Route] = [:]
        for type in types {
            guard let (configuration, recipient) = named[ObjectIdentifier(type)] ?? fallback else {
                throw FlightDataConfigurationError.missingRoute(type.name)
            }
            if type is any PeriodicFlightDataReport.Type, configuration.saves == .explicitly {
                throw FlightDataConfigurationError.periodicWithoutPeriod(type.name)
            }
            routes[ObjectIdentifier(type)] = Route(name: type.name, kind: type.kind, saves: configuration.saves,
                                                   recipient: recipient, periodicContent: configuration.periodicContent)
        }
        return routes
    }

    /// The configuration's key, checked by agreeing a secret with it: a key that parses can still be one nothing
    /// can be sealed to.
    private static func recipient(_ configuration: FlightDataConfiguration)
        throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            let recipient = try Envelope.publicKey(from: configuration.publicKey)
            _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: recipient)
            return recipient
        } catch {
            throw FlightDataConfigurationError.invalidPublicKey(channels: configuration.types.map { $0.name })
        }
    }
}
