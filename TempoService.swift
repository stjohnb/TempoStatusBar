import Foundation
import OSLog
import SwiftUI
import AppKit

// MARK: - Protocols for Dependency Injection

protocol CredentialManagerProtocol {
    func hasStoredCredentials() -> Bool
    func loadCredentials() throws -> CredentialManager.Credentials
}

protocol TempoServiceProtocol {
    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String?) async throws -> Worklog?
}

// MARK: - Centralized State Management

@MainActor
class WorklogStateManager: ObservableObject {
    static let shared = WorklogStateManager()

    @Published var daysSinceLastWorklog: Int?
    @Published var latestWorklog: Worklog?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasCredentials = false
    @Published var warningThreshold = 7

    private var refreshTimer: Timer?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "WorklogStateManager")

    // Dependency injection for testing
    var credentialManager: CredentialManagerProtocol = CredentialManager.shared
    var tempoService: TempoServiceProtocol = TempoService.shared

    init() {
        setupTimer()
        checkCredentialsAndRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public Methods

    func refresh() {
        Task {
            await loadTempoData()
        }
    }

    func checkCredentialsAndRefresh() {
        hasCredentials = credentialManager.hasStoredCredentials()
        if hasCredentials {
            do {
                let credentials = try credentialManager.loadCredentials()
                warningThreshold = credentials.warningThreshold
                refresh()
            } catch {
                logger.error("Failed to load credentials: \(error.localizedDescription, privacy: .public)")
                hasCredentials = false
                clearData()
                errorMessage = "Credential error: \(error.localizedDescription)"
            }
        } else {
            // Clear any existing data when no credentials are available
            clearData()
        }
    }

    // MARK: - Private Methods

    private func setupTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                await self.loadTempoData()
            }
        }
    }

    func clearData() {
        daysSinceLastWorklog = nil
        latestWorklog = nil
        errorMessage = nil
        warningThreshold = 7
    }

    func resetForTesting() {
        clearData()
        hasCredentials = false
        isLoading = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func loadTempoData() async {
        guard hasCredentials else { return }

        isLoading = true
        errorMessage = nil

        do {
            let credentials = try credentialManager.loadCredentials()

            // Fetch the actual worklog data
            let worklog = try await tempoService.fetchLatestWorklog(
                apiToken: credentials.apiToken,
                jiraURL: credentials.jiraURL,
                accountId: credentials.accountId.isEmpty ? nil : credentials.accountId
            )

            isLoading = false
            latestWorklog = worklog
            daysSinceLastWorklog = worklog?.daysSinceStarted

        } catch {
            isLoading = false
            if let credentialError = error as? CredentialError {
                switch credentialError {
                case .noStoredCredentials:
                    errorMessage = "No credentials configured"
                    hasCredentials = false
                case .decodingFailed(let error):
                    errorMessage = "Credential error: \(error.localizedDescription)"
                    hasCredentials = false
                case .keychainError(let status):
                    errorMessage = "Keychain error: \(status)"
                    hasCredentials = false
                }
            } else if let tempoError = error as? TempoError {
                errorMessage = "Tempo error: \(tempoError.localizedDescription)"
            } else {
                errorMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Computed Properties for Status Display

extension WorklogStateManager {
    var statusEmoji: String {
        guard let days = daysSinceLastWorklog else { return "" }
        if days <= warningThreshold {
            return "✅"
        } else if days == warningThreshold + 1 {
            return "⏰"
        } else {
            return "🚨"
        }
    }

    var statusColor: Color {
        guard let days = daysSinceLastWorklog else { return .secondary }
        if days <= warningThreshold {
            return .green
        } else if days <= warningThreshold + 1 {
            return .orange
        } else {
            return .red
        }
    }

    var statusBarColor: NSColor {
        guard let days = daysSinceLastWorklog else { return .labelColor }
        if days <= warningThreshold {
            return .systemGreen
        } else if days <= warningThreshold + 1 {
            return .systemOrange
        } else {
            return .systemRed
        }
    }

    var statusBarTitle: String {
        guard let days = daysSinceLastWorklog else { return "⏱️" }
        return "\(statusEmoji) \(days)"
    }

    var statusBarTooltip: String {
        guard let days = daysSinceLastWorklog else { return "No worklog data available" }
        return "Last worklog: \(days) day\(days == 1 ? "" : "s") ago"
    }
}

// MARK: - Existing Code

struct WorklogResponse: Codable {
    let results: [Worklog]
}

struct Worklog: Codable {
    let dateStarted: String
    let timeSpentSeconds: Int
    let comment: String?
    let issue: WorklogIssue?

    var started: String { dateStarted }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let legacyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? legacyFormatter.date(from: string)
    }

    var daysSinceStarted: Int? {
        guard let date = Worklog.parseDate(dateStarted) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day
        return days.flatMap { $0 >= 0 ? $0 : nil }
    }
}

struct WorklogIssue: Codable {
    let key: String
    let summary: String?
}

struct UserInfo: Codable {
    let accountId: String?
    let name: String?
    let key: String?
    let emailAddress: String?

    enum CodingKeys: String, CodingKey {
        case key, name, emailAddress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
        accountId = name
    }
}

class TempoService: TempoServiceProtocol {
    static let shared = TempoService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "TempoService")

    private static let worklogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {}

    func fetchUserInfo(apiToken: String, jiraURL: String) async throws -> UserInfo? {
        let baseURL = jiraURL.hasSuffix("/") ? jiraURL : jiraURL + "/"
        let urlString = "\(baseURL)rest/api/2/myself"

        guard let url = URL(string: urlString) else {
            throw TempoError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TempoError.networkError
            }

            if httpResponse.statusCode == 401 {
                throw TempoError.unauthorized
            } else if httpResponse.statusCode == 403 {
                throw TempoError.forbidden
            } else if httpResponse.statusCode != 200 {
                throw TempoError.apiError(statusCode: httpResponse.statusCode)
            }

            let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
            return userInfo
        } catch let error as TempoError {
            throw error
        } catch {
            logger.error("fetchUserInfo network error: \(error.localizedDescription, privacy: .public)")
            throw TempoError.networkError
        }
    }

    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async throws -> Worklog? {
        // If accountId is provided and non-empty, use it directly without fetching user info
        if let accountId = accountId, !accountId.isEmpty {
            return try await fetchWorklog(apiToken: apiToken, jiraURL: jiraURL, identifier: accountId)
        }
        
        // Only fetch user info when accountId is not provided
        let userInfo = try await fetchUserInfo(apiToken: apiToken, jiraURL: jiraURL)
        
        let identifier = userInfo?.name ?? userInfo?.key ?? ""

        guard !identifier.isEmpty else {
            throw TempoError.missingCredentials
        }

        return try await fetchWorklog(apiToken: apiToken, jiraURL: jiraURL, identifier: identifier)
    }


    func testConnection(apiToken: String, accountId: String, jiraURL: String) async throws -> Worklog? {
        let userIdentifier = accountId.isEmpty ?
            (try await fetchUserInfo(apiToken: apiToken, jiraURL: jiraURL))?.name ?? "" : accountId

        guard !userIdentifier.isEmpty else {
            throw TempoError.missingCredentials
        }

        return try await fetchWorklog(apiToken: apiToken, jiraURL: jiraURL, identifier: userIdentifier)
    }

    private func fetchWorklog(apiToken: String, jiraURL: String, identifier: String) async throws -> Worklog? {
        let baseURL = jiraURL.hasSuffix("/") ? jiraURL : jiraURL + "/"
        let urlString = "\(baseURL)rest/tempo-timesheets/3/worklogs"

        guard let url = URL(string: urlString) else {
            throw TempoError.invalidURL
        }

        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) ?? endDate

        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "username", value: identifier),
            URLQueryItem(name: "dateFrom", value: TempoService.worklogDateFormatter.string(from: startDate)),
            URLQueryItem(name: "dateTo", value: TempoService.worklogDateFormatter.string(from: endDate))
        ]

        guard let finalURL = urlComponents.url else {
            throw TempoError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TempoError.networkError
            }

            if httpResponse.statusCode == 401 {
                throw TempoError.unauthorized
            } else if httpResponse.statusCode == 403 {
                throw TempoError.forbidden
            } else if httpResponse.statusCode != 200 {
                throw TempoError.apiError(statusCode: httpResponse.statusCode)
            }

            do {
                let worklogs = try JSONDecoder().decode([Worklog].self, from: data)
                return getMostRecentWorklog(worklogs)
            } catch {
                logger.warning("fetchWorklog: [Worklog] decode failed, falling back to WorklogResponse: \(error.localizedDescription, privacy: .public)")
                let worklogResponse = try JSONDecoder().decode(WorklogResponse.self, from: data)
                return getMostRecentWorklog(worklogResponse.results)
            }
        } catch let error as TempoError {
            throw error
        } catch {
            logger.error("fetchWorklog network error: \(error.localizedDescription, privacy: .public)")
            throw TempoError.networkError
        }
    }

    private func getMostRecentWorklog(_ worklogs: [Worklog]) -> Worklog? {
        guard !worklogs.isEmpty else { return nil }

        return worklogs.max { worklog1, worklog2 in
            guard let date1 = Worklog.parseDate(worklog1.started),
                  let date2 = Worklog.parseDate(worklog2.started) else {
                return false
            }
            return date1 < date2
        }
    }
}

enum TempoError: Error, LocalizedError {
    case missingCredentials
    case invalidURL
    case unauthorized
    case forbidden
    case networkError
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Missing API credentials"
        case .invalidURL:
            return "Invalid Jira URL"
        case .unauthorized:
            return "Unauthorized - check your API token"
        case .forbidden:
            return "Forbidden - check your account permissions"
        case .networkError:
            return "Network error - check your internet connection"
        case .apiError(let statusCode):
            return "API error (HTTP \(statusCode))"
        }
    }
}
