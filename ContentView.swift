import SwiftUI

struct ContentView: View {
    @State private var daysSinceLastWorklog: Int?
    @State private var latestWorklog: Worklog?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasCredentials = false
    @State private var warningThreshold = 7
    @State private var showingSettings = false
    
    private var statusEmoji: String {
        guard let days = daysSinceLastWorklog else { return "" }
        if days <= warningThreshold {
            return "✅"
        } else if days <= warningThreshold + 1 {
            return "⏰"
        } else {
            return "🚨"
        }
    }
    
    private var statusColor: Color {
        guard let days = daysSinceLastWorklog else { return .secondary }
        if days <= warningThreshold {
            return .green
        } else if days <= warningThreshold + 1 {
            return .orange
        } else {
            return .red
        }
    }
    
    private func formatTimeSpent(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func formatDate(_ dateString: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        
        guard let date = dateFormatter.date(from: dateString) else {
            return dateString
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Tempo Status")
                .font(.headline)
            
            if isLoading {
                Text("Loading...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            } else if let worklog = latestWorklog {
                VStack(spacing: 12) {
                    HStack {
                        Text(statusEmoji)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            if let days = daysSinceLastWorklog {
                                Text("\(days) day\(days == 1 ? "" : "s") ago")
                                    .font(.caption)
                                    .foregroundColor(statusColor)
                            }
                            
                            if let issue = worklog.issue {
                                Text(issue.key)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                if let summary = issue.summary {
                                    Text(summary)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Time spent:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatTimeSpent(worklog.timeSpentSeconds))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        HStack {
                            Text("Date:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatDate(worklog.dateStarted))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        if let comment = worklog.comment, !comment.isEmpty {
                            HStack(alignment: .top) {
                                Text("Comment:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(comment)
                                    .font(.caption)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !hasCredentials {
                VStack(spacing: 12) {
                    Text("No credentials configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("Open Settings") {
                        showingSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No worklog data available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Button("Refresh") {
                loadTempoData()
            }
            .disabled(!hasCredentials)
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 350, height: 280)
        .onAppear {
            checkCredentialsAndRefresh()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onChange(of: showingSettings) { newValue in
            if !newValue {
                // Settings sheet was dismissed, check if credentials were updated
                checkCredentialsAndRefresh()
            }
        }
    }
    
    private func checkCredentialsAndRefresh() {
        hasCredentials = CredentialManager.shared.hasStoredCredentials()
        if hasCredentials {
            // Load the warning threshold from credentials
            do {
                let credentials = try CredentialManager.shared.loadCredentials()
                warningThreshold = credentials.warningThreshold
            } catch {
                // If we can't load credentials, use default value
                warningThreshold = 7
            }
            loadTempoData()
        } else {
            // Clear any existing data when no credentials are available
            daysSinceLastWorklog = nil
            latestWorklog = nil
            errorMessage = nil
            warningThreshold = 7
        }
    }
    
    private func loadTempoData() {
        guard hasCredentials else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let credentials = try CredentialManager.shared.loadCredentials()
                
                // Fetch the actual worklog data
                let worklog = try await TempoService.shared.fetchLatestWorklog(
                    apiToken: credentials.apiToken,
                    jiraURL: credentials.jiraURL,
                    accountId: credentials.accountId.isEmpty ? nil : credentials.accountId
                )
                
                // Calculate days since last worklog
                let days = await TempoService.shared.getDaysSinceLastWorklog(
                    apiToken: credentials.apiToken,
                    jiraURL: credentials.jiraURL,
                    accountId: credentials.accountId.isEmpty ? nil : credentials.accountId
                )
                
                await MainActor.run {
                    isLoading = false
                    latestWorklog = worklog
                    daysSinceLastWorklog = days
                    
                    // Notify AppDelegate to update the status bar
                    NotificationCenter.default.post(name: .worklogDataRefreshed, object: nil)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    if let credentialError = error as? CredentialError {
                        switch credentialError {
                        case .noStoredCredentials:
                            errorMessage = "No credentials configured"
                            hasCredentials = false
                        case .decodingFailed(let error):
                            errorMessage = "Credential error: \(error.localizedDescription)"
                        }
                    } else if let tempoError = error as? TempoError {
                        errorMessage = "Tempo error: \(tempoError.localizedDescription)"
                    } else {
                        errorMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}