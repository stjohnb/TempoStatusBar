import XCTest
@testable import TempoStatusBarApp

@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: - parseSemver

    func testParseSemver_withVPrefix() {
        XCTAssertEqual(UpdateChecker.parseSemver("v1.2.3"), [1, 2, 3])
    }

    func testParseSemver_withoutPrefix() {
        XCTAssertEqual(UpdateChecker.parseSemver("1.0"), [1, 0])
    }

    func testParseSemver_withUppercaseVPrefix() {
        XCTAssertEqual(UpdateChecker.parseSemver("V2.0.0"), [2, 0, 0])
    }

    func testParseSemver_unknown_returnsNil() {
        XCTAssertNil(UpdateChecker.parseSemver("unknown"))
    }

    func testParseSemver_prereleaseSuffix_returnsNil() {
        XCTAssertNil(UpdateChecker.parseSemver("v1.2.3-beta"))
    }

    func testParseSemver_empty_returnsNil() {
        XCTAssertNil(UpdateChecker.parseSemver(""))
    }

    // MARK: - compare

    func testCompare_paddedVersionsAreEqual() {
        let checker = UpdateChecker.shared
        XCTAssertEqual(checker.compare(current: "1.2", latest: "1.2.0"), .orderedSame)
    }

    func testCompare_numericOrdering() {
        let checker = UpdateChecker.shared
        XCTAssertEqual(checker.compare(current: "1.2.3", latest: "1.2.10"), .orderedAscending)
    }

    func testCompare_currentNewer() {
        let checker = UpdateChecker.shared
        XCTAssertEqual(checker.compare(current: "1.10.0", latest: "1.9.5"), .orderedDescending)
    }

    func testCompare_equal() {
        let checker = UpdateChecker.shared
        XCTAssertEqual(checker.compare(current: "1.0.0", latest: "1.0.0"), .orderedSame)
    }

    // MARK: - checkForUpdates skipped path

    func testCheckForUpdates_unknownVersion_returnsSkipped() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "unknown" }
        defer { checker.currentVersionProvider = { appVersion } }

        let result = await checker.checkForUpdates()
        if case .skipped = result {
            // expected
        } else {
            XCTFail("Expected .skipped, got \(result)")
        }
    }

    // MARK: - checkForUpdates network paths

    private func makeSession(handler: @escaping MockURLProtocol.Handler) -> URLSession {
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testCheckForUpdates_404_returnsSkipped() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        checker.session = makeSession { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .skipped = result {
            // expected
        } else {
            XCTFail("Expected .skipped, got \(result)")
        }
    }

    func testCheckForUpdates_newerTag_returnsUpdateAvailable() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        let json = #"{"tag_name":"v1.1.0","html_url":"https://github.com/releases/tag/v1.1.0"}"#
        checker.session = makeSession { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .updateAvailable(let current, let latest, _) = result {
            XCTAssertEqual(current, "1.0.0")
            XCTAssertEqual(latest, "v1.1.0")
        } else {
            XCTFail("Expected .updateAvailable, got \(result)")
        }
    }

    func testCheckForUpdates_sameTag_returnsUpToDate() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        let json = #"{"tag_name":"v1.0.0","html_url":"https://github.com/releases/tag/v1.0.0"}"#
        checker.session = makeSession { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .upToDate = result {
            // expected
        } else {
            XCTFail("Expected .upToDate, got \(result)")
        }
    }

    func testCheckForUpdates_non200_returnsFailed() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        checker.session = makeSession { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .failed = result {
            // expected
        } else {
            XCTFail("Expected .failed, got \(result)")
        }
    }

    func testCheckForUpdates_transportError_returnsFailed() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        checker.session = makeSession { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .failed = result {
            // expected
        } else {
            XCTFail("Expected .failed, got \(result)")
        }
    }

    func testCheckForUpdates_malformedJSON_returnsFailed() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        checker.session = makeSession { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return ("not json".data(using: .utf8)!, response)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .failed = result {
            // expected
        } else {
            XCTFail("Expected .failed, got \(result)")
        }
    }

    func testCheckForUpdates_401_returnsFailed() async {
        let checker = UpdateChecker.shared
        checker.currentVersionProvider = { "1.0.0" }
        checker.session = makeSession { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        defer {
            checker.currentVersionProvider = { appVersion }
            checker.session = .shared
        }

        let result = await checker.checkForUpdates()
        if case .failed = result {
            // expected
        } else {
            XCTFail("Expected .failed on HTTP 401, got \(result)")
        }
    }
}

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, URLResponse)
    static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
