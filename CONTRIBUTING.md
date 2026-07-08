# Contributing to TempoStatusBarApp

Thank you for your interest in contributing to TempoStatusBarApp! This document provides guidelines and information for contributors.

## Development Setup

### Prerequisites
- macOS 12.0 or later
- Xcode 15.0 or later
- Git

### Getting Started
1. Fork the repository
2. Clone your fork locally
3. Open `TempoStatusBarApp.xcodeproj` in Xcode
4. Build and run the project

## Code Style Guidelines

### Swift
- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and concise
- Use SwiftLint for code style consistency

### SwiftUI
- Use semantic color names
- Implement proper accessibility labels
- Follow SwiftUI best practices for state management
- Use appropriate view modifiers

## Security Guidelines

### Credential Management
- **Never** hardcode credentials in source code
- Use macOS Keychain for secure storage
- Follow the existing `CredentialManager` pattern
- Validate all user inputs

### Data Handling
- Sanitize all API responses
- Handle errors gracefully
- Log sensitive information appropriately
- Follow Apple's privacy guidelines

## Testing

### Local Testing
- Test on macOS 12.0+ (minimum supported version)
- Verify credential management works correctly
- Test with both valid and invalid API responses
- Check that the status bar updates properly

### Build Verification
- Ensure the project builds in both Debug and Release configurations
- Verify no warnings are generated
- Test the app archive process

## Pull Request Process

1. **Create a feature branch** from `main`
2. **Make your changes** following the guidelines above
3. **Test thoroughly** on your local machine
4. **Update documentation** if necessary
5. **Submit a PR** using the provided template
6. **Wait for review** and address any feedback

### PR Requirements
- All CI checks must pass
- Code must follow style guidelines
- No TODO/FIXME comments should remain
- Documentation must be updated if needed
- Security considerations must be addressed

## GitHub Actions

The project uses several GitHub Actions workflows:

### PR Verification
- Runs on every PR to the main branch
- Verifies build and code quality
- Includes SwiftLint checks
- Performs security scanning with Trivy
- Creates DMG artifacts for testing

### Release Verification
- Runs on pushes to main branch and manual dispatch
- Builds release artifacts
- Security scanning with Trivy
- Documentation validation
- Creates DMG distribution files

## Release Process

1. **Create a release** on GitHub
2. **Add release notes** describing changes
3. **Tag the release** with semantic versioning
4. **Wait for CI** to complete
5. **Download artifacts** from the release

## Getting Help

- Check existing issues for similar problems
- Review the README.md for setup instructions
- Open an issue for bugs or feature requests
- Ask questions in discussions

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow
- Follow the project's coding standards

Thank you for contributing to TempoStatusBarApp! 
