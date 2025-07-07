# Setting Up Unit Tests in Xcode

## Prerequisites

1. **Xcode 14.0 or later** installed on your Mac
2. **TempoStatusBarApp project** opened in Xcode

## Step-by-Step Setup

### 1. Create Test Target

1. **Open Xcode** and load the `TempoStatusBarApp.xcodeproj` file
2. **Select the project** in the navigator (top-level item)
3. **Click the "+" button** at the bottom of the targets list
4. **Choose "New Target"**
5. **Select "Unit Testing Bundle"** under macOS
6. **Name it** `TempoStatusBarAppTests`
7. **Click "Finish"**

### 2. Add Test Files

1. **Right-click** on the `TempoStatusBarAppTests` group in the navigator
2. **Select "Add Files to TempoStatusBarAppTests"**
3. **Add the following files**:
   - `WorklogStateManagerTests.swift`
   - `TempoStatusBarAppTests.swift`

### 3. Configure Test Target

1. **Select the test target** (`TempoStatusBarAppTests`) in the project navigator
2. **Look for the "Build Phases" tab** in the editor area (it may be alongside "General", "Signing & Capabilities", "Build Settings", etc.)
3. **If you don't see tabs, try selecting the project name first, then the test target**
4. **Expand "Compile Sources"** in the Build Phases section
5. **Verify** that both test files are listed
6. **Go to "Build Settings"** tab
7. **Search for "Test Host"**
8. **Set "Test Host"** to `$(BUILT_PRODUCTS_DIR)/TempoStatusBarApp.app/Contents/MacOS/TempoStatusBarApp`

### 4. Configure Scheme

1. **Click on the scheme selector** (next to the play/stop buttons)
2. **Select "Edit Scheme"**
3. **Select "Test"** from the left sidebar
4. **Click the "+" button** under "Info"
5. **Select "TempoStatusBarAppTests"**
6. **Click "Close"**

## Running Tests

### Option 1: Xcode UI

1. **Select the test target** in the scheme selector
2. **Press Cmd+U** or go to **Product → Test**
3. **View results** in the Test Navigator (Cmd+6)

### Option 2: Command Line

```bash
# Navigate to project directory
cd /path/to/TempoStatusBarApp

# Run all tests
xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS'

# Run specific test class
xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS' -only-testing:TempoStatusBarAppTests/WorklogStateManagerTests

# Run specific test method
xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS' -only-testing:TempoStatusBarAppTests/WorklogStateManagerTests/testInitialState
```

## Expected Test Results

After setup, you should see **25 test methods** in the `WorklogStateManagerTests` class:

### Initial State Tests (1 test)
- ✅ `testInitialState`

### Credential Management Tests (3 tests)
- ✅ `testCheckCredentialsAndRefresh_WithValidCredentials`
- ✅ `testCheckCredentialsAndRefresh_WithoutCredentials`
- ✅ `testCheckCredentialsAndRefresh_CredentialLoadError`

### Data Loading Tests (5 tests)
- ✅ `testLoadTempoData_Success`
- ✅ `testLoadTempoData_NoCredentials`
- ✅ `testLoadTempoData_CredentialError`
- ✅ `testLoadTempoData_TempoError`
- ✅ `testLoadTempoData_NetworkError`

### Computed Properties Tests (12 tests)
- ✅ `testStatusEmoji_NoData`
- ✅ `testStatusEmoji_WithinThreshold`
- ✅ `testStatusEmoji_AtThreshold`
- ✅ `testStatusEmoji_OneDayOverThreshold`
- ✅ `testStatusEmoji_MultipleDaysOverThreshold`
- ✅ `testStatusColor_NoData`
- ✅ `testStatusColor_WithinThreshold`
- ✅ `testStatusColor_OneDayOverThreshold`
- ✅ `testStatusColor_MultipleDaysOverThreshold`
- ✅ `testStatusBarTitle_NoData`
- ✅ `testStatusBarTitle_WithData`
- ✅ `testStatusBarTooltip_NoData`
- ✅ `testStatusBarTooltip_OneDay`
- ✅ `testStatusBarTooltip_MultipleDays`

### Error Handling Tests (3 tests)
- ✅ `testErrorHandling_CredentialError`
- ✅ `testErrorHandling_TempoUnauthorizedError`
- ✅ `testErrorHandling_GenericError`

### State Management Tests (2 tests)
- ✅ `testClearData`
- ✅ `testRefresh_TriggersDataLoad`

## Troubleshooting

### Common Issues

1. **"Can't find Build Phases"**
   - Make sure you've selected the test target (`TempoStatusBarAppTests`), not the project
   - Look for tabs in the editor area: "General", "Signing & Capabilities", "Build Settings", "Build Phases"
   - If you don't see tabs, try selecting the project name first, then the test target
   - In newer Xcode versions, Build Phases might be in a different location - look for it in the target configuration

2. **"No such module 'TempoStatusBarApp'"**
   - Ensure the test target has the main app target as a dependency
   - Check that `@testable import TempoStatusBarApp` is used in test files

3. **"Test target not found"**
   - Verify the test target is properly added to the scheme
   - Check that the test target is included in the project

4. **"Build failed"**
   - Check that all required files are added to the test target
   - Verify that the main app target builds successfully

5. **"Async test failures"**
   - Ensure proper wait times for async operations
   - Check that `@MainActor` is used where required

### Debugging Tests

1. **Add breakpoints** in test methods
2. **Use print statements** to debug mock behavior
3. **Check test console output** for detailed error messages
4. **Verify mock state** before and after operations

## Test Architecture

The tests use a **dependency injection** pattern with protocols:

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

### Mock Classes

- **`MockCredentialManager`**: Simulates credential management
- **`MockTempoService`**: Simulates Tempo API calls

### Benefits

1. **Isolation**: Tests run without external dependencies
2. **Speed**: No network calls during testing
3. **Reliability**: Deterministic and repeatable
4. **Coverage**: Easy to test error scenarios

## Continuous Integration

Once tests are set up, you can integrate them into your CI/CD pipeline:

### GitHub Actions Example

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

## Next Steps

After setting up the test target:

1. **Run all tests** to verify they pass
2. **Add more tests** for other components as needed
3. **Set up CI/CD** integration
4. **Add performance tests** for critical paths
5. **Consider UI tests** for end-to-end validation

## Support

If you encounter issues during setup:

1. **Check the troubleshooting section** above
2. **Verify Xcode version** compatibility
3. **Ensure all files** are properly added to the test target
4. **Check build settings** for the test target
5. **Review the test documentation** in `TESTING.md` 