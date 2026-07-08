import SwiftUI

struct ContentView: View {
    @StateObject private var stateManager = WorklogStateManager.shared
    @State private var showingSettings = false
    
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
            
            if stateManager.isLoading {
                Text("Loading...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if let error = stateManager.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            } else if let worklog = stateManager.latestWorklog {
                VStack(spacing: 12) {
                    HStack {
                        Text(stateManager.statusEmoji)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            if let days = stateManager.daysSinceLastWorklog {
                                Text("\(days) day\(days == 1 ? "" : "s") ago")
                                    .font(.caption)
                                    .foregroundColor(stateManager.statusColor)
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
            } else if !stateManager.hasCredentials {
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
                stateManager.refresh()
            }
            .disabled(!stateManager.hasCredentials)
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 350, height: 280)
        .onAppear {
            stateManager.checkCredentialsAndRefresh()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onChange(of: showingSettings) { newValue in
            if !newValue {
                // Settings sheet was dismissed, check if credentials were updated
                stateManager.checkCredentialsAndRefresh()
            }
        }
    }
}

#Preview {
    ContentView()
}