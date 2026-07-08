import XCTest
import SwiftUI
@testable import TempoStatusBarApp

@MainActor
final class WorklogStateManagerTests: XCTestCase {
    
    var stateManager: WorklogStateManager!
    var mockCredentialManager: MockCredentialManager!
    var mockTempoService: MockTempoService!
    
    override func setUp() {
        super.setUp()
        stateManager = WorklogStateManager.shared
        mockCredentialManager = MockCredentialManager()
        mockTempoService = MockTempoService()
        
        // Reset state manager for testing
        stateManager.resetForTesting()
        
        // Inject mocks
        stateManager.credentialManager = mockCredentialManager
        stateManager.tempoService = mockTempoService
    }
    
    override func tearDown() {
        stateManager = nil
        mockCredentialManager = nil
        mockTempoService = nil
        super.tearDown()
    }
    
    // MARK: - Initial State Tests
    
    func testInitialState() {
        XCTAssertNil(stateManager.daysSinceLastWorklog)
        XCTAssertNil(stateManager.latestWorklog)
        XCTAssertFalse(stateManager.isLoading)
        XCTAssertNil(stateManager.errorMessage)
        XCTAssertFalse(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 7)
    }
    
    // MARK: - Credential Management Tests
    
    func testCheckCredentialsAndRefresh_WithValidCredentials() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 5
        )
        mockCredentialManager.mockCredentials = credentials
        mockCredentialManager.hasCredentialsResult = true
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let worklog = Worklog(
            dateStarted: formatter.string(from: threeDaysAgo),
            timeSpentSeconds: 3600,
            comment: "Test work",
            issue: WorklogIssue(key: "TEST-123", summary: "Test issue")
        )
        mockTempoService.mockWorklog = worklog

        // When
        stateManager.checkCredentialsAndRefresh()

        // Wait for async operations
        await Task.sleep(100_000_000) // 0.1 seconds

        // Then
        XCTAssertTrue(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 5)
        XCTAssertEqual(stateManager.latestWorklog?.comment, "Test work")
        XCTAssertEqual(stateManager.daysSinceLastWorklog, 3)
        XCTAssertNil(stateManager.errorMessage)
        XCTAssertFalse(stateManager.isLoading)
    }
    
    func testCheckCredentialsAndRefresh_WithoutCredentials() {
        // Given
        mockCredentialManager.hasCredentialsResult = false
        
        // When
        stateManager.checkCredentialsAndRefresh()
        
        // Then
        XCTAssertFalse(stateManager.hasCredentials)
        XCTAssertNil(stateManager.daysSinceLastWorklog)
        XCTAssertNil(stateManager.latestWorklog)
        XCTAssertEqual(stateManager.warningThreshold, 7)
    }
    
    func testCheckCredentialsAndRefresh_CredentialLoadError() async {
        // Given
        mockCredentialManager.hasCredentialsResult = true
        mockCredentialManager.loadCredentialsError = CredentialError.decodingFailed(error: NSError(domain: "test", code: 1))

        // When
        stateManager.checkCredentialsAndRefresh()

        // Then: corrupt/unreadable credentials are treated as no usable credentials,
        // and an error message is surfaced so the user is not left with a silent failure.
        XCTAssertFalse(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 7) // Reset to default by clearData()
        XCTAssertNotNil(stateManager.errorMessage)
        XCTAssertTrue(stateManager.errorMessage?.contains("Credential error") == true)
    }

    func testCheckCredentialsAndRefresh_CredentialLoadError_NoStoredCredentials() {
        // Given: hasStoredCredentials() returns true but loadCredentials() throws
        // noStoredCredentials — e.g., one UserDefaults key is deleted between the two calls.
        mockCredentialManager.hasCredentialsResult = true
        mockCredentialManager.loadCredentialsError = CredentialError.noStoredCredentials

        // When
        stateManager.checkCredentialsAndRefresh()

        // Then
        XCTAssertFalse(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 7)
        XCTAssertNotNil(stateManager.errorMessage)
        XCTAssertTrue(stateManager.errorMessage?.contains("Credential error") == true)
    }
    
    // MARK: - Data Loading Tests
    
    func testLoadTempoData_Success() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        stateManager.hasCredentials = true
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let worklog = Worklog(
            dateStarted: formatter.string(from: twoDaysAgo),
            timeSpentSeconds: 7200,
            comment: "Development work",
            issue: WorklogIssue(key: "DEV-456", summary: "Development task")
        )
        mockTempoService.mockWorklog = worklog

        // When
        await stateManager.loadTempoData()

        // Then
        XCTAssertEqual(stateManager.latestWorklog?.comment, "Development work")
        XCTAssertEqual(stateManager.daysSinceLastWorklog, 2)
        XCTAssertNil(stateManager.errorMessage)
        XCTAssertFalse(stateManager.isLoading)
    }
    
    func testLoadTempoData_NoCredentials() async {
        // Given
        stateManager.hasCredentials = false
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertNil(stateManager.latestWorklog)
        XCTAssertNil(stateManager.daysSinceLastWorklog)
        XCTAssertFalse(stateManager.isLoading)
    }
    
    func testLoadTempoData_CredentialError() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockCredentialManager.loadCredentialsError = CredentialError.noStoredCredentials
        stateManager.hasCredentials = true
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertFalse(stateManager.isLoading)
        XCTAssertNotNil(stateManager.errorMessage)
        XCTAssertTrue(stateManager.errorMessage?.contains("No credentials configured") == true)
        XCTAssertFalse(stateManager.hasCredentials)
    }
    
    func testLoadTempoData_TempoError() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockTempoService.mockError = TempoError.unauthorized
        stateManager.hasCredentials = true
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertFalse(stateManager.isLoading)
        XCTAssertNotNil(stateManager.errorMessage)
        XCTAssertTrue(stateManager.errorMessage?.contains("Tempo error") == true)
    }
    
    func testLoadTempoData_NetworkError() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockTempoService.mockError = TempoError.networkError
        stateManager.hasCredentials = true
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertFalse(stateManager.isLoading)
        XCTAssertNotNil(stateManager.errorMessage)
        XCTAssertTrue(stateManager.errorMessage?.contains("Tempo error") == true)
    }
    
    // MARK: - Computed Properties Tests
    
    func testStatusEmoji_NoData() {
        // Given
        stateManager.daysSinceLastWorklog = nil
        
        // When & Then
        XCTAssertEqual(stateManager.statusEmoji, "")
    }
    
    func testStatusEmoji_WithinThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 5
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusEmoji, "✅")
    }
    
    func testStatusEmoji_AtThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 7
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusEmoji, "✅")
    }
    
    func testStatusEmoji_OneDayOverThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 8
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusEmoji, "⏰")
    }
    
    func testStatusEmoji_MultipleDaysOverThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 10
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusEmoji, "🚨")
    }
    
    func testStatusColor_NoData() {
        // Given
        stateManager.daysSinceLastWorklog = nil
        
        // When & Then
        XCTAssertEqual(stateManager.statusColor, .secondary)
    }
    
    func testStatusColor_WithinThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 5
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusColor, .green)
    }
    
    func testStatusColor_OneDayOverThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 8
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusColor, .orange)
    }
    
    func testStatusColor_MultipleDaysOverThreshold() {
        // Given
        stateManager.daysSinceLastWorklog = 10
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusColor, .red)
    }
    
    func testStatusBarTitle_NoData() {
        // Given
        stateManager.daysSinceLastWorklog = nil
        
        // When & Then
        XCTAssertEqual(stateManager.statusBarTitle, "⏱️")
    }
    
    func testStatusBarTitle_WithData() {
        // Given
        stateManager.daysSinceLastWorklog = 5
        stateManager.warningThreshold = 7
        
        // When & Then
        XCTAssertEqual(stateManager.statusBarTitle, "✅ 5")
    }
    
    func testStatusBarTooltip_NoData() {
        // Given
        stateManager.daysSinceLastWorklog = nil
        
        // When & Then
        XCTAssertEqual(stateManager.statusBarTooltip, "No worklog data available")
    }
    
    func testStatusBarTooltip_OneDay() {
        // Given
        stateManager.daysSinceLastWorklog = 1
        
        // When & Then
        XCTAssertEqual(stateManager.statusBarTooltip, "Last worklog: 1 day ago")
    }
    
    func testStatusBarTooltip_MultipleDays() {
        // Given
        stateManager.daysSinceLastWorklog = 5
        
        // When & Then
        XCTAssertEqual(stateManager.statusBarTooltip, "Last worklog: 5 days ago")
    }
    
    // MARK: - Refresh Tests
    
    func testRefresh_TriggersDataLoad() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        stateManager.hasCredentials = true
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let worklog = Worklog(
            dateStarted: formatter.string(from: yesterday),
            timeSpentSeconds: 3600,
            comment: "Test work",
            issue: WorklogIssue(key: "TEST-123", summary: "Test issue")
        )
        mockTempoService.mockWorklog = worklog

        // When
        stateManager.refresh()

        // Wait for async operations
        await Task.sleep(100_000_000) // 0.1 seconds

        // Then
        XCTAssertEqual(stateManager.latestWorklog?.comment, "Test work")
        XCTAssertEqual(stateManager.daysSinceLastWorklog, 1)
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorHandling_CredentialError() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockCredentialManager.loadCredentialsError = CredentialError.noStoredCredentials
        stateManager.hasCredentials = true
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertEqual(stateManager.errorMessage, "No credentials configured")
        XCTAssertFalse(stateManager.hasCredentials)
    }
    
    func testErrorHandling_TempoUnauthorizedError() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockTempoService.mockError = TempoError.unauthorized
        stateManager.hasCredentials = true
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertTrue(stateManager.errorMessage?.contains("Tempo error") == true)
        XCTAssertTrue(stateManager.errorMessage?.contains("Unauthorized") == true)
    }
    
    func testErrorHandling_GenericError() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockTempoService.mockError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        stateManager.hasCredentials = true
        
        // When
        await stateManager.loadTempoData()
        
        // Then
        XCTAssertTrue(stateManager.errorMessage?.contains("Error:") == true)
        XCTAssertTrue(stateManager.errorMessage?.contains("Test error") == true)
    }
    
    // MARK: - State Clearing Tests
    
    func testClearData() {
        // Given
        stateManager.daysSinceLastWorklog = 5
        stateManager.latestWorklog = Worklog(
            dateStarted: "2024-01-15T10:00:00.000",
            timeSpentSeconds: 3600,
            comment: "Test",
            issue: nil
        )
        stateManager.errorMessage = "Test error"
        stateManager.warningThreshold = 10
        
        // When
        stateManager.clearData()
        
        // Then
        XCTAssertNil(stateManager.daysSinceLastWorklog)
        XCTAssertNil(stateManager.latestWorklog)
        XCTAssertNil(stateManager.errorMessage)
        XCTAssertEqual(stateManager.warningThreshold, 7)
    }
}

// MARK: - Mock Classes

class MockCredentialManager: CredentialManagerProtocol {
    var mockCredentials: CredentialManager.Credentials?
    var hasCredentialsResult: Bool = false
    var loadCredentialsError: Error?
    
    func hasStoredCredentials() -> Bool {
        return hasCredentialsResult
    }
    
    func loadCredentials() throws -> CredentialManager.Credentials {
        if let error = loadCredentialsError {
            throw error
        }
        guard let credentials = mockCredentials else {
            throw CredentialError.noStoredCredentials
        }
        return credentials
    }
}

class MockTempoService: TempoServiceProtocol {
    var mockWorklog: Worklog?
    var mockError: Error?

    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async throws -> Worklog? {
        if let error = mockError {
            throw error
        }
        return mockWorklog
    }
}

// MARK: - CredentialManager.hasStoredCredentials() Tests

final class CredentialManagerHasStoredCredentialsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CredentialManager.shared.deleteCredentials()
    }

    override func tearDown() {
        CredentialManager.shared.deleteCredentials()
        super.tearDown()
    }

    func testHasStoredCredentials_NoCredentials_ReturnsFalse() {
        XCTAssertFalse(CredentialManager.shared.hasStoredCredentials())
    }

    func testHasStoredCredentials_AfterSave_ReturnsTrue() throws {
        try CredentialManager.shared.saveCredentials(
            apiToken: "token", accountId: "account", jiraURL: "https://jira.example.com"
        )
        XCTAssertTrue(CredentialManager.shared.hasStoredCredentials())
    }

    func testHasStoredCredentials_AfterDelete_ReturnsFalse() throws {
        try CredentialManager.shared.saveCredentials(
            apiToken: "token", accountId: "account", jiraURL: "https://jira.example.com"
        )
        CredentialManager.shared.deleteCredentials()
        XCTAssertFalse(CredentialManager.shared.hasStoredCredentials())
    }
}

// MARK: - Worklog.daysSinceStarted Tests

final class WorklogDaysSinceStartedTests: XCTestCase {

    private func makeWorklog(dateStarted: String) -> Worklog {
        Worklog(dateStarted: dateStarted, timeSpentSeconds: 3600, comment: nil, issue: nil)
    }

    func testDaysSinceStarted_Today_ReturnsZero() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let todayString = formatter.string(from: Date())

        XCTAssertEqual(makeWorklog(dateStarted: todayString).daysSinceStarted, 0)
    }

    func testDaysSinceStarted_NDaysAgo_ReturnsN() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let dateString = formatter.string(from: fiveDaysAgo)

        XCTAssertEqual(makeWorklog(dateStarted: dateString).daysSinceStarted, 5)
    }

    func testDaysSinceStarted_MalformedDate_ReturnsNil() {
        XCTAssertNil(makeWorklog(dateStarted: "not-a-date").daysSinceStarted)
    }

    func testDaysSinceStarted_DateWithTimezoneSuffix_ReturnsValidInt() {
        // ISO8601DateFormatter handles timezone suffixes; result should be a non-nil integer.
        let result = makeWorklog(dateStarted: "2024-01-15T10:00:00.000+00:00").daysSinceStarted
        XCTAssertNotNil(result)
    }

    func testDaysSinceStarted_FutureDate_ReturnsNil() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertNil(makeWorklog(dateStarted: formatter.string(from: tomorrow)).daysSinceStarted)
    }
}
