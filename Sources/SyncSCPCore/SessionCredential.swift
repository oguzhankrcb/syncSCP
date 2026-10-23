// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// A secret placed in Keychain only while ssh asks for it through askpass (SYNCSCP_ASKPASS_ID).
public enum SessionCredential {
    private static let service = "io.github.oguzhankrcb.syncscp.session"
    public static func store(_ secret: String) throws -> String {
        let id = UUID().uuidString
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                kSecAttrAccount: id, kSecValueData: Data(secret.utf8),
                                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClientError.invalid("Could not temporarily store the SSH credential in Keychain (\(status)).") }
        return id
    }
    public static func read(_ id: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                         kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func remove(_ id: String) -> Bool {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
