// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// What is wrong with a container's setup. A container that finds one sends nothing: a debug build stops with
/// this description, and a release build logs it.
enum FlightDataConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidAppToken
    case invalidChannel(String)
    case duplicateChannel(String)
    case unknownType(String)
    case duplicateRoute(String)
    case duplicateFallback
    case missingRoute(String)
    case periodicWithoutPeriod(String)
    /// The listed channels share this recipient. An empty list is the configuration that covers the rest.
    case invalidPublicKey(channels: [String])

    var description: String {
        switch self {
        case .invalidAppToken: "The app token isn’t one Flight Data Recorder gave: fdk_ and 32 lowercase hex digits."
        case .invalidChannel(let name): "The channel ‘\(name)’ must have 1–256 bytes and no control characters."
        case .duplicateChannel(let name): "Two report types are named ‘\(name)’."
        case .unknownType(let name): "A configuration names ‘\(name)’, which isn’t in the schema."
        case .duplicateRoute(let name): "More than one configuration names ‘\(name)’."
        case .duplicateFallback: "Only one configuration may name no types."
        case .missingRoute(let name): "No configuration covers ‘\(name)’."
        case .periodicWithoutPeriod(let name):
            "‘\(name)’ is periodic: give it FlightDataConfiguration(periodic:every:publicKey:)."
        case .invalidPublicKey(let channels):
            channels.isEmpty ? "The configuration that names no types has an invalid public key."
                : "The public key for \(channels.joined(separator: ", ")) is invalid or mistyped."
        }
    }
}
