import Foundation
import CryptoKit
import Security
import OSLog

class CredentialManager: CredentialManagerProtocol {
    static let shared = CredentialManager()

    private let keychainService = "com.stjohnsoftware.TempoStatusBarApp"
    private let keychainAccount = "credentials"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "CredentialManager")

    private init() {}

    struct Credentials: Codable {
        let apiToken: String
        let accountId: String
        let jiraURL: String
        let warningThreshold: Int
    }

    // MARK: - Keychain helpers

    private func saveToKeychain(data: Data) throws {
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            // kSecAttrAccessibleWhenUnlockedThisDeviceOnly prevents iCloud Keychain backup/sync of
            // API tokens, which is desirable. On macOS, the login keychain stays unlocked for the
            // duration of the user's session, so this does not impede background refresh while the
            // screen is locked (macOS does not lock the keychain on screen lock by default).
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status: status)
        }
    }

    private func loadFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Legacy migration

    private let legacyUserDefaultsKey = "TempoStatusBarApp_Credentials"
    private let legacyUserDefaultsKeyKey = "TempoStatusBarApp_Credentials_key"

    private func migrateLegacyCredentials() -> Credentials? {
        guard let encryptedData = UserDefaults.standard.data(forKey: legacyUserDefaultsKey),
              let keyData = UserDefaults.standard.data(forKey: legacyUserDefaultsKeyKey) else {
            return nil
        }
        do {
            let key = SymmetricKey(data: keyData)
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            let credentials = try JSONDecoder().decode(Credentials.self, from: decryptedData)
            return credentials
        } catch {
            logger.error("Failed to migrate legacy credentials: \(error.localizedDescription)")
            return nil
        }
    }

    private func removeLegacyCredentials() {
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKeyKey)
    }

    // MARK: - CredentialManagerProtocol

    func saveCredentials(apiToken: String, accountId: String, jiraURL: String, warningThreshold: Int = 7) throws {
        let credentials = Credentials(apiToken: apiToken, accountId: accountId, jiraURL: jiraURL, warningThreshold: warningThreshold)
        let data = try JSONEncoder().encode(credentials)
        try saveToKeychain(data: data)
        removeLegacyCredentials()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    func loadCredentials() throws -> Credentials {
        if let data = loadFromKeychain() {
            do {
                return try JSONDecoder().decode(Credentials.self, from: data)
            } catch {
                throw CredentialError.decodingFailed(error: error)
            }
        }

        // Attempt migration from legacy UserDefaults storage
        if let legacyCredentials = migrateLegacyCredentials() {
            // Save to Keychain so future loads use Keychain directly
            let data = try JSONEncoder().encode(legacyCredentials)
            try saveToKeychain(data: data)
            removeLegacyCredentials()
            logger.info("Successfully migrated credentials from UserDefaults to Keychain")
            return legacyCredentials
        }

        throw CredentialError.noStoredCredentials
    }

    func hasStoredCredentials() -> Bool {
        if loadFromKeychain() != nil {
            return true
        }
        // Check for legacy credentials that can be migrated
        return UserDefaults.standard.data(forKey: legacyUserDefaultsKey) != nil
            && UserDefaults.standard.data(forKey: legacyUserDefaultsKeyKey) != nil
    }

    func deleteCredentials() {
        deleteFromKeychain()
        removeLegacyCredentials()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }
}

enum CredentialError: Error, LocalizedError {
    case noStoredCredentials
    case decodingFailed(error: Error)
    case keychainError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noStoredCredentials:
            return "No stored credentials found"
        case .decodingFailed(let error):
            return "Failed to decode credentials: \(error.localizedDescription)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}

// Notification name for credential changes
extension Notification.Name {
    static let credentialsChanged = Notification.Name("credentialsChanged")
}
