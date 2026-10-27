import Darwin
import Foundation

/// Public, read-only system diagnostic. Never infer effective DNS by choosing Setup over State.
enum DNSResolverReader {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var valid = true
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count + chunk.count <= 262_144 { data.append(chunk) }
            else { valid = false }
        }
        func invalidate() { lock.lock(); valid = false; lock.unlock() }
        func text() -> String? {
            lock.lock(); defer { lock.unlock() }
            return valid ? String(data: data, encoding: .utf8) : nil
        }
    }

    /// Called on the information reader's background queue. Bound both runtime and captured output.
    static func read() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--dns"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close(); drained.signal() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    output.append(chunk)
                }
            } catch { output.invalidate() }
        }
        guard finished.wait(timeout: .now() + 3) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard drained.wait(timeout: .now() + 0.2) == .success, process.terminationStatus == 0 else { return nil }
        return output.text()
    }

    /// Select interface-scoped unicast resolvers only, not global, VPN, mDNS or per-domain routes.
    static func servers(in text: String?, interface: String) -> [String] {
        guard let text, !interface.isEmpty else { return [] }
        var scopedSection = false
        var currentInterface: String?
        var addresses: [String] = []
        var scoped = false
        var domainSpecific = false
        var multicast = false
        var result: [String] = []
        func flush() {
            if scopedSection && scoped && !domainSpecific && !multicast && currentInterface == interface {
                result.append(contentsOf: addresses)
            }
            currentInterface = nil; addresses = []; scoped = false; domainSpecific = false; multicast = false
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("DNS configuration") {
                flush()
                scopedSection = line == "DNS configuration (for scoped queries)"
            } else if line.hasPrefix("resolver #") {
                flush()
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("nameserver[") {
                    if isAddress(value) { addresses.append(value) }
                } else if key == "if_index", let left = value.firstIndex(of: "("), let right = value.lastIndex(of: ")"), left < right {
                    currentInterface = String(value[value.index(after: left)..<right])
                } else if key == "flags" {
                    scoped = value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "Scoped" }
                } else if key == "domain" { domainSpecific = true }
                else if key == "options" { multicast = value.split(separator: " ").contains("mdns") }
            }
        }
        flush()
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func isAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let base = String(value.split(separator: "%", maxSplits: 1).first ?? "")
        return inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, base, &ipv6) == 1
    }
}
