import Foundation
import Network

protocol InternetChecking {
    func isReachable() async -> Bool
}

/// TLS must complete through Wi-Fi with normal certificate validation. No account data is sent.
struct InternetConnectivity: InternetChecking {
    typealias Probe = (String) async -> Bool
    private let probe: Probe
    init(probe: @escaping Probe = InternetConnectivity.probe) { self.probe = probe }

    func isReachable() async -> Bool {
        // Retry a failed round once so a single transient failure is not shown as an outage.
        for _ in 0..<2 {
            async let apple = probe("www.apple.com")
            async let microsoft = probe("www.microsoft.com")
            let results = await (apple, microsoft)
            if results.0 || results.1 { return true }
        }
        return false
    }

    static func probe(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "WiFiSwitch.internet-probe")
            let parameters = NWParameters.tls
            parameters.requiredInterfaceType = .wifi
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters)
            let completion = ProbeCompletion(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(true)
                case .failed, .cancelled: completion.finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { completion.finish(false) }
        }
    }
}

enum InternetStatus { case checking, reachable, unreachable }

/// Network callbacks and the timeout may race. Resume the continuation exactly once.
private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?
    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }
    func finish(_ success: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: success)
    }
}
