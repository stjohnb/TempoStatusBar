# Unit Testing Documentation

## Overview

This document describes the comprehensive unit testing implementation for the TempoStatusBarApp, specifically focusing on the `WorklogStateManager` class and related components.

## Test Coverage

### WorklogStateManager Tests

The test suite covers all major functionality of the `WorklogStateManager` class:

#### 1. Initial State Tests
- **`testInitialState()`**: Verifies that the state manager starts with correct default values
  - All state variables are nil or false
  - Warning threshold defaults to 7

#### 2. Credential Management Tests
- **`testCheckCredentialsAndRefresh_WithValidCredentials()`**: Tests successful credential loading and data refresh
- **`testCheckCredentialsAndRefresh_WithoutCredentials()`**: Tests behavior when no credentials are available
- **`testCheckCredentialsAndRefresh_CredentialLoadError()`**: Tests error handling during credential loading

#### 3. Data Loading Tests
- **`testLoadTempoData_Success()`**: Tests successful data fetching from Tempo API
- **`testLoadTempoData_NoCredentials()`**: Tests early return when no credentials are available
- **`testLoadTempoData_CredentialError()`**: Tests credential-related error handling
- **`testLoadTempoData_TempoError()`**: Tests Tempo API error handling
- **`testLoadTempoData_NetworkError()`**: Tests network error scenarios

#### 4. Computed Properties Tests
- **Status Emoji Tests**: Verify correct emoji display based on days since last worklog
  - ✅ for days within threshold
  - ⏰ for one day over threshold
  - 🚨 for multiple days over threshold
- **Status Color Tests**: Verify correct color coding
  - Green for within threshold
  - Orange for one day over
  - Red for multiple days over
- **Status Bar Title Tests**: Verify correct title formatting
- **Status Bar Tooltip Tests**: Verify correct tooltip text

#### 5. Error Handling Tests
- **`testErrorHandling_CredentialError()`**: Tests credential error message formatting
- **`testErrorHandling_TempoUnauthorizedError()`**: Tests Tempo API error message formatting
- **`testErrorHandling_GenericError()`**: Tests generic error handling

#### 6. State Management Tests
- **`testClearData()`**: Tests state clearing functionality
- **`testRefresh_TriggersDataLoad()`**: Tests manual refresh functionality

## Architecture Improvements for Testing

### Dependency Injection

The original architecture has been enhanced to support dependency injection for better testability:

#### Protocols Added
```swift
protocol CredentialManagerProtocol {
    func hasStoredCredentials() -> Bool
    func loadCredentials() throws -> CredentialManager.Credentials
}

protocol TempoServiceProtocol {
    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String?) async throws -> Worklog?
    func getDaysSinceLastWorklog(apiToken: String, jiraURL: String, accountId: String?) async -> Int?
}
```

#### Mock Classes
- **`MockCredentialManager`**: Simulates credential management for testing
- **`MockTempoService`**: Simulates Tempo API calls for testing

### Benefits of This Approach

1. **Isolation**: Tests run independently without external dependencies
2. **Speed**: No network calls or file system access during testing
3. **Reliability**: Tests are deterministic and repeatable
4. **Coverage**: Easy to test error scenarios and edge cases
5. **Maintainability**: Changes to external dependencies don't break tests

## Running the Tests

### Prerequisites

1. **Xcode**: Ensure you have Xcode 14.0 or later installed
2. **Test Target**: The project should have a test target configured

### Running Tests in Xcode

1. **Open the project** in Xcode
2. **Select the test target** in the scheme selector
3. **Press Cmd+U** or go to Product → Test
4. **View results** in the Test Navigator

### Running Tests from Command Line

```bash
# Navigate to project directory
cd /path/to/TempoStatusBarApp

# Run tests using xcodebuild
xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS'

# Run specific test class
xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS' -only-testing:TempoStatusBarAppTests/WorklogStateManagerTests
```

### Running Individual Tests

In Xcode, you can run individual tests by:
1. Clicking the diamond icon next to any test method
2. Right-clicking on a test method and selecting "Run Test"
3. Using the test navigator to run specific test cases

## Test Data and Mocking

### Mock Data Structure

The tests use realistic mock data that mirrors the actual API responses:

```swift
let credentials = CredentialManager.Credentials(
    apiToken: "test-token",
    accountId: "test-account",
    jiraURL: "https://test.atlassian.net",
    warningThreshold: 5
)

let worklog = Worklog(
    dateStarted: "2024-01-15T10:00:00.000",
    timeSpentSeconds: 3600,
    comment: "Test work",
    issue: WorklogIssue(key: "TEST-123", summary: "Test issue")
)
```

### Error Scenarios Tested

1. **Credential Errors**:
   - No stored credentials
   - Decoding failures
   - Invalid credential format

2. **Tempo API Errors**:
   - Unauthorized (401)
   - Forbidden (403)
   - Network errors
   - Invalid URLs

3. **Data Processing Errors**:
   - Invalid date formats
   - Missing required fields
   - Malformed JSON responses

## Continuous Integration

### GitHub Actions (Recommended)

Create `.github/workflows/test.yml`:

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Select Xcode
      run: sudo xcode-select -switch /Applications/Xcode.app
      
    - name: Run Tests
      run: xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS'
```

### Local CI Setup

For local continuous integration:

```bash
#!/bin/bash
# test.sh

set -e

echo "Running unit tests..."
xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS'

echo "Tests completed successfully!"
```

## Best Practices Implemented

### 1. Test Organization
- Tests are organized by functionality using MARK comments
- Each test method has a clear, descriptive name
- Tests follow the Given-When-Then pattern

### 2. Mock Management
- Mocks are created fresh for each test
- Mock state is reset between tests
- Mock behavior is predictable and controlled

### 3. Async Testing
- Proper handling of async/await operations
- Appropriate wait times for async operations
- Clear separation of sync and async test logic

### 4. Error Testing
- Comprehensive error scenario coverage
- Verification of error message content
- Testing of error state transitions

### 5. State Verification
- Verification of all relevant state changes
- Testing of computed properties
- Validation of side effects

## Future Testing Enhancements

### 1. Integration Tests
- Test actual API integration (with test credentials)
- Test file system operations
- Test UI state synchronization

### 2. Performance Tests
- Test memory usage patterns
- Test timer-based operations
- Test large data set handling

### 3. UI Tests
- Test status bar updates
- Test menu interactions
- Test settings view functionality

### 4. End-to-End Tests
- Test complete user workflows
- Test credential management flow
- Test error recovery scenarios

## Troubleshooting

### Common Issues

1. **Test Target Not Found**
   - Ensure the test target is properly configured in the Xcode project
   - Check that the test target includes the main app target as a dependency

2. **Import Errors**
   - Verify that `@testable import TempoStatusBarApp` is used
   - Check that the main target is properly configured for testing

3. **Async Test Failures**
   - Ensure proper wait times for async operations
   - Check that `@MainActor` is used where required
   - Verify that async operations complete before assertions

4. **Mock Injection Issues**
   - Ensure mock objects are properly injected before test execution
   - Check that mock protocols match the real implementations

### Debugging Tests

1. **Add breakpoints** in test methods to step through execution
2. **Use print statements** to debug mock behavior
3. **Check test console output** for detailed error messages
4. **Verify mock state** before and after operations

## Conclusion

The unit testing implementation provides comprehensive coverage of the `WorklogStateManager` class and demonstrates best practices for testing SwiftUI applications with dependency injection. The tests ensure that the architectural improvements are working correctly and provide a solid foundation for future development.

The testing approach balances thoroughness with maintainability, making it easy to add new tests as the application evolves while ensuring that existing functionality continues to work as expected. 