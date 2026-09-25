import Foundation

/// Swift wrapper around the CPython C bridge (`PyBridge.m`).
///
/// All calls funnel through `slbridge.handle(json)` in the bundled Python and
/// are serialized on a dedicated queue (CPython holds a single GIL anyway).
final class PythonBridge {
    static let shared = PythonBridge()
    private let queue = DispatchQueue(label: "com.example.streamlink.python")
    private var didBootstrap = false

    private init() {}

    /// Initialize the interpreter. Cheap to call repeatedly.
    func bootstrap() {
        queue.sync {
            if didBootstrap { return }
            didBootstrap = (py_bootstrap() == 0)
        }
    }

    enum BridgeError: LocalizedError {
        case nullResult
        case pythonError(String)

        var errorDescription: String? {
            switch self {
            case .nullResult:
                return "The Python bridge returned no data (interpreter or import failure)."
            case .pythonError(let msg):
                return msg
            }
        }
    }

    /// Send a request dictionary to `slbridge.handle` and decode the JSON reply.
    func request<T: Decodable>(_ body: [String: Any], as: T.Type) async throws -> T {
        let data = try await requestData(body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestData(_ body: [String: Any]) async throws -> Data {
        let argData = try JSONSerialization.data(withJSONObject: body)
        let arg = String(decoding: argData, as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if !self.didBootstrap {
                    self.didBootstrap = (py_bootstrap() == 0)
                }
                guard let c = py_call_json("slbridge", "handle", arg) else {
                    cont.resume(throwing: BridgeError.nullResult)
                    return
                }
                let data = Data(bytes: c, count: strlen(c))
                free(c)
                cont.resume(returning: data)
            }
        }
    }
}

// MARK: - Response models

struct DiagResponse: Decodable {
    let ok: Bool
    let python: String?
    let platform: String?
    let checks: [String: String]?
    let error: String?
}

struct StreamOption: Decodable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct ResolveResponse: Decodable {
    let ok: Bool
    let error: String?
    let plugin: String?
    let streams: [String]?          // available quality names, best/worst first
    let selected: SelectedStream?
}

struct SelectedStream: Decodable, Hashable {
    let name: String
    let url: String
    let headers: [String: String]
}
