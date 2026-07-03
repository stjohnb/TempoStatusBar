import Foundation
import Network
import OSLog
import Security
import SwiftUI
import AppKit

// MARK: - Protocols for Dependency Injection

protocol CredentialManagerProtocol {
    func hasStoredCredentials() -> Bool
    func loadCredentials() throws -> CredentialManager.Credentials
}

protocol TempoServiceProtocol {
    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String?) async throws -> Worklog?
    func fetchUserInfo(apiToken: String, jiraURL: String) async throws -> UserInfo?
}

// MARK: - Centralized State Management

@MainActor
class WorklogStateManager: ObservableObject {
    static let shared = WorklogStateManager()

    @Published var daysSinceLastWorklog: Int?
    @Published var latestWorklog: Worklog?
    @Published var isLoading = false
    @Published var lastError: WorklogStateError?
    @Published var hasCredentials = false
    @Published var warningThreshold = 7

    var errorMessage: String? { lastError?.displayMessage }

    private var refreshTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var retryTask: Task<Void, Never>?
    private var lastErrorWasNetworkError = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "WorklogStateManager")

    var retryDelay: TimeInterval = 15

    // Dependency injection for testing
    var credentialManager: CredentialManagerProtocol = CredentialManager.shared
    var tempoService: TempoServiceProtocol = TempoService.shared

    init() {
        setupTimer()
        setupNetworkMonitor()
        checkCredentialsAndRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
        networkMonitor?.cancel()
        retryTask?.cancel()
    }

    // MARK: - Public Methods

    func refresh() {
        Task {
            await loadTempoData()
        }
    }

    func checkCredentialsAndRefresh() {
        do {
            let credentials = try credentialManager.loadCredentials()
            hasCredentials = true
            warningThreshold = credentials.warningThreshold
            Task {
                await loadTempoData(preloadedCredentials: credentials)
            }
        } catch CredentialError.noStoredCredentials {
            hasCredentials = false
            clearData()
        } catch let credentialError as CredentialError {
            logger.error("Failed to load credentials: \(credentialError.localizedDescription, privacy: .public)")
            hasCredentials = false
            clearData()
            lastError = mapCredentialError(credentialError)
        } catch {
            logger.error("Failed to load credentials: \(error.localizedDescription, privacy: .public)")
            hasCredentials = false
            clearData()
            lastError = .other(message: error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func mapCredentialError(_ error: CredentialError) -> WorklogStateError {
        switch error {
        case .noStoredCredentials:
            return .noCredentials
        case .decodingFailed(let underlyingError):
            return .credentialError(detail: underlyingError.localizedDescription)
        case .keychainError(let status):
            return .keychainError(status: status)
        }
    }

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let queue = DispatchQueue(label: "com.stjohnsoftware.TempoStatusBar.NetworkMonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            Task { @MainActor in
                guard self.hasCredentials, self.lastErrorWasNetworkError else { return }
                await self.loadTempoData()
            }
        }
        monitor.start(queue: queue)
    }

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
        lastError = nil
        warningThreshold = 7
    }

    func resetForTesting() {
        clearData()
        hasCredentials = false
        isLoading = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        retryTask?.cancel()
        retryTask = nil
        lastErrorWasNetworkError = false
    }

    func loadTempoData(preloadedCredentials: CredentialManager.Credentials? = nil) async {
        guard hasCredentials else { return }
        guard !isLoading else { return }

        isLoading = true
        lastError = nil

        do {
            let credentials = try preloadedCredentials ?? credentialManager.loadCredentials()

            // Fetch the actual worklog data
            let worklog = try await tempoService.fetchLatestWorklog(
                apiToken: credentials.apiToken,
                jiraURL: credentials.jiraURL,
                accountId: credentials.accountId.isEmpty ? nil : credentials.accountId
            )

            isLoading = false
            lastErrorWasNetworkError = false
            retryTask?.cancel()
            retryTask = nil
            latestWorklog = worklog
            daysSinceLastWorklog = worklog?.daysSinceStarted

        } catch {
            isLoading = false
            if let credentialError = error as? CredentialError {
                lastErrorWasNetworkError = false
                hasCredentials = false
                lastError = mapCredentialError(credentialError)
            } else if let tempoError = error as? TempoError {
                lastError = .tempo(tempoError)
                if case .networkError = tempoError {
                    lastErrorWasNetworkError = true
                    retryTask?.cancel()
                    retryTask = Task { [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await loadTempoData()
                    }
                } else {
                    lastErrorWasNetworkError = false
                }
            } else {
                lastErrorWasNetworkError = false
                lastError = .other(message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Computed Properties for Status Display

extension WorklogStateManager {
    private enum Severity {
        case ok, warning, overdue
    }

    private var severity: Severity? {
        guard let days = daysSinceLastWorklog else { return nil }
        if days <= warningThreshold {
            return .ok
        } else if days == warningThreshold + 1 {
            return .warning
        } else {
            return .overdue
        }
    }

    var statusEmoji: String {
        switch severity {
        case .ok: return "✅"
        case .warning: return "⏰"
        case .overdue: return "🚨"
        case nil: return ""
        }
    }

    var statusColor: Color {
        switch severity {
        case .ok: return .green
        case .warning: return .orange
        case .overdue: return .red
        case nil: return .secondary
        }
    }

    var statusBarColor: NSColor {
        switch severity {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .overdue: return .systemRed
        case nil: return .labelColor
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
    let name: String?
    let key: String?
    let emailAddress: String?
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
        try await performAuthorizedRequest(
            path: "rest/api/2/myself",
            queryItems: nil,
            apiToken: apiToken,
            jiraURL: jiraURL
        ) { data in
            try JSONDecoder().decode(UserInfo.self, from: data)
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

    private func fetchWorklog(apiToken: String, jiraURL: String, identifier: String) async throws -> Worklog? {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) ?? endDate

        let queryItems = [
            URLQueryItem(name: "username", value: identifier),
            URLQueryItem(name: "dateFrom", value: TempoService.worklogDateFormatter.string(from: startDate)),
            URLQueryItem(name: "dateTo", value: TempoService.worklogDateFormatter.string(from: endDate))
        ]

        return try await performAuthorizedRequest(
            path: "rest/tempo-timesheets/3/worklogs",
            queryItems: queryItems,
            apiToken: apiToken,
            jiraURL: jiraURL
        ) { data in
            do {
                let worklogs = try JSONDecoder().decode([Worklog].self, from: data)
                return self.getMostRecentWorklog(worklogs)
            } catch {
                self.logger.debug("fetchWorklog: response is wrapped format, decoding as WorklogResponse")
                let worklogResponse = try JSONDecoder().decode(WorklogResponse.self, from: data)
                return self.getMostRecentWorklog(worklogResponse.results)
            }
        }
    }

    private func performAuthorizedRequest<T>(
        path: String,
        queryItems: [URLQueryItem]?,
        apiToken: String,
        jiraURL: String,
        decoder: (Data) throws -> T
    ) async throws -> T {
        let baseURL = jiraURL.hasSuffix("/") ? jiraURL : jiraURL + "/"

        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw TempoError.invalidURL
        }

        let finalURL: URL
        if let queryItems {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw TempoError.invalidURL
            }
            components.queryItems = queryItems
            guard let queryURL = components.url else {
                throw TempoError.invalidURL
            }
            finalURL = queryURL
        } else {
            finalURL = url
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

            return try decoder(data)
        } catch let error as TempoError {
            throw error
        } catch {
            logger.error("network error at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

enum WorklogStateError: Equatable {
    case noCredentials
    case credentialError(detail: String)
    case keychainError(status: OSStatus)
    case tempo(TempoError)
    case other(message: String)

    var displayMessage: String {
        switch self {
        case .noCredentials:
            return "No credentials configured"
        case .credentialError(let detail):
            return "Credential error: \(detail)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .tempo(let error):
            return "Tempo error: \(error.localizedDescription)"
        case .other(let message):
            return "Error: \(message)"
        }
    }
}

enum TempoError: Error, LocalizedError, Equatable {
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
