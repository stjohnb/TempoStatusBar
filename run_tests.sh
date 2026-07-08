#!/bin/bash

# TempoStatusBarApp Test Runner
# This script helps run unit tests and provides setup guidance

set -e
set -o pipefail

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
if [ ! -f "TempoStatusBarAppTests/WorklogStateManagerTests.swift" ]; then
    echo "❌ Error: WorklogStateManagerTests.swift not found in TempoStatusBarAppTests directory"
    echo "   Please ensure the test files are in the TempoStatusBarAppTests directory"
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
# Remove existing test results if they exist
rm -rf test-results.xcresult 2>/dev/null || true

if TEST_OUTPUT=$(xcodebuild test -scheme TempoStatusBarApp -destination 'platform=macOS' -resultBundlePath ./test-results.xcresult 2>&1); then
    echo "✅ Tests passed!"
    echo ""
    echo "📊 Test Results:"
    echo "$TEST_OUTPUT" | grep -E "(Test Suite|Test Case|passed|failed)" || true
    echo ""
    echo "📁 Test results saved to: test-results.xcresult"
    echo "🔍 Open test-results.xcresult in Xcode to view detailed results"
else
    echo "❌ Tests failed"
    echo ""
    echo "$TEST_OUTPUT" | grep -E "(Test Suite|Test Case|passed|failed|error:)" || true
    echo ""
    echo "🔧 Troubleshooting:"
    echo "   - Ensure Xcode is properly installed"
    echo "   - Check that the test target is configured correctly"
    echo "   - Verify that test files are included in the test target"
    echo ""
    echo "📖 For detailed instructions, see docs/OVERVIEW.md"
    exit 1
fi

echo ""
echo "📚 Additional Resources:"
echo "   - docs/OVERVIEW.md: Architecture, testing, and developer overview"
echo ""
echo "🎯 Test Coverage:"
echo "   - WorklogStateManagerTests: Comprehensive state management testing"
echo "   - Initial state validation"
echo "   - Credential management scenarios"
echo "   - Data loading and error handling"
echo "   - Computed properties (status emoji, color, tooltip)"
echo "   - State clearing and refresh functionality"
echo "   - Mock service integration"
echo ""

echo "✨ Test runner completed!" 