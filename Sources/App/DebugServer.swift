#if DEBUG
import Foundation
import Network
import UIKit
import WebKit
import os

private let log = Logger(subsystem: "com.agartner.streamlink", category: "DebugServer")

/// Debug-only HTTP hook into the app's internals, started with `--debug-server`
/// or the Developer toggle in Settings. (UI flows are XCUITest's job.)
///
///     curl localhost:8765/state                              # app + player state (JSON)
///     curl -X POST localhost:8765/action/settings            # navigate; see ContentView.debugAction
///     curl -d '{"url":"hls://…"}' localhost:8765/action/open
///     curl localhost:8765/screenshot > shot.png
///     curl -d 'return document.title' localhost:8765/eval    # async JS function body, chat webview
///     curl localhost:8765/log                                # chat console.* + JS errors, app events
///
/// In the Simulator and on a Mac it listens on loopback only, since they share
/// the Mac's network. On a device it listens on all interfaces (after the
/// Local Network prompt) and every request needs `-H "X-Debug-Token: <token>"`,
/// with the token and addresses shown in Settings and printed at startup.
///
/// Send files with `--data-binary @file` (`-d @file` strips newlines).
/// The chat webview is also marked inspectable for Safari's Develop menu.
@MainActor
final class DebugServer {
    static let shared = DebugServer()
    static let port: NWEndpoint.Port = 8765
    static let settingKey = "debug_server"
    static var launchEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--debug-server") }
    static var enabled: Bool { launchEnabled || UserDefaults.standard.bool(forKey: settingKey) }

    static let loopbackOnly: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }()

    /// Per-install secret required from non-loopback clients.
    static let token: String = {
        let key = "debug_server_token"
        if let token = UserDefaults.standard.string(forKey: key) { return token }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: key)
        return token
    }()

    /// Forwards `console.*` and uncaught errors to the `debugLog` message handler.
    static let consoleHookJS = """
    (function () {
      var post = function (level, args) {
        try {
          window.webkit.messageHandlers.debugLog.postMessage(level + ' ' +
            Array.prototype.map.call(args, function (a) {
              try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); }
            }).join(' '));
        } catch (e) {}
      };
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var orig = console[level];
        console[level] = function () { post(level, arguments); return orig.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) { post('uncaught', [e.message + ' @' + e.filename + ':' + e.lineno]); });
      window.addEventListener('unhandledrejection', function (e) { post('unhandled', [String(e.reason)]); });
    })();
    """

    /// Logs taps, focus changes (with inputmode) and viewport resizes, for
    /// chasing keyboard issues on a device.
    static let focusTraceJS = """
    (function () {
      function desc(el) {
        if (!el || !el.getAttribute) return String(el);
        return el.tagName + '[' + (el.getAttribute('data-a-target') || el.getAttribute('aria-label') ||
          String(el.getAttribute('class') || '').slice(0, 30)) + ']' +
          (el.getAttribute('inputmode') ? ' im=' + el.getAttribute('inputmode') : '');
      }
      ['pointerdown', 'touchstart', 'click', 'focusin', 'focusout'].forEach(function (type) {
        document.addEventListener(type, function (e) {
          var t = e.composedPath ? e.composedPath()[0] : e.target;
          console.debug('[trace] ' + type + ' ' + desc(t) + ' trusted=' + e.isTrusted);
        }, true);
      });
      window.addEventListener('resize', function () {
        console.debug('[trace] resize ' + innerWidth + 'x' + innerHeight + ' active=' + desc(document.activeElement));
      });
    })();
    """

    /// App-level hooks, registered by `ContentView` (which owns the navigation state).
    struct AppHooks {
        /// Snapshot of the app's state for `GET /state`.
        var state: @MainActor () -> [String: Any]
        /// Run a named action with JSON args for `POST /action/<name>`.
        var perform: @MainActor (_ name: String, _ args: [String: Any]) async throws -> Void
    }

    struct ActionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    var app: AppHooks?
    private weak var webView: WKWebView?
    private var listener: NWListener?
    private var lines: [String] = []
    private let maxLines = 2000

    /// Start listening (idempotent; retried after a failure).
    func start() {
        guard listener == nil else { return }
        do {
            let listener: NWListener
            if Self.loopbackOnly {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
                listener = try NWListener(using: params)
            } else {
                listener = try NWListener(using: .tcp, on: Self.port)
                // Findable with `dns-sd -B _sldebug._tcp`.
                listener.service = NWListener.Service(name: UIDevice.current.name, type: "_sldebug._tcp")
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        log.notice("listening on port \(Self.port.rawValue)")
                        if !Self.loopbackOnly {
                            // Shows up in `devicectl ... process launch --console`.
                            print("[debug-server] http://\(Self.addresses.first ?? "<device-ip>"):\(Self.port.rawValue) " +
                                  "X-Debug-Token: \(Self.token)")
                        }
                    case .failed(let error):
                        // e.g. port in use; clear so the next start retries.
                        log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                        self.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.error("listen failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var isRunning: Bool { listener != nil }

    /// The device's IPv4 addresses, Wi-Fi first, for reaching the server.
    static var addresses: [String] {
        var result: [(name: String, ip: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        return result.sorted { ($0.name == "en0" ? 0 : 1) < ($1.name == "en0" ? 0 : 1) }.map(\.ip)
    }

    /// Point `/eval` at the chat `webView`.
    func attach(_ webView: WKWebView) {
        self.webView = webView
        if #available(iOS 16.4, *) { webView.isInspectable = true }
    }

    var webViewURL: String? { webView?.url?.absoluteString }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    /// Read until the headers and a `Content-Length` body have arrived.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.handle(request, conn)
                } else if done || error != nil {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buffer)
                }
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased names
        let body: String
    }

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let headerLines = head.components(separatedBy: "\r\n")
        let parts = headerLines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers,
                       body: String(decoding: body.prefix(length), as: UTF8.self))
    }

    private static let usage = """
    GET  /state                 app + player state
    POST /action/<name>         JSON args body; names listed in /state "actions"
    GET  /screenshot            PNG of the key window
    POST /eval                  body: async JS function body, run in the chat webview
    GET|DELETE /log             chat console + app events

    """

    private func handle(_ request: Request, _ conn: NWConnection) {
        // Any page in a browser could POST here. Browsers always send Origin on
        // those (and a foreign Host under DNS rebinding); curl sends neither.
        // Off-device clients (a device's network listener) also need the token.
        let host = request.headers["host"]?.split(separator: ":").first.map(String.init)
        let authorized = Self.isLoopback(conn.endpoint)
            ? host == "localhost" || host == "127.0.0.1"
            : request.headers["x-debug-token"] == Self.token
        guard request.headers["origin"] == nil, authorized else {
            return respond(conn, 403, "forbidden\n")
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("POST", "/eval"):
            guard let webView else { return respond(conn, 503, "no chat webview (open a Twitch stream)\n") }
            webView.callAsyncJavaScript(request.body, arguments: [:], in: nil, in: .page) { [weak self] result in
                switch result {
                case .success(let value): self?.respond(conn, 200, Self.describe(value) + "\n")
                case .failure(let error): self?.respond(conn, 500, "\((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error.localizedDescription)\n")
                }
            }
        case ("GET", "/state"):
            guard let app else { return respond(conn, 503, "app not ready\n") }
            respondJSON(conn, 200, app.state())
        case ("POST", _) where path.hasPrefix("/action/"):
            guard let app else { return respond(conn, 503, "app not ready\n") }
            let name = String(path.dropFirst("/action/".count))
            let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let args: [String: Any]
            if body.isEmpty {
                args = [:]
            } else if let parsed = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
                args = parsed
            } else {
                return respond(conn, 400, "body must be a JSON object\n")
            }
            append(String(format: "%.3f action %@ %@", Date().timeIntervalSince1970, name, body))
            Task {
                do {
                    try await app.perform(name, args)
                    respondJSON(conn, 200, app.state())
                } catch {
                    respond(conn, 400, "\(error.localizedDescription)\n")
                }
            }
        case ("GET", "/screenshot"):
            guard let png = Self.screenshot() else { return respond(conn, 503, "no window\n") }
            respond(conn, 200, png, contentType: "image/png")
        case ("GET", "/log"):
            respond(conn, 200, lines.joined(separator: "\n") + "\n")
        case ("DELETE", "/log"):
            lines.removeAll()
            respond(conn, 200, "cleared\n")
        default:
            respond(conn, 404, Self.usage)
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    // MARK: - Screenshot

    private static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    private static func screenshot() -> Data? {
        guard let window = keyWindow else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }

    // MARK: - Responses

    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "undefined" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    private func respondJSON(_ conn: NWConnection, _ status: Int, _ object: [String: Any]) {
        respond(conn, status, Self.describe(object) + "\n", contentType: "application/json")
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ body: String, contentType: String = "text/plain; charset=utf-8") {
        respond(conn, status, Data(body.utf8), contentType: contentType)
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ payload: Data, contentType: String) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Receives the console hook's messages.
final class DebugLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let line = String(format: "%.3f %@", Date().timeIntervalSince1970, "\(message.body)")
        print("[webview] \(line)")   // shows up in `devicectl ... launch --console`
        Task { @MainActor in DebugServer.shared.append(line) }
    }
}
#endif
