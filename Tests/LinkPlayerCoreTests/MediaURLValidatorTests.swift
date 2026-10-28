import XCTest
@testable import LinkPlayerCore

final class MediaURLValidatorTests: XCTestCase {

    let validator = MediaURLValidator(policy: .standard)

    // MARK: Happy paths

    func testAcceptsHTTPSLink() throws {
        let url = try validator.validatedURL(for: "https://example.com/video.mp4")
        XCTAssertEqual(url.absoluteString, "https://example.com/video.mp4")
    }

    func testAcceptsHTTPSLINKWithPortAndQuery() throws {
        _ = try validator.validatedURL(for: "https://media.example.com:8443/path/stream.m3u8?tag=12")
    }

    func testTrimsSurroundingWhitespace() throws {
        _ = try validator.validatedURL(for: "  \n https://example.com/v.mp4 \t ")
    }

    func testAcceptsHTTPLinkWhenPolicyAllows() throws {
        _ = try validator.validatedURL(for: "http://example.com/v.mp4")
    }

    func testAcceptsHLSManifest() throws {
        _ = try validator.validatedURL(for: "https://cdn.example.com/live/index.m3u8")
    }

    // MARK: Empty / malformed input

    func testRejectsEmptyInput() {
        assertFailure("", .emptyInput)
        assertFailure("   ", .emptyInput)
        assertFailure("\n\t ", .emptyInput)
    }

    func testRejectsPlainTextThatIsNotAURL() {
        assertFailure("hello world", .notAURL("hello world"))
        assertFailure("example.com/video.mp4", .notAURL("example.com/video.mp4"))
    }

    func testRejectsEmbeddedWhitespace() {
        if case .success = validator.validate("https://exa mple.com/v.mp4") {
            XCTFail("should reject whitespace inside URL")
        }
    }

    // MARK: Unsupported schemes

    func testRejectsFileScheme() {
        assertFailure("file:///Users/me/movie.mp4", .unsupportedScheme("file"))
    }

    func testRejectsJavaScriptScheme() {
        assertFailure("javascript:alert(1)", .unsupportedScheme("javascript"))
    }

    func testRejectsDataScheme() {
        if case .failure(.unsupportedScheme("data")) = validator.validate("data:text/html,<h1>hi") {}
        else { recordFailureIfNeeded("data:") }
    }

    func testRejectsArbitraryCustomSchemes() {
        assertFailure("vlc://https://example.com", .unsupportedScheme("vlc"))
        assertFailure("magnet:?xt=urn:btih:abc", .unsupportedScheme("magnet"))
        assertFailure("itms-apps://itunes.apple.com", .unsupportedScheme("itms-apps"))
    }

    func testSchemeMatchingIsCaseInsensitive() throws {
        _ = try validator.validatedURL(for: "HTTPS://example.com/v.mp4")
    }

    // MARK: HTTPS-only policy

    func testHTTPSOnlyPolicyRejectsHTTP() {
        let strict = MediaURLValidator(policy: .httpsOnly)
        switch strict.validate("http://example.com/v.mp4") {
        case .failure(.httpNotAllowed): break
        default: XCTFail("expected httpNotAllowed")
        }
        // https still fine
        XCTAssertNoThrow(try strict.validatedURL(for: "https://example.com/v.mp4"))
    }

    // MARK: Missing host

    func testRejectsURLWithoutHost() {
        switch validator.validate("https://") {
        case .failure(.missingHost), .failure(.notAURL(_)): break
        default: XCTFail("expected missingHost/notAURL, got \(resultDescription("https://"))")
        }
    }

    // MARK: Helpers

    private func assertFailure(_ input: String, _ expected: PlaybackError,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch validator.validate(input) {
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        case .success(let url):
            XCTFail("Expected \(expected) but accepted \(url)", file: file, line: line)
        }
    }

    private func recordFailureIfNeeded(_ scheme: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTFail("expected unsupportedScheme(\(scheme))", file: file, line: line)
    }

    private func resultDescription(_ input: String) -> String {
        switch validator.validate(input) {
        case .success: return "success"
        case .failure(let e): return "failure(\(e))"
        }
    }
}
