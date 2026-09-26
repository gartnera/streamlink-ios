#if DEBUG
import Foundation
import Network
import WebKit
import os

private let log = Logger(subsystem: "com.agartner.streamlink", category: "DebugServer")

/// Debug-only HTTP hook into the chat webview, started with `--debug-server`.
/// Loopback only (the Simulator shares the Mac's network):
///
///     curl -d 'return document.title' localhost:8765/eval   # async function body
///     curl localhost:8765/log                                # console.* + JS errors
///
/// The webview is also marked inspectable for Safari's Develop menu.
@MainActor
final class DebugServer {
    static let shared = DebugServer()
    static let port: NWEndpoint.Port = 8765
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--debug-server") }

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

    private weak var webView: WKWebView?
    private var listener: NWListener?
    private var lines: [String] = []
    private let maxLines = 2000

    /// Point the server at the chat `webView` and start it.
    func attach(_ webView: WKWebView) {
        self.webView = webView
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        log.notice("listening on 127.0.0.1:\(Self.port.rawValue)")
                    case .failed(let error):
                        // e.g. port in use; clear so the next attach retries.
                        log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.listener?.cancel()
                        self?.listener = nil
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

    private func handle(_ request: Request, _ conn: NWConnection) {
        // The Simulator shares the Mac's loopback, so any page in a Mac browser
        // could POST here. Browsers always send Origin on those (and a foreign
        // Host under DNS rebinding); curl sends neither.
        let host = request.headers["host"]?.split(separator: ":").first.map(String.init)
        guard request.headers["origin"] == nil, host == "localhost" || host == "127.0.0.1" else {
            return respond(conn, 403, "forbidden\n")
        }
        switch (request.method, request.path) {
        case ("POST", "/eval"):
            guard let webView else { return respond(conn, 503, "no webview\n") }
            webView.callAsyncJavaScript(request.body, arguments: [:], in: nil, in: .page) { [weak self] result in
                switch result {
                case .success(let value): self?.respond(conn, 200, Self.describe(value) + "\n")
                case .failure(let error): self?.respond(conn, 500, "\((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error.localizedDescription)\n")
                }
            }
        case ("GET", "/log"):
            respond(conn, 200, lines.joined(separator: "\n") + "\n")
        case ("DELETE", "/log"):
            lines.removeAll()
            respond(conn, 200, "cleared\n")
        default:
            respond(conn, 404, "POST /eval, GET|DELETE /log\n")
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "undefined" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
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
