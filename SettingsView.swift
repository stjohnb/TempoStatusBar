import SwiftUI
import OSLog

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
    }
}

struct SettingsView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "SettingsView")
    @State private var apiToken = ""
    @State private var accountId = ""
    @State private var jiraURL = ""
    @State private var warningThreshold = 7
    @State private var githubToken = ""
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.shared.isEnabled
    @State private var launchAtLoginError: String?
    @State private var isTestingConnection = false
    @State private var isDetectingUser = false
    @State private var testResult: String?
    @State private var detectedUserInfo: String?
    @State private var saveResult: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var stateManager = WorklogStateManager.shared
    
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
                        .foregroundColor(userInfo.hasPrefix("❌") ? .red : .green)
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

            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub Update Token (Optional)")
                    .font(.headline)
                MacOSTextField("Personal access token for update checks", text: $githubToken, isSecure: true)
                Text("Required when the repository is private. Create a fine-grained PAT scoped to St-John-Software/TempoStatusBar with Contents: read at https://github.com/settings/personal-access-tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
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
                    .foregroundColor(result.contains("✅") ? .green : result.contains("⚠️") ? .orange : .red)
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
            
            VStack(alignment: .leading, spacing: 8) {
                Text("App Settings")
                    .font(.headline)
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                try LaunchAtLoginManager.shared.setEnabled(newValue)
                                launchAtLogin = newValue
                                launchAtLoginError = nil
                            } catch {
                                launchAtLogin = !newValue
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                    ))
                    if let error = launchAtLoginError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                } else {
                    HStack {
                        Text("Launch at Login")
                        Spacer()
                        Text("Requires macOS 13 or later")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }

            if stateManager.hasCredentials {
                Button("Clear Stored Credentials") {
                    clearStoredCredentials()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding()
        .frame(width: 400, height: 640)
        .onAppear {
            loadStoredCredentials()
            launchAtLogin = LaunchAtLoginManager.shared.isEnabled
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
            githubToken = credentials.githubToken ?? ""
        } catch {
            // No stored credentials or error loading them - this is normal for first-time users
            logger.info("No stored credentials found: \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    private func trimFields() -> Bool {
        apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        jiraURL = jiraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        githubToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !apiToken.isEmpty && !jiraURL.isEmpty
    }

    private func saveCredentials() {
        guard trimFields() else {
            saveResult = "❌ API token and Jira URL cannot be empty"
            return
        }
        do {
            try CredentialManager.shared.saveCredentials(
                apiToken: apiToken,
                accountId: accountId,
                jiraURL: jiraURL,
                warningThreshold: warningThreshold,
                githubToken: githubToken.isEmpty ? nil : githubToken
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
        githubToken = ""
        saveResult = "✅ Stored credentials cleared"
    }
    
    private func detectUserInfo() {
        guard trimFields() else {
            detectedUserInfo = "❌ API token and Jira URL cannot be empty"
            return
        }
        isDetectingUser = true
        detectedUserInfo = nil

        Task {
            do {
                let userInfo = try await TempoService.shared.fetchUserInfo(
                    apiToken: apiToken,
                    jiraURL: jiraURL
                )
                await MainActor.run {
                    isDetectingUser = false
                    if let user = userInfo {
                        var info = "Detected user info:\n"
                        if let name = user.name {
                            info += "• Username: \(name)\n"
                            self.accountId = name
                        }
                        if let key = user.key {
                            info += "• Key: \(key)\n"
                        }
                        if let email = user.emailAddress {
                            info += "• Email: \(email)"
                        }
                        detectedUserInfo = info
                    } else {
                        detectedUserInfo = "❌ Could not detect user information"
                    }
                }
            } catch {
                await MainActor.run {
                    isDetectingUser = false
                    detectedUserInfo = "❌ Error detecting user: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testConnection() async {
        guard trimFields() else {
            testResult = "❌ API token and Jira URL cannot be empty"
            return
        }
        isTestingConnection = true
        testResult = nil

        testResult = await runConnectionTest(
            apiToken: apiToken, accountId: accountId, jiraURL: jiraURL,
            service: TempoService.shared
        )
        isTestingConnection = false
    }
}

func runConnectionTest(
    apiToken: String,
    accountId: String,
    jiraURL: String,
    service: any TempoServiceProtocol
) async -> String {
    do {
        if !accountId.isEmpty {
            let userInfo = try await service.fetchUserInfo(apiToken: apiToken, jiraURL: jiraURL)
            let resolvedName = userInfo?.name
            let resolvedKey = userInfo?.key
            // Only check for mismatch if the server returned at least one identity field;
            // if both are nil the API gave us nothing to compare against, so let
            // fetchLatestWorklog surface the real error (missingCredentials).
            if resolvedName != nil || resolvedKey != nil {
                if resolvedName?.lowercased() != accountId.lowercased() &&
                   resolvedKey?.lowercased() != accountId.lowercased() {
                    let resolved = resolvedName ?? resolvedKey ?? "unknown"
                    return "⚠️ API token authenticated, but Account ID '\(accountId)' does not match your Jira user '\(resolved)'. Worklog access was not tested."
                }
            }
        }
        _ = try await service.fetchLatestWorklog(apiToken: apiToken, jiraURL: jiraURL, accountId: accountId)
        return "✅ Connection successful! Your credentials are valid."
    } catch let tempoError as TempoError {
        return "❌ Connection failed: \(tempoError.localizedDescription)"
    } catch {
        return "❌ Connection failed: \(error.localizedDescription)"
    }
}

#Preview {
    SettingsView()
}