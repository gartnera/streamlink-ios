import Foundation
import Network

/// Tracks whether the current network path is cellular / metered, so playback
/// can default to a lower quality on mobile data.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cellular = false

    /// True on cellular data or another expensive path (e.g. a personal hotspot).
    var isCellular: Bool {
        lock.lock(); defer { lock.unlock() }
        return cellular
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
            self.lock.lock(); self.cellular = expensive; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
