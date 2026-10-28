import XCTest
@testable import LinkPlayerCore

final class MediaKindDetectorTests: XCTestCase {

    let detector = MediaKindDetector()

    func testMP4ByContentType() {
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://cdn.example.com/x")!,
                                       contentTypeHeader: "video/mp4"),
                       .progressiveVideo)
    }

    func testMP4WithCharsetStyleParameter() {
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://cdn.example.com/x")!,
                                       contentTypeHeader: "video/mp4; codecs=avc1.42E01E"),
                       .progressiveVideo)
    }

    func testQuickTime() {
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/a")!,
                                       contentTypeHeader: "video/quicktime"),
                       .progressiveVideo)
    }

    func testHLSByContentType() {
        for mime in ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl"] {
            XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/master")!,
                                           contentTypeHeader: mime),
                           .hlsStream, "for \(mime)")
        }
    }

    func testHLSByExtensionFallback() {
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/live/index.m3u8")!,
                                       contentTypeHeader: nil),
                       .hlsStream)
    }

    func testAudioTypes() {
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/s")!,
                                       contentTypeHeader: "audio/mpeg"), .audio)
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/s.mp3")!,
                                       contentTypeHeader: nil), .audio)
    }

    func testHTMLPageIsNotPlayable() {
        let kind = detector.detect(finalURL: URL(string: "https://youtube.com/watch?v=x")!,
                                   contentTypeHeader: "text/html; charset=utf-8")
        XCTAssertEqual(kind, .webPage)
        XCTAssertFalse(kind.isDirectlyPlayable)
    }

    func testOctetStreamFallsBackToExtension() {
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/film.mp4")!,
                                       contentTypeHeader: "application/octet-stream"),
                       .progressiveVideo)
        XCTAssertEqual(detector.detect(finalURL: URL(string: "https://e.com/film")!,
                                       contentTypeHeader: "application/octet-stream"),
                       .unknown)
    }

    func testUnknownWhenNothingMatches() {
        let kind = detector.detect(finalURL: URL(string: "https://e.com/api/status")!,
                                   contentTypeHeader: "application/json")
        XCTAssertEqual(kind, .unknown)
        XCTAssertFalse(kind.isDirectlyPlayable)
    }

    func testPlayableKindsFlag() {
        XCTAssertTrue(MediaKind.progressiveVideo.isDirectlyPlayable)
        XCTAssertTrue(MediaKind.hlsStream.isDirectlyPlayable)
        XCTAssertTrue(MediaKind.audio.isDirectlyPlayable)
        XCTAssertFalse(MediaKind.webPage.isDirectlyPlayable)
        XCTAssertFalse(MediaKind.unknown.isDirectlyPlayable)
    }

    func testRedirectedURLClassificationUsesFinalURL() {
        // Original link had no extension, final redirect target does.
        let final = URL(string: "https://cdn.other.net/store/video.mp4?region=eu")!
        XCTAssertEqual(detector.detect(finalURL: final, contentTypeHeader: nil),
                       .progressiveVideo)
    }
}
