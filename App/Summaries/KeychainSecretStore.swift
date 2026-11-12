// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import Security

/// Endpoint API keys, as generic passwords in the login keychain. Never written anywhere else.
struct KeychainSecretStore: SecretStore {
    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    private let service = "io.github.rosslopez.minutes.endpoint"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) throws -> String? {
        var item: CFTypeRef?
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure(status: status)
        }
        return String(bytes: data, encoding: .utf8)
    }

    func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Minutes endpoint API key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw Failure(status: added)
            }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    func removeSecret(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status)
        }
    }
}
