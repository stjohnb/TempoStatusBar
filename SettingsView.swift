import SwiftUI

struct MacOSTextField: View {
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    
    init(_ placeholder: String, text: Binding<String>, isSecure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
    }
    
    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .textSelection(.enabled)
        .focused($focusedField)
    }
    
    @FocusState private var focusedField: Bool
}

struct SettingsView: View {
    @State private var apiToken = ""
    @State private var accountId = ""
    @State private var jiraURL = ""
    @State private var warningThreshold = 7
    @State private var isTestingConnection = false
    @State private var isDetectingUser = false
    @State private var testResult: String?
    @State private var detectedUserInfo: String?
    @State private var saveResult: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Jira Tempo Settings")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Jira Instance URL")
                    .font(.headline)
                MacOSTextField("https://your-domain.atlassian.net", text: $jiraURL)
                Text("Your Jira instance URL (e.g., https://yourcompany.atlassian.net)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("API Token")
                    .font(.headline)
                MacOSTextField("Enter your Jira API token", text: $apiToken, isSecure: true)
                Text("Generate from https://id.atlassian.com/manage-profile/security/api-tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Account ID (Optional)")
                    .font(.headline)
                HStack {
                    MacOSTextField("Enter your Jira account ID (optional)", text: $accountId)
                    
                    Button("Auto-detect") {
                        detectUserInfo()
                    }
                    .disabled(apiToken.isEmpty || jiraURL.isEmpty || isDetectingUser)
                    .buttonStyle(.bordered)
                }
                
                if let userInfo = detectedUserInfo {
                    Text(userInfo)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                Text("Account ID (username) is optional - the app can auto-detect it from your API token. This should be your Jira username (e.g., 'bstjohn'), not the internal user ID.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)                
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Warning Threshold")
                    .font(.headline)
                HStack {
                    Text("Show warning after")
                    Stepper(value: $warningThreshold, in: 1...365) {
                        Text("\(warningThreshold) day\(warningThreshold == 1 ? "" : "s")")
                            .fontWeight(.medium)
                    }
                    Text("without worklog")
                }
                Text("The app will show a warning emoji when no worklog has been recorded for this many days or more.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if isDetectingUser {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Detecting user information...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if isTestingConnection {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testing connection...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("✅") ? .green : .red)
                    .multilineTextAlignment(.center)
            }
            
            if let saveResult = saveResult {
                Text(saveResult)
                    .font(.caption)
                    .foregroundColor(saveResult.contains("✅") ? .green : .red)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 16) {
                Button("Test Connection") {
                    Task {
                        await testConnection()
                    }
                }
                .disabled(apiToken.isEmpty || jiraURL.isEmpty || isTestingConnection)
                .buttonStyle(.borderedProminent)
                
                Button("Save & Done") {
                    saveCredentials()
                }
                .disabled(apiToken.isEmpty || jiraURL.isEmpty)
                .buttonStyle(.borderedProminent)
                
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            
            if CredentialManager.shared.hasStoredCredentials() {
                Button("Clear Stored Credentials") {
                    clearStoredCredentials()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding()
        .frame(width: 400, height: 500)
        .onAppear {
            loadStoredCredentials()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func loadStoredCredentials() {
        do {
            let credentials = try CredentialManager.shared.loadCredentials()
            apiToken = credentials.apiToken
            accountId = credentials.accountId
            jiraURL = credentials.jiraURL
            warningThreshold = credentials.warningThreshold
        } catch {
            // No stored credentials or error loading them - this is normal for first-time users
            print("No stored credentials found: \(error.localizedDescription)")
        }
    }
    
    private func saveCredentials() {
        do {
            try CredentialManager.shared.saveCredentials(
                apiToken: apiToken,
                accountId: accountId,
                jiraURL: jiraURL,
                warningThreshold: warningThreshold
            )
            saveResult = "✅ Credentials saved successfully!"
            
            // Dismiss the settings after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dismiss()
            }
        } catch {
            saveResult = "❌ Failed to save credentials: \(error.localizedDescription)"
        }
    }
    
    private func clearStoredCredentials() {
        CredentialManager.shared.deleteCredentials()
        apiToken = ""
        accountId = ""
        jiraURL = ""
                    warningThreshold = 7
        saveResult = "✅ Stored credentials cleared"
    }
    
    private func detectUserInfo() {
        guard !apiToken.isEmpty && !jiraURL.isEmpty else { return }
        
        isDetectingUser = true
        detectedUserInfo = nil
        
        Task {
            do {
                let userInfo = try await TempoService.shared.fetchUserInfo(apiToken: apiToken, jiraURL: jiraURL)
                await MainActor.run {
                    isDetectingUser = false
                    if let user = userInfo {
                        var info = "Detected user info:\n"
                        if let accountId = user.accountId {
                            info += "• Account ID: \(accountId)\n"
                            self.accountId = accountId
                        }
                        if let name = user.name {
                            info += "• Username: \(name)\n"
                        }
                        if let key = user.key {
                            info += "• Key: \(key)\n"
                        }
                        if let email = user.emailAddress {
                            info += "• Email: \(email)"
                        }
                        detectedUserInfo = info
                    } else {
                        detectedUserInfo = "Could not detect user information"
                    }
                }
            } catch {
                await MainActor.run {
                    isDetectingUser = false
                    detectedUserInfo = "Error detecting user: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testConnection() async {
        isTestingConnection = true
        testResult = nil
        
        do {
            // Test the connection using the current form values
            _ = try await TempoService.shared.testConnection(apiToken: apiToken, accountId: accountId, jiraURL: jiraURL)
            await MainActor.run {
                testResult = "✅ Connection successful! Your credentials are valid."
            }
        } catch let tempoError as TempoError {
            await MainActor.run {
                testResult = "❌ Connection failed: \(tempoError.localizedDescription)"
            }
        } catch {
            await MainActor.run {
                testResult = "❌ Connection failed: \(error.localizedDescription)"
            }
        }
        
        await MainActor.run {
            isTestingConnection = false
        }
    }
}

#Preview {
    SettingsView()
}