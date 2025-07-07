#!/bin/bash

# TempoStatusBarApp Test Runner
# This script helps run unit tests and provides setup guidance

set -e

echo "🚀 TempoStatusBarApp Test Runner"
echo "=================================="

# Check if we're in the right directory
if [ ! -f "TempoStatusBarApp.xcodeproj/project.pbxproj" ]; then
    echo "❌ Error: Please run this script from the TempoStatusBarApp directory"
    echo "   Current directory: $(pwd)"
    echo "   Expected: Directory containing TempoStatusBarApp.xcodeproj"
    exit 1
fi

# Check if Xcode is available
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Error: xcodebuild not found. Please install Xcode."
    exit 1
fi

# Check if test files exist
if [ ! -f "WorklogStateManagerTests.swift" ]; then
    echo "❌ Error: WorklogStateManagerTests.swift not found"
    echo "   Please ensure the test files are in the project directory"
    exit 1
fi

if [ ! -f "TempoStatusBarAppTests.swift" ]; then
    echo "❌ Error: TempoStatusBarAppTests.swift not found"
    echo "   Please ensure the test files are in the project directory"
    exit 1
fi

echo "✅ Project structure looks good"
echo "✅ Test files found"
echo ""

# Try to run tests
echo "🔍 Attempting to run tests..."
echo ""

# First, try to build the project
echo "📦 Building project..."
if xcodebuild build -scheme TempoStatusBarApp -destination 'platform=macOS' > /dev/null 2>&1; then
    echo "✅ Project builds successfully"
else
    echo "⚠️  Project build failed or scheme not found"
    echo "   This might be expected if the test target isn't set up yet"
fi

echo ""

# Try to run tests
echo "🧪 Running tests..."
if xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS' 2>&1 | grep -q "Test Suite.*passed"; then
    echo "✅ Tests ran successfully!"
    echo ""
    echo "📊 Test Results:"
    xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS' 2>&1 | grep -E "(Test Suite|Test Case|passed|failed)" || true
else
    echo "❌ Tests failed to run or scheme not configured for testing"
    echo ""
    echo "🔧 Setup Required:"
    echo "   The test target needs to be configured in Xcode."
    echo "   Please follow the instructions in SETUP_TESTS.md"
    echo ""
    echo "📋 Quick Setup Steps:"
    echo "   1. Open TempoStatusBarApp.xcodeproj in Xcode"
    echo "   2. Add a new Unit Testing Bundle target named 'TempoStatusBarAppTests'"
    echo "   3. Add WorklogStateManagerTests.swift and TempoStatusBarAppTests.swift to the test target"
    echo "   4. Configure the scheme to include the test target"
    echo "   5. Run tests with Cmd+U in Xcode"
    echo ""
    echo "📖 For detailed instructions, see SETUP_TESTS.md"
fi

echo ""
echo "📚 Additional Resources:"
echo "   - SETUP_TESTS.md: Step-by-step test setup guide"
echo "   - TESTING.md: Comprehensive testing documentation"
echo "   - ARCHITECTURE_IMPROVEMENTS.md: Background on the architectural changes"
echo ""

# Check for test documentation
if [ -f "TESTING.md" ]; then
    echo "✅ Test documentation found"
else
    echo "⚠️  TESTING.md not found - check if documentation was created"
fi

if [ -f "SETUP_TESTS.md" ]; then
    echo "✅ Setup guide found"
else
    echo "⚠️  SETUP_TESTS.md not found - check if setup guide was created"
fi

echo ""
echo "🎯 Expected Test Coverage:"
echo "   - 25 test methods in WorklogStateManagerTests"
echo "   - Initial state validation"
echo "   - Credential management"
echo "   - Data loading scenarios"
echo "   - Computed properties"
echo "   - Error handling"
echo "   - State management"
echo ""

echo "✨ Test runner completed!" 