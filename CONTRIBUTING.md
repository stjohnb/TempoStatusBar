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

## Forgejo Actions

The canonical repo is on Forgejo (`git.home.bstjohn.net/St-John-Software/TempoStatusBar`), and CI runs as Forgejo Actions workflows in `.forgejo/workflows/`. CI does not use `gh`; it talks to the Forgejo API with `curl`. See [docs/ci-cd.md](docs/ci-cd.md) for full details.

### PR Verification
- Runs on every PR to the main branch
- Verifies build and code quality
- Includes SwiftLint checks
- Performs security scanning with Trivy (fails only on CRITICAL findings with a fix available)
- Builds, signs and notarizes a DMG and uploads it to S3. The DMG is delivered as a raw `.dmg` (not zipped), which keeps its `com.apple.quarantine` origin consistent with tagged-release downloads and avoids macOS Keychain re-prompts.
- **Automatically posts a comment** on the PR with a direct download link to the DMG. The comment is updated on each subsequent push, so there is always a single comment pointing to the latest build.
- The PR's builds are deleted from S3 when the PR closes (merged or not).
- Fork PRs skip the sign/upload/comment steps because they get no secrets; contributors from forks should rebase their branch onto the upstream repo or build locally to test.

### Release Verification
- Runs when a release is published on Forgejo, and on manual dispatch
- Builds, signs and notarizes the release DMG
- Security scanning with Trivy
- Documentation validation
- Uploads the DMG to S3 and adds the download link to the release notes (the DMG is not a release asset)

## Release Process

1. **Create a release** on Forgejo with the title equal to the tag (e.g. `v1.3.0`)
2. **Add release notes** describing changes
3. **Publish** — CI builds the DMG and appends its download link to the release notes
4. **Wait for CI** to complete

Linux releases are cut automatically by bumping `version` in `linux/Cargo.toml`; the tarball and `.sha256` are attached to a `linux-vX.Y.Z` Forgejo release. Claws mirrors the latest release (both lines) to the public GitHub repo.

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
