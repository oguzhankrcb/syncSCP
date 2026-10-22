// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import LocalAuthentication
import SyncSCPCore

/// Passwords the user chose to save (WinSCP's "Save password"): one Keychain item per site,
/// this device only. Site files never contain them.
enum SavedPasswords {
    private static let service = "io.github.oguzhankrcb.syncscp.site-password"
    /// Settings ▸ Passwords: ask for Touch ID or the Mac password before a saved password is used.
    static let requireAuthenticationKey = "RequireAuthenticationForSavedPasswords"

    private static func query(_ site: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: site.uuidString]
    }

    static func save(_ password: String, for site: UUID) throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query(site) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(site)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel] = "syncSCP site password"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientError.invalid("Keychain could not save the password (\(status)).") }
    }

    static func read(_ site: UUID) -> String? {
        var item = query(site); item[kSecReturnData] = true; item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Which of `sites` have a saved password; reads attributes only, never the secrets.
    static func sites(among sites: [UUID]) -> Set<UUID> {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        let saved = Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) })
        return saved.intersection(sites)
    }

    static func remove(_ site: UUID) {
        SecItemDelete(query(site) as CFDictionary)
    }

    /// Touch ID or the Mac password, when Settings ask for it, before a saved password is used.
    @MainActor static func authorize(_ reason: String) async -> Bool {
        guard UserDefaults.standard.bool(forKey: requireAuthenticationKey) else { return true }
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
