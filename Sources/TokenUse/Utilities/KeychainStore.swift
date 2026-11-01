import Foundation
import Security

/// macOS Keychain 凭证存储（无外部依赖，线程安全）
/// 用于安全保存用户在设置页添加的多账号 API Key、OAuth Token、Cookie 等敏感信息。
enum KeychainStore {
    private static let service = "com.tokenuse.app.accounts"

    static func saveSecret(_ secret: String, for accountID: String) throws {
        guard let data = secret.data(using: .utf8) else { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            for (k, v) in attributes {
                addQuery[k] = v
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError.osStatus(updateStatus)
        }
    }

    static func loadSecret(for accountID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func deleteSecret(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainStoreError: Error, LocalizedError {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let code):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
            return "Keychain 操作失败: \(message)"
        }
    }
}
