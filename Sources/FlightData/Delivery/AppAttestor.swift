// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightDataFormat
import Foundation
import Security
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// What App Attest does for a sender: makes a key in the Secure Enclave, has Apple attest it, and signs with it.
/// A protocol so that tests can stand in for the device.
protocol AppAttestor: Sendable {
    /// Whether this copy of the app, on this device, can prove itself at all.
    var isSupported: Bool { get }
    /// The App ID prefix this copy is signed with, usually the developer's Team ID: ten characters, A–Z and 0–9.
    /// Nil when it can't be read. The server is told it, and believes Apple's attestation, not the telling.
    var appIDPrefix: String? { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

enum AttestorError: Error, Equatable, Sendable {
    /// Apple's service couldn't be reached. The same key can be attested later.
    case unavailable
    /// The key is gone or was refused: after a reinstall or a restore, or a second attestation.
    case invalidKey
    case failed
}

/// The device's own App Attest. Supported for an app with an App ID, on a device with a Secure Enclave; never in
/// the simulator, in a command-line tool or in most extensions.
struct DeviceAttestor: AppAttestor {
    #if canImport(DeviceCheck)
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await translating { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await translating { try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await translating {
            try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        }
    }

    var appIDPrefix: String? {
        guard let prefix = Self.signedPrefix(), prefix.wholeMatch(of: /[A-Z0-9]{10}/) != nil else { return nil }
        return prefix
    }

    #if os(macOS)
    /// Read from the copy's own code signature: the start of its application identifier, which is the prefix, a
    /// period and the bundle ID, or its team when it was signed without one.
    private static func signedPrefix() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let signature = information as? [String: Any] else { return nil }
        let entitlements = signature[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        if let appID = entitlements?["com.apple.application-identifier"] as? String,
           let prefix = appID.split(separator: ".").first {
            return String(prefix)
        }
        return signature[kSecCodeInfoTeamIdentifier as String] as? String
    }
    #else
    /// Read from the keychain, where a signature can't be: the install ID the kit keeps there is in the app's own
    /// access group, which is the prefix, a period and a name. Nil for an app that keeps its install ID elsewhere.
    private static func signedPrefix() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Bundle.main.bundleIdentifier ?? "dev.flightdata.kit",
                                    kSecAttrAccount as String: KeychainInstallIDStore.account,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let group = (found as? [String: Any])?[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first else { return nil }
        return String(prefix)
    }
    #endif

    private func translating<Value: Sendable>(_ work: @Sendable () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let error as DCError {
            switch error.code {
            case .serverUnavailable: throw AttestorError.unavailable
            case .invalidKey: throw AttestorError.invalidKey
            default: throw AttestorError.failed
            }
        } catch {
            throw AttestorError.failed
        }
    }
    #else
    var isSupported: Bool { false }
    var appIDPrefix: String? { nil }
    func generateKey() async throws -> String { throw AttestorError.failed }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw AttestorError.failed }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { throw AttestorError.failed }
    #endif
}
