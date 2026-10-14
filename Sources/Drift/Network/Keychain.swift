import Foundation
import Security

enum Keychain {
    private static let service = "com.drift.connection"

    static func setPassword(_ password: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // Pin the classic file keychain explicitly; the password has to
            // survive across builds and stay readable by `security`(1) for
            // diagnostics.
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            writeProbeLog("[keychain] update ok")
            return
        }
        if status == errSecItemNotFound {
            let addStatus = add(query: query, data: data)
            writeProbeLog("[keychain] add status=\(addStatus)")
            return
        }
        // Ad-hoc builds change identity every compile, so the item's ACL can
        // reject updates (-67030). Rebuild the item with permissive access.
        writeProbeLog("[keychain] update status=\(status) — rebuilding")
        let deleteStatus = SecItemDelete(query as CFDictionary)
        let addStatus = add(query: query, data: data)
        writeProbeLog("[keychain] delete status=\(deleteStatus) add status=\(addStatus)")
    }

    private static func add(query: [String: Any], data: Data) -> OSStatus {
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            writeProbeLog("[keychain] read status=\(status)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
