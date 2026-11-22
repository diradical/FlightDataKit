// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Security

/// Keeps the install ID in the Keychain under the app's own bundle ID, so it survives reinstalls and is private to
/// the app.
///
/// An app signed with an application identifier keeps it in the data-protection keychain, where the item belongs
/// to the app's access group: every build the team signs reads it and nobody is asked. A process without one
/// (`swift test`, an unsigned tool) falls back to the login keychain, whose items trust the signature that made
/// them: a build with another signature is asked, and a refusal fails the read.
struct KeychainInstallIDStore: InstallIDStore {
    static let account = "flightdata-install-id"

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "dev.flightdata.kit") {
        self.service = service
    }

    func installID() throws -> String {
        do {
            return try installID(dataProtection: true)
        } catch InstallIDError.keychain(errSecMissingEntitlement) {
            return try installID(dataProtection: false)
        }
    }

    private func installID(dataProtection: Bool) throws -> String {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: Self.account,
                                   kSecUseDataProtectionKeychain as String: dataProtection]
        if let id = try read(item) { return id }
        let id = InstallID.make()
        let attributes = item.merging([
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let add = SecItemAdd(attributes as CFDictionary, nil)
        switch add {
        case errSecSuccess:
            return id
        case errSecDuplicateItem:
            // Another process of the app made one in the meantime: use theirs. One this process may not read (made
            // by a build with another signature) can't be replaced, so give up.
            if let theirs = try read(item) { return theirs }
            throw InstallIDError.keychain(add)
        default:
            throw InstallIDError.keychain(add)
        }
    }

    /// The stored ID, or nil when there is none. Throws when there is one this process may not read.
    private func read(_ item: [String: Any]) throws -> String? {
        var found: CFTypeRef?
        let query = item.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        switch status {
        case errSecSuccess:
            guard let data = found as? Data, let id = String(data: data, encoding: .utf8) else {
                throw InstallIDError.keychain(errSecDecode)
            }
            return id
        case errSecItemNotFound:
            return nil
        default:
            throw InstallIDError.keychain(status)
        }
    }
}
