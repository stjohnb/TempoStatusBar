import Foundation
import CryptoKit

class CredentialManager: CredentialManagerProtocol {
    static let shared = CredentialManager()
    
    private let userDefaultsKey = "TempoStatusBarApp_Credentials"
    private let userDefaultsKeyKey = "TempoStatusBarApp_Credentials_key"
    
    private init() {}
    
    struct Credentials: Codable {
        let apiToken: String
        let accountId: String
        let jiraURL: String
        let warningThreshold: Int
    }
    
    func saveCredentials(apiToken: String, accountId: String, jiraURL: String, warningThreshold: Int = 7) throws {
        print("Debug: CredentialManager - Saving credentials...")
        print("Debug: CredentialManager - API Token: \(apiToken.prefix(10))...")
        print("Debug: CredentialManager - Account ID: \(accountId)")
        print("Debug: CredentialManager - Jira URL: \(jiraURL)")
        print("Debug: CredentialManager - Warning Threshold: \(warningThreshold)")
        
        let credentials = Credentials(apiToken: apiToken, accountId: accountId, jiraURL: jiraURL, warningThreshold: warningThreshold)
        let data = try JSONEncoder().encode(credentials)
        
        // Encrypt the data before storing
        let key = SymmetricKey(size: .bits256)
        let encryptedData = try AES.GCM.seal(data, using: key)
        
        // Store both encrypted data and key (in production, you'd want to store the key more securely)
        UserDefaults.standard.set(encryptedData.combined, forKey: userDefaultsKey)
        UserDefaults.standard.set(key.withUnsafeBytes { Data($0) }, forKey: userDefaultsKeyKey)
        
        print("Debug: CredentialManager - Credentials saved successfully")
        print("Debug: CredentialManager - Encrypted data size: \(encryptedData.combined?.count ?? 0)")
        print("Debug: CredentialManager - Key data size: \(key.withUnsafeBytes { Data($0) }.count)")
        
        // Post notification that credentials were saved
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }
    
    func loadCredentials() throws -> Credentials {
        print("Debug: CredentialManager - Loading credentials...")
        
        guard let encryptedData = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            print("Debug: CredentialManager - No encrypted data found in UserDefaults")
            throw CredentialError.noStoredCredentials
        }
        
        guard let keyData = UserDefaults.standard.data(forKey: userDefaultsKeyKey) else {
            print("Debug: CredentialManager - No key data found in UserDefaults")
            throw CredentialError.noStoredCredentials
        }
        
        print("Debug: CredentialManager - Found encrypted data size: \(encryptedData.count)")
        print("Debug: CredentialManager - Found key data size: \(keyData.count)")
        
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        
        do {
            let credentials = try JSONDecoder().decode(Credentials.self, from: decryptedData)
            print("Debug: CredentialManager - Credentials loaded successfully")
            print("Debug: CredentialManager - API Token: \(credentials.apiToken.prefix(10))...")
            print("Debug: CredentialManager - Account ID: \(credentials.accountId)")
            print("Debug: CredentialManager - Jira URL: \(credentials.jiraURL)")
            return credentials
        } catch {
            print("Debug: CredentialManager - Failed to decode credentials: \(error)")
            throw CredentialError.decodingFailed(error: error)
        }
    }
    
    func hasStoredCredentials() -> Bool {
        print("Debug: CredentialManager - Checking if credentials exist...")
        do {
            _ = try loadCredentials()
            print("Debug: CredentialManager - Credentials exist")
            return true
        } catch {
            print("Debug: CredentialManager - No credentials found: \(error)")
            return false
        }
    }
    
    func deleteCredentials() {
        print("Debug: CredentialManager - Deleting credentials...")
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsKeyKey)
        print("Debug: CredentialManager - Credentials deleted")
        
        // Post notification that credentials were deleted
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }
}

enum CredentialError: Error, LocalizedError {
    case noStoredCredentials
    case decodingFailed(error: Error)
    
    var errorDescription: String? {
        switch self {
        case .noStoredCredentials:
            return "No stored credentials found"
        case .decodingFailed(let error):
            return "Failed to decode credentials: \(error.localizedDescription)"
        }
    }
}

// Notification name for credential changes
extension Notification.Name {
    static let credentialsChanged = Notification.Name("credentialsChanged")
} 