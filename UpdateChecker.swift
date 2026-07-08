import Foundation
import OSLog

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum CheckResult {
        case upToDate(current: String)
        case updateAvailable(current: String, latest: String, releaseURL: URL)
        case skipped(reason: String)
        case failed(Error)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
        }
    }

    private static let skippedVersionKey = "TempoStatusBar.UpdateChecker.skippedVersion"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "UpdateChecker")

    var session: URLSession = .shared
    var currentVersionProvider: () -> String = { appVersion }

    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedVersionKey) }
    }

    private init() {}

    func checkForUpdates() async -> CheckResult {
        let current = currentVersionProvider()

        guard current != "unknown", Self.parseSemver(current) != nil else {
            return .skipped(reason: "current version '\(current)' is not a valid semver")
        }

        let url = URL(string: "https://api.github.com/repos/stjohnb/TempoStatusBar/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TempoStatusBar/\(current)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Update check transport error: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 404 {
                // Public repo: 404 means no published releases yet
                return .skipped(reason: "no published releases")
            }
            guard httpResponse.statusCode == 200 else {
                let err = URLError(.badServerResponse)
                logger.error("Update check HTTP \(httpResponse.statusCode, privacy: .public)")
                return .failed(err)
            }
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            logger.error("Update check decode error: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }

        let latest = release.tagName
        guard Self.parseSemver(latest) != nil else {
            logger.error("Update check: latest tag '\(latest, privacy: .public)' not parseable as semver")
            return .failed(URLError(.cannotParseResponse))
        }

        guard let releaseURL = URL(string: release.htmlUrl) else {
            logger.error("Update check: invalid release URL '\(release.htmlUrl, privacy: .public)'")
            return .failed(URLError(.cannotParseResponse))
        }

        let comparison = compare(current: current, latest: latest)
        if comparison == .orderedAscending {
            logger.info("Update available: \(current, privacy: .public) -> \(latest, privacy: .public)")
            return .updateAvailable(current: current, latest: latest, releaseURL: releaseURL)
        } else {
            logger.info("Up to date: \(current, privacy: .public)")
            return .upToDate(current: current)
        }
    }

    func compare(current: String, latest: String) -> ComparisonResult {
        guard let currentParts = Self.parseSemver(current), let latestParts = Self.parseSemver(latest) else {
            return .orderedSame
        }
        let maxLen = max(currentParts.count, latestParts.count)
        let paddedCurrent = currentParts + Array(repeating: 0, count: maxLen - currentParts.count)
        let paddedLatest = latestParts + Array(repeating: 0, count: maxLen - latestParts.count)
        for (currentVer, latestVer) in zip(paddedCurrent, paddedLatest) {
            if currentVer < latestVer { return .orderedAscending }
            if currentVer > latestVer { return .orderedDescending }
        }
        return .orderedSame
    }

    static func parseSemver(_ version: String) -> [Int]? {
        var str = version
        if str.hasPrefix("v") || str.hasPrefix("V") {
            str = String(str.dropFirst())
        }
        guard !str.isEmpty else { return nil }
        let parts = str.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let num = Int(part) else { return nil }
            result.append(num)
        }
        return result
    }
}
