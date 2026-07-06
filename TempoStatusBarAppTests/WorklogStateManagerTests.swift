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
        stateManager.retryDelay = 0.05

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
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let threeDaysAgo = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        )
        let worklog = Worklog(
            dateStarted: isoFormatter.string(from: threeDaysAgo),
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

    func testCheckCredentialsAndRefresh_KeychainError() {
        // Given
        mockCredentialManager.hasCredentialsResult = true
        mockCredentialManager.loadCredentialsError = CredentialError.keychainError(status: -25293)

        // When
        stateManager.checkCredentialsAndRefresh()

        // Then
        XCTAssertFalse(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 7) // Reset to default by clearData()
        XCTAssertEqual(stateManager.lastError, .keychainError(status: -25293))
    }

    func testCheckCredentialsAndRefresh_CredentialLoadError_NoStoredCredentials() {
        // Given: loadCredentials() throws noStoredCredentials
        mockCredentialManager.loadCredentialsError = CredentialError.noStoredCredentials

        // When
        stateManager.checkCredentialsAndRefresh()

        // Then: noStoredCredentials is treated as the "no credentials" branch — no error surfaced
        XCTAssertFalse(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 7)
        XCTAssertNil(stateManager.errorMessage)
    }
    
    func testCheckCredentialsAndRefresh_LoadsCredentialsOnce() async {
        // Given
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 5
        )
        mockCredentialManager.mockCredentials = credentials
        mockCredentialManager.hasCredentialsResult = true
        mockTempoService.mockWorklog = nil

        // When
        stateManager.checkCredentialsAndRefresh()
        await Task.sleep(100_000_000) // 0.1 seconds — let the spawned Task complete

        // Then: loadCredentials() must be called exactly once (not again inside loadTempoData)
        XCTAssertEqual(mockCredentialManager.loadCredentialsCallCount, 1)
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
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let twoDaysAgo = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        )
        let worklog = Worklog(
            dateStarted: isoFormatter.string(from: twoDaysAgo),
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
        XCTAssertEqual(stateManager.lastError, .noCredentials)
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
        XCTAssertEqual(stateManager.lastError, .tempo(.unauthorized))
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

        // Then: initial error state
        XCTAssertFalse(stateManager.isLoading)
        XCTAssertEqual(stateManager.lastError, .tempo(.networkError))

        // Simulate network recovery: provide a valid worklog and clear the error
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        mockTempoService.mockError = nil
        mockTempoService.mockWorklog = Worklog(
            dateStarted: formatter.string(from: twoDaysAgo),
            timeSpentSeconds: 3600,
            comment: "Retry success",
            issue: nil
        )

        // Wait for the retry task to fire (retryDelay = 0.05s)
        await Task.sleep(100_000_000) // 0.1 seconds

        // Then: retry should have succeeded
        XCTAssertNil(stateManager.errorMessage)
        XCTAssertNotNil(stateManager.daysSinceLastWorklog)
    }

    func testLoadTempoData_NonNetworkError_DoesNotRetry() async {
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

        // Wait past the retry window
        await Task.sleep(100_000_000) // 0.1 seconds

        // Then: error should persist unchanged (no silent retry)
        XCTAssertEqual(stateManager.lastError, .tempo(.unauthorized))
    }

    func testResetForTesting_CancelsRetryTask() async {
        // Given: trigger a network error to start a retry task
        let credentials = CredentialManager.Credentials(
            apiToken: "test-token",
            accountId: "test-account",
            jiraURL: "https://test.atlassian.net",
            warningThreshold: 7
        )
        mockCredentialManager.mockCredentials = credentials
        mockTempoService.mockError = TempoError.networkError
        stateManager.hasCredentials = true
        await stateManager.loadTempoData()

        // Reset before retry fires
        stateManager.resetForTesting()
        stateManager.credentialManager = mockCredentialManager
        stateManager.tempoService = mockTempoService
        stateManager.retryDelay = 0.05

        let callCountBeforeWindow = mockTempoService.fetchCallCount

        // Wait past the original retry window
        await Task.sleep(100_000_000) // 0.1 seconds

        // Then: cancelled retry task must not have incremented the call count
        XCTAssertEqual(mockTempoService.fetchCallCount, callCountBeforeWindow)
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
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let yesterday = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        let worklog = Worklog(
            dateStarted: isoFormatter.string(from: yesterday),
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
        XCTAssertEqual(stateManager.lastError, .tempo(.unauthorized))
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
        XCTAssertEqual(stateManager.lastError, .other(message: "Test error"))
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
        stateManager.lastError = .other(message: "Test error")
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
    var loadCredentialsCallCount = 0

    func hasStoredCredentials() -> Bool {
        return hasCredentialsResult
    }

    func loadCredentials() throws -> CredentialManager.Credentials {
        loadCredentialsCallCount += 1
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
    var fetchCallCount = 0
    var mockUserInfo: UserInfo?
    var fetchUserInfoError: Error?
    var fetchUserInfoCallCount = 0

    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async throws -> Worklog? {
        fetchCallCount += 1
        if let error = mockError {
            throw error
        }
        return mockWorklog
    }

    func fetchUserInfo(apiToken: String, jiraURL: String) async throws -> UserInfo? {
        fetchUserInfoCallCount += 1
        if let error = fetchUserInfoError {
            throw error
        }
        return mockUserInfo
    }
}

// MARK: - runConnectionTest Tests

final class ConnectionTestTests: XCTestCase {

    func testAccountIdMismatch_ReturnsWarning_SkipsWorklogFetch() async {
        let service = MockTempoService()
        service.mockUserInfo = UserInfo(name: "alice", key: "alice", emailAddress: nil)

        let result = await runConnectionTest(
            apiToken: "token", accountId: "bob", jiraURL: "https://jira.example.com",
            service: service
        )

        XCTAssert(result.contains("⚠️"), "Expected warning emoji in result: \(result)")
        XCTAssertEqual(service.fetchCallCount, 0, "Worklog fetch should be skipped on mismatch")
    }

    func testAccountIdMatchesCaseInsensitively_ProceedsToWorklogFetch() async {
        let service = MockTempoService()
        service.mockUserInfo = UserInfo(name: "Alice", key: nil, emailAddress: nil)

        let result = await runConnectionTest(
            apiToken: "token", accountId: "alice", jiraURL: "https://jira.example.com",
            service: service
        )

        XCTAssert(result.contains("✅"), "Expected success in result: \(result)")
        XCTAssertEqual(service.fetchCallCount, 1, "Worklog fetch should proceed when IDs match case-insensitively")
    }

    func testAccountIdMatchesViaKeyOnly_ProceedsToWorklogFetch() async {
        let service = MockTempoService()
        service.mockUserInfo = UserInfo(name: nil, key: "Alice", emailAddress: nil)

        let result = await runConnectionTest(
            apiToken: "token", accountId: "alice", jiraURL: "https://jira.example.com",
            service: service
        )

        XCTAssert(result.contains("✅"), "Expected success when accountId matches key: \(result)")
        XCTAssertEqual(service.fetchCallCount, 1, "Worklog fetch should proceed when accountId matches key")
    }

    func testBothIdentityFieldsNil_SkipsIdentityCheck_ProceedsToWorklogFetch() async {
        let service = MockTempoService()
        service.mockUserInfo = UserInfo(name: nil, key: nil, emailAddress: nil)

        let result = await runConnectionTest(
            apiToken: "token", accountId: "someaccount", jiraURL: "https://jira.example.com",
            service: service
        )

        XCTAssert(result.contains("✅"), "Expected success in result: \(result)")
        XCTAssertEqual(service.fetchCallCount, 1, "Worklog fetch should proceed when server returns no identity fields")
    }

    func testFetchUserInfoThrows_ReturnsError_SkipsWorklogFetch() async {
        let service = MockTempoService()
        service.fetchUserInfoError = TempoError.unauthorized

        let result = await runConnectionTest(
            apiToken: "token", accountId: "someaccount", jiraURL: "https://jira.example.com",
            service: service
        )

        XCTAssert(result.contains("❌"), "Expected error in result: \(result)")
        XCTAssertEqual(service.fetchCallCount, 0, "Worklog fetch should be skipped when user info fetch fails")
    }

    func testEmptyAccountId_SkipsIdentityCheck_ProceedsToWorklogFetch() async {
        let service = MockTempoService()
        // fetchUserInfo should never be called when accountId is empty
        service.fetchUserInfoError = TempoError.unauthorized

        let result = await runConnectionTest(
            apiToken: "token", accountId: "", jiraURL: "https://jira.example.com",
            service: service
        )

        XCTAssert(result.contains("✅"), "Expected success when accountId is empty: \(result)")
        XCTAssertEqual(service.fetchUserInfoCallCount, 0, "fetchUserInfo should be skipped when accountId is empty")
        XCTAssertEqual(service.fetchCallCount, 1, "Worklog fetch should proceed directly when accountId is empty")
    }
}

// MARK: - CredentialManager.hasStoredCredentials() Tests

final class CredentialManagerHasStoredCredentialsTests: XCTestCase {
    // This suite exercises the REAL keychain via CredentialManager.shared —
    // including deleteCredentials() against the production service name in
    // setUp/tearDown. On the shared self-hosted CI Macs the runner user's
    // keychain holds genuine credentials and headless keychain access blocks
    // on authorization dialogs, so CI sets TEMPO_SKIP_KEYCHAIN_TESTS=1 and the
    // whole suite is skipped there. The skip must happen BEFORE setUp touches
    // the keychain, hence setUpWithError.
    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["TEMPO_SKIP_KEYCHAIN_TESTS"] == "1",
            "Real-keychain tests are skipped on self-hosted CI runners"
        )
        CredentialManager.shared.deleteCredentials()
    }

    override func tearDown() {
        // tearDown still runs when setUpWithError skips — keep it away from the
        // real keychain under the same gate.
        if ProcessInfo.processInfo.environment["TEMPO_SKIP_KEYCHAIN_TESTS"] != "1" {
            CredentialManager.shared.deleteCredentials()
        }
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
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let today = Calendar.current.startOfDay(for: Date())
        let todayString = isoFormatter.string(from: today)

        XCTAssertEqual(makeWorklog(dateStarted: todayString).daysSinceStarted, 0)
    }

    func testDaysSinceStarted_NDaysAgo_ReturnsN() {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Use local midnight 5 days ago so Calendar.current always sees an exact
        // 5-day span regardless of what time of day the test runs.
        let fiveDaysAgo = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        )
        let dateString = isoFormatter.string(from: fiveDaysAgo)

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
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Use +2 days: dateComponents([.day]) rounds toward zero, so a delta of
        // -23.999h (from time drift between Date() calls) truncates to 0, not -1,
        // and the nil-on-negative check would silently pass.
        let future = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        XCTAssertNil(makeWorklog(dateStarted: isoFormatter.string(from: future)).daysSinceStarted)
    }
}
