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
        stateManager = WorklogStateManager()
        mockCredentialManager = MockCredentialManager()
        mockTempoService = MockTempoService()
        
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
        
        let worklog = Worklog(
            dateStarted: "2024-01-15T10:00:00.000",
            timeSpentSeconds: 3600,
            comment: "Test work",
            issue: WorklogIssue(key: "TEST-123", summary: "Test issue")
        )
        mockTempoService.mockWorklog = worklog
        mockTempoService.mockDaysSinceLastWorklog = 3
        
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
        
        // Wait for async operations
        await Task.sleep(100_000_000) // 0.1 seconds
        
        // Then
        XCTAssertTrue(stateManager.hasCredentials)
        XCTAssertEqual(stateManager.warningThreshold, 7) // Default value
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
        
        let worklog = Worklog(
            dateStarted: "2024-01-15T10:00:00.000",
            timeSpentSeconds: 7200,
            comment: "Development work",
            issue: WorklogIssue(key: "DEV-456", summary: "Development task")
        )
        mockTempoService.mockWorklog = worklog
        mockTempoService.mockDaysSinceLastWorklog = 2
        
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
        
        let worklog = Worklog(
            dateStarted: "2024-01-15T10:00:00.000",
            timeSpentSeconds: 3600,
            comment: "Test work",
            issue: WorklogIssue(key: "TEST-123", summary: "Test issue")
        )
        mockTempoService.mockWorklog = worklog
        mockTempoService.mockDaysSinceLastWorklog = 1
        
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
    var mockDaysSinceLastWorklog: Int?
    var mockError: Error?
    
    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async throws -> Worklog? {
        if let error = mockError {
            throw error
        }
        return mockWorklog
    }
    
    func getDaysSinceLastWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async -> Int? {
        if let error = mockError {
            return nil
        }
        return mockDaysSinceLastWorklog
    }
} 