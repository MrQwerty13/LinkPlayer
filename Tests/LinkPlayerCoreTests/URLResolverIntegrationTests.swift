import XCTest
@testable import LinkPlayerCore

/// Integration-style tests over the *real* HTTPURLResolver against a local
/// HTTP server (python3 http.server) — no external network dependency.
final class URLResolverIntegrationTests: XCTestCase {

    static var serverProcess: Process?
    static var port: Int = 0
    static var serverReady = false

    override class func setUp() {
        super.setUp()
        guard !serverReady else { return }
        // Launch a tiny scripted HTTP server with controllable responses.
        let script = """
        import http.server, socketserver, threading, sys

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _routes(self):
                p = self.path
                if p == '/movie.mp4':
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp4')
                    self.send_header('Content-Length', '4')
                    self.end_headers()
                    self.wfile.write(b'FAKE')
                elif p == '/page.html':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                    self.send_header('Content-Length', '13')
                    self.end_headers()
                    self.wfile.write(b'<h1>Hello</h1>')
                elif p == '/stream.m3u8':
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                    self.send_header('Content-Length', '8')
                    self.end_headers()
                    self.wfile.write(b'#EXTM3U\\n')
                elif p == '/redirect-to-media':
                    self.send_response(302)
                    self.send_header('Location', f'http://127.0.0.1:{Handler.port}/movie.mp4')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                elif p == '/gone.mp4':
                    self.send_response(404)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                elif p == '/private.mp4':
                    self.send_response(403)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                elif p == '/nohead':
                    if self.command == 'HEAD':
                        self.send_response(405)
                        self.send_header('Content-Length', '0')
                        self.end_headers()
                    else:
                        self.send_response(200)
                        self.send_header('Content-Type', 'video/quicktime')
                        self.send_header('Content-Length', '2')
                        self.end_headers()
                        self.wfile.write(b'QT')
                elif p == '/octet.mp4':
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', '1')
                    self.end_headers()
                    self.wfile.write(b'x')
                else:
                    self.send_response(418)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
            do_GET = _routes
            do_HEAD = _routes

        def main():
            socketserver.TCPServer.allow_reuse_address = True
            with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
                Handler.port = httpd.server_address[1]
                print(httpd.server_address[1], flush=True)
                httpd.serve_forever()

        main()
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // silence
        do {
            try proc.run()
            serverProcess = proc
            // Read the port printed by the server.
            let handle = pipe.fileHandleForReading
            let deadline = Date().addingTimeInterval(5)
            var buffer = Data()
            while Date() < deadline {
                buffer.append(handle.availableData)
                if let s = String(data: buffer, encoding: .utf8),
                   let firstLine = s.split(separator: "\n").first,
                   let p = Int(firstLine), p > 0 {
                    port = p
                    serverReady = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } catch {
            NSLog("Local test server failed to start: \(error)")
        }
    }

    override class func tearDown() {
        serverProcess?.terminate()
        serverProcess = nil
        serverReady = false
        super.tearDown()
    }

    private func baseURL() -> String {
        XCTAssertTrue(Self.serverReady, "local test server must be running")
        return "http://127.0.0.1:\(Self.port)"
    }

    private let resolver = HTTPURLResolver(timeout: 5)

    func testResolvesDirectMP4WithContentType() async throws {
        let r = try await resolver.resolve(URL(string: "\(baseURL())/movie.mp4")!)
        XCTAssertEqual(r.statusCode, 200)
        XCTAssertEqual(r.contentType, "video/mp4")
        let kind = MediaKindDetector().detect(finalURL: r.finalURL, contentTypeHeader: r.contentType)
        XCTAssertEqual(kind, .progressiveVideo)
    }

    func testResolvesHLSManifest() async throws {
        let r = try await resolver.resolve(URL(string: "\(baseURL())/stream.m3u8")!)
        let kind = MediaKindDetector().detect(finalURL: r.finalURL, contentTypeHeader: r.contentType)
        XCTAssertEqual(kind, .hlsStream)
    }

    func testHTMLPageClassifiedAsWebPage() async throws {
        let r = try await resolver.resolve(URL(string: "\(baseURL())/page.html")!)
        let kind = MediaKindDetector().detect(finalURL: r.finalURL, contentTypeHeader: r.contentType)
        XCTAssertEqual(kind, .webPage)
        XCTAssertFalse(kind.isDirectlyPlayable)
    }

    func testFollowsRedirectToMediaAndReportsFinalURL() async throws {
        let r = try await resolver.resolve(URL(string: "\(baseURL())/redirect-to-media")!)
        XCTAssertEqual(r.finalURL.lastPathComponent, "movie.mp4",
                       "resolver must expose the final URL after redirects")
        let kind = MediaKindDetector().detect(finalURL: r.finalURL, contentTypeHeader: r.contentType)
        XCTAssertEqual(kind, .progressiveVideo)
    }

    func testNotFoundThrowsReadableError() async {
        do {
            _ = try await resolver.resolve(URL(string: "\(baseURL())/gone.mp4")!)
            XCTFail("expected notFound")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .notFound(statusCode: 404))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testForbiddenThrowsUnauthorized() async {
        do {
            _ = try await resolver.resolve(URL(string: "\(baseURL())/private.mp4")!)
            XCTFail("expected unauthorized")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .unauthorized(statusCode: 403))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFallsBackToGETWhenHeadRejected() async throws {
        let r = try await resolver.resolve(URL(string: "\(baseURL())/nohead")!)
        XCTAssertEqual(r.contentType, "video/quicktime")
        let kind = MediaKindDetector().detect(finalURL: r.finalURL, contentTypeHeader: r.contentType)
        XCTAssertEqual(kind, .progressiveVideo)
    }

    func testOctetStreamUsesExtensionFallback() async throws {
        let r = try await resolver.resolve(URL(string: "\(baseURL())/octet.mp4")!)
        let kind = MediaKindDetector().detect(finalURL: r.finalURL, contentTypeHeader: r.contentType)
        XCTAssertEqual(kind, .progressiveVideo)
    }

    func testConnectionRefusedMapsToNetworkFailure() async throws {
        // Port 1 is never listening.
        do {
            _ = try await resolver.resolve(URL(string: "http://127.0.0.1:1/x.mp4")!)
            XCTFail("expected network failure")
        } catch let error as PlaybackError {
            switch error {
            case .networkFailure, .timedOut: break   // platform-dependent detail
            default: XCTFail("unexpected \(error)")
            }
        }
    }

    func testRejectsNonHTTPScheme() async {
        do {
            _ = try await resolver.resolve(URL(string: "ftp://example.com/x.mp4")!)
            XCTFail("expected unsupportedScheme")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .unsupportedScheme("ftp"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
