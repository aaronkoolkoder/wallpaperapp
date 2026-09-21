import Foundation
import Network
import Testing
import WebKit
import os
@testable import PlayerCore

@Suite("Web wallpapers cannot reach the network")
@MainActor
struct WebNetworkBlockTests {

    /// Counts TCP connections to a loopback port. Anything the page manages to send arrives here.
    private final class ConnectionCounter: Sendable {
        private let listener: NWListener
        private let count = OSAllocatedUnfairLock(initialState: 0)

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [count] connection in
                count.withLock { $0 += 1 }
                connection.cancel()
            }
        }

        var connections: Int { count.withLock { $0 } }

        func start() async throws -> UInt16 {
            listener.start(queue: .global())
            for _ in 0 ..< 100 {
                if let port = listener.port?.rawValue, port != 0 { return port }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }

        func stop() { listener.cancel() }
    }

    /// A 1x1 PNG, so the page has a local file to load alongside the remote ones.
    private static let pixel = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    )!

    @Test("Stylesheets, images, fetch and WebSockets to the network never connect")
    func subresourcesAreBlocked() async throws {
        let counter = try ConnectionCounter()
        let port = try await counter.start()
        defer { counter.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diorama-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.pixel.write(to: directory.appendingPathComponent("local.png"))

        let remote = "http://127.0.0.1:\(port)"
        let page = directory.appendingPathComponent("index.html")
        try """
        <html><head>
        <link rel="stylesheet" href="\(remote)/style.css">
        </head><body>
        <img id="remote" src="\(remote)/image.png">
        <img id="local" src="local.png">
        <script>
        var outcome = { fetch: null, socket: null };
        fetch('\(remote)/fetch').then(
            function () { outcome.fetch = 'sent'; },
            function () { outcome.fetch = 'refused'; });
        try {
            var socket = new WebSocket('ws://127.0.0.1:\(port)/socket');
            socket.onopen = function () { outcome.socket = 'open'; };
            socket.onerror = function () { outcome.socket = 'refused'; };
        } catch (e) { outcome.socket = 'refused'; }
        window.addEventListener('load', function () {
            setTimeout(function () {
                var local = document.getElementById('local');
                window.__result = [
                    'fetch=' + outcome.fetch,
                    'socket=' + outcome.socket,
                    'local=' + (local.naturalWidth === 1 ? 'loaded' : 'missing')
                ].join(' ');
            }, 300);
        });
        </script>
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)

        let configuration = WebBackend.configuration(
            properties: [:], isMuted: true, networkBlock: try await WebBackend.networkBlock()
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadFileURL(page, allowingReadAccessTo: directory)

        var result = "(timed out)"
        for _ in 0 ..< 100 {
            try? await Task.sleep(for: .milliseconds(50))
            if let text = try? await view.evaluateJavaScript("window.__result ?? null") as? String {
                result = text
                break
            }
        }
        // Give anything still in flight time to arrive before counting.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(result == "fetch=refused socket=refused local=loaded", "got \(result)")
        #expect(counter.connections == 0, "\(counter.connections) connection(s) reached the network")
    }

    @Test("The block compiles once and is reused")
    func compiledOnce() async throws {
        let first = try await WebBackend.networkBlock()
        let second = try await WebBackend.networkBlock()
        #expect(first === second)
    }

    @Test("Remote hosts in a page's markup are named for the report")
    func remoteHostsAreFound() {
        let html = """
        <link href="https://fonts.googleapis.com/css?family=Roboto" rel="stylesheet">
        <script src="//cdn.jsdelivr.net/npm/aplayer/dist/APlayer.min.js"></script>
        <script src='https://www.youtube.com/iframe_api'></script>
        <script src="js/index.min.js"></script>
        <img src="img/bg.png"><a href="#top">top</a>
        <link href="https://FONTS.googleapis.com/another">
        """
        #expect(WebBackend.remoteHosts(inHTML: html) == [
            "fonts.googleapis.com", "cdn.jsdelivr.net", "www.youtube.com",
        ])
    }

    @Test("A page with only local references names no hosts")
    func localPageNamesNoHosts() {
        #expect(WebBackend.remoteHosts(inHTML: #"<script src="main.js"></script><img src="a/b.png">"#).isEmpty)
    }
}
