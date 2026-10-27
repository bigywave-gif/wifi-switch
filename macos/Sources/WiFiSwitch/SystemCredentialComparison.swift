import CoreWLAN
import Foundation
import Security
import WiFiSwitchCore

enum SystemCredentialComparison: String, Codable {
    case same, different, unavailable
}

protocol SystemCredentialComparing {
    func compare(identity: SystemConnectionIdentity, accountID: UUID) async -> SystemCredentialComparison
    func compare(identity: SystemConnectionIdentity, accountID: UUID, expectedSource: SystemCredentialSource?) async -> SystemCredentialComparison
}

extension SystemCredentialComparing {
    func compare(identity: SystemConnectionIdentity, accountID: UUID, expectedSource: SystemCredentialSource?) async -> SystemCredentialComparison {
        await compare(identity: identity, accountID: accountID)
    }
}

enum CredentialComparisonReason: String, Codable {
    case equal, stableDifference, sourceChanged, changedDuringRead, identityChanged, unreadable, timedOut, helperFailed
}

struct SystemCredentialComparisonEvidence: Codable {
    let result: SystemCredentialComparison
    let reason: CredentialComparisonReason
    var source: SystemCredentialSource? = nil
    var errorCode: Int? = nil
}

/// The pipe carries identity and an application account ID, never a password or password hash.
struct SystemCredentialComparisonRequest: Codable {
    let identity: SystemConnectionIdentity
    let accountID: UUID
    var expectedSource: SystemCredentialSource? = nil
}

final class SystemCredentialComparator: SystemCredentialComparing {
    func compare(identity: SystemConnectionIdentity, accountID: UUID) async -> SystemCredentialComparison {
        await compare(identity: identity, accountID: accountID, expectedSource: nil)
    }

    func compare(identity: SystemConnectionIdentity, accountID: UUID, expectedSource: SystemCredentialSource?) async -> SystemCredentialComparison {
        if identity.authentication == .open { return .same }
        let request = SystemCredentialComparisonRequest(identity: identity, accountID: accountID, expectedSource: expectedSource)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let input = Pipe(), output = Pipe()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--compare-system-password"]
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    let data = try JSONEncoder().encode(request)
                    guard data.count < 4096 else { continuation.resume(returning: .unavailable); return }
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: data)
                    try input.fileHandleForWriting.close()
                } catch {
                    if process.isRunning { process.terminate() }
                    CredentialDiagnostics.record(.backgroundRead, comparison: .unavailable, reason: .helperFailed)
                    continuation.resume(returning: .unavailable)
                    return
                }
                if finished.wait(timeout: .now() + 4) == .timedOut {
                    process.terminate()
                    CredentialDiagnostics.record(.backgroundRead, comparison: .unavailable, reason: .timedOut)
                    continuation.resume(returning: .unavailable)
                    return
                }
                guard process.terminationStatus == 0 else {
                    CredentialDiagnostics.record(.backgroundRead, comparison: .unavailable, reason: .helperFailed,
                                                 errorCode: Int(process.terminationStatus))
                    continuation.resume(returning: .unavailable)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let result = data.count < 512 ? try? JSONDecoder().decode(SystemCredentialComparisonEvidence.self, from: data) : nil
                CredentialDiagnostics.record(.backgroundRead, comparison: result?.result ?? .unavailable,
                    reason: result?.reason ?? .unreadable, source: result?.source, errorCode: result?.errorCode)
                continuation.resume(returning: result?.result ?? .unavailable)
            }
        }
    }

    static func compare(request: SystemCredentialComparisonRequest,
                        system: () throws -> SystemConnectionConfiguration,
                        savedPassword: () throws -> String?) -> SystemCredentialComparison {
        evidence(request: request, system: system, savedPassword: savedPassword).result
    }

    static func evidence(request: SystemCredentialComparisonRequest,
                         system: () throws -> SystemConnectionConfiguration,
                         savedPassword: () throws -> String?) -> SystemCredentialComparisonEvidence {
        do {
            let configuration = try system()
            guard configuration.identity == request.identity else { return .init(result: .unavailable, reason: .identityChanged) }
            if let expected = request.expectedSource, configuration.source != expected {
                return .init(result: .unavailable, reason: .sourceChanged, source: configuration.source)
            }
            if request.identity.authentication == .open { return .init(result: .same, reason: .equal) }
            guard request.identity.authentication != .unknown,
                  let password = configuration.password, !password.isEmpty,
                  let saved = try savedPassword() else { return .init(result: .unavailable, reason: .unreadable) }
            // Only call it a difference when both sides remain stable across a second read.
            // A system refresh or app write between the reads must not create a false mismatch.
            if password != saved {
                let checked = try system()
                guard checked.identity == configuration.identity, checked.source == configuration.source,
                      checked.password == password, try savedPassword() == saved else {
                    return .init(result: .unavailable, reason: .changedDuringRead, source: configuration.source)
                }
            }
            return .init(result: password == saved ? .same : .different,
                reason: password == saved ? .equal : .stableDifference, source: configuration.source)
        } catch {
            let code: Int?
            if case let SystemImportError.keychain(_, value) = error { code = value }
            else if let failure = error as? KeychainFailure { code = Int(failure.status) }
            else { code = nil }
            return .init(result: .unavailable, reason: .unreadable, errorCode: code)
        }
    }

    /// Never run noninteractive legacy Keychain mode in the main application's process.
    static func runHelper() -> Int32 {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return 2 }
        let data = FileHandle.standardInput.readData(ofLength: 4096)
        guard data.count < 4096,
              let request = try? JSONDecoder().decode(SystemCredentialComparisonRequest.self, from: data) else { return 3 }
        func connectedInterface() throws -> CWInterface {
            guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interfaceHasUsableAddress(interface),
                  SystemConnectionReader.authentication(interface.security()) == request.identity.authentication else {
                throw SystemImportError.connectionChanged
            }
            // Location permission may be unavailable in this helper; the caller also checks the SSID before/after.
            if let ssid = interface.ssid(), ssid != request.identity.ssid { throw SystemImportError.connectionChanged }
            return interface
        }
        let result = evidence(request: request, system: {
            let interface = try connectedInterface()
            let store = CoreWLANDefaultStore(interface: interface)
            let identity = request.identity
            var source: SystemCredentialSource?
            let credentials = try SystemConnectionReader.readCredentials(authentication: identity.authentication,
                personal: { try PersonalWiFiKeychainReader().read(ssid: identity.ssid) },
                coreWLAN: { try store.read(ssid: Data(identity.ssid.utf8), enterprise: identity.authentication == .enterprise, domain: $0) },
                selectedSource: { source = $0 })
            var configuration = try SystemConnectionReader.resolve(ssid: identity.ssid, authentication: identity.authentication, credentials: credentials)
            configuration.source = source
            _ = try connectedInterface()
            return configuration
        }, savedPassword: { try KeychainVault().password(for: request.accountID) })
        guard let output = try? JSONEncoder().encode(result) else { return 4 }
        FileHandle.standardOutput.write(output)
        return 0
    }
}
