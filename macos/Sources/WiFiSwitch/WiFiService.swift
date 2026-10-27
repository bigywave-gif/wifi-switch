import Foundation
import CoreWLAN
import CoreLocation
import SystemConfiguration
import WiFiSwitchCore

struct NearbyWiFi: Identifiable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int
    var authentication: WiFiAuthentication
    var supportsEnterpriseAuthentication: Bool { authentication == .enterprise }
    init(ssid: String, rssi: Int, supportsEnterpriseAuthentication: Bool = false) {
        self.ssid = ssid; self.rssi = rssi
        authentication = supportsEnterpriseAuthentication ? .enterprise : .personal
    }
    init(ssid: String, rssi: Int, authentication: WiFiAuthentication) {
        self.ssid = ssid; self.rssi = rssi; self.authentication = authentication
    }
}

struct WiFiSnapshot {
    var ssid: String?
    var poweredOn: Bool
    var available: Bool
    var ssidIsReadable = true
    var hasUsableAddress = false
}

/// Read-only notifications prompt a refresh of the connection and account label.
final class WiFiConnectionMonitor: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private let changed: () -> Void
    private let events: [CWEventType] = [.ssidDidChange, .linkDidChange, .powerDidChange]

    init(changed: @escaping () -> Void) {
        self.changed = changed
        super.init()
        client.delegate = self
        for event in events { try? client.startMonitoringEvent(with: event) }
    }

    deinit {
        for event in events { try? client.stopMonitoringEvent(with: event) }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func clientConnectionInterrupted() { changed() }
    func clientConnectionInvalidated() { changed() }
}

private func authentication(for network: CWNetwork) -> WiFiAuthentication {
    if [.wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .enterprise, .dynamicWEP]
        .contains(where: { network.supportsSecurity($0) }) { return .enterprise }
    if [.WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition, .personal]
        .contains(where: { network.supportsSecurity($0) }) { return .personal }
    if [.none, .OWE, .oweTransition].contains(where: { network.supportsSecurity($0) }) { return .open }
    return .unknown
}

private final class CoreWLANDriver: WiFiDriver {
    private let interface: CWInterface
    private var target: CWNetwork?
    private var credentialBackup: SystemCredentialBackup?

    init() throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        self.interface = interface
    }

    func prepare(ssid: String) throws -> WiFiAuthentication {
        guard interface.powerOn() else { throw WiFiError.poweredOff }
        let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8), includeHidden: true)
            .filter { $0.ssidData == Data(ssid.utf8) }
        guard !networks.isEmpty else { throw WiFiError.networkNotFound }
        let modes = Set(networks.map { authentication(for: $0) })
        guard modes.count == 1 else { throw WiFiError.ambiguousAuthentication }
        guard let mode = modes.first, mode != .unknown else { throw WiFiError.unsupportedAuthentication }
        target = networks.max(by: { $0.rssiValue < $1.rssiValue })
        return mode
    }

    func disconnect() throws { interface.disassociate() }

    func associate(credentials: WiFiAssociationCredentials) throws {
        guard let target else { throw WiFiError.networkNotFound }
        // Keep authentication and certificate trust inside macOS; never disable certificate checks.
        switch credentials {
        case let .enterprise(username, password):
            try interface.associate(toEnterpriseNetwork: target, identity: nil, username: username, password: password)
        case let .personal(password):
            try interface.associate(to: target, password: password)
        case .open:
            try interface.associate(to: target, password: nil)
        }
    }

    func linkState() -> LinkState {
        LinkState(ssid: interface.ssid(), hasUsableAddress: interfaceHasUsableAddress(interface))
    }

    func captureSystemCredentials(credentials: WiFiAssociationCredentials) throws {
        guard let ssid = target?.ssidData else { throw WiFiError.networkNotFound }
        credentialBackup = try SystemCredentialBackup(store: CoreWLANDefaultStore(interface: interface), ssid: ssid, credentials: credentials)
    }

    func restoreSystemCredentials() throws { try credentialBackup?.restore() }

    func saveSystemDefault(credentials: WiFiAssociationCredentials) throws {
        guard let ssid = target?.ssidData else {
            throw SystemDefaultSyncError(stage: "确认目标网络", code: -1)
        }
        try SystemDefaultSynchronizer(store: CoreWLANDefaultStore(interface: interface))
            .save(ssid: ssid, credentials: credentials)
    }
}

func interfaceHasUsableAddress(_ interface: CWInterface?) -> Bool {
    guard let name = interface?.interfaceName,
          let store = SCDynamicStoreCreate(nil, "WiFiSwitch" as CFString, nil, nil) else { return false }
    for family in ["IPv4", "IPv6"] {
        let key = "State:/Network/Interface/\(name)/\(family)" as CFString
        guard let value = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let addresses = value["Addresses"] as? [String] else { continue }
        if addresses.contains(where: { address in
            let value = address.lowercased()
            if family == "IPv4" {
                return !value.hasPrefix("169.254.") && !value.hasPrefix("127.") && value != "0.0.0.0"
            }
            return !value.hasPrefix("fe8") && !value.hasPrefix("fe9") && !value.hasPrefix("fea") &&
                   !value.hasPrefix("feb") && value != "::" && value != "::1"
        }) { return true }
    }
    return false
}

protocol WiFiServicing {
    func switchAccount(ssid: String, username: String, password: String, synchronizeSystemCredentials: Bool,
                       progress: @escaping (SwitchPhase) -> Void) async throws
    func snapshot() async -> WiFiSnapshot
    func scan() async throws -> [NearbyWiFi]
    func switchAccount(ssid: String, username: String, password: String,
                       progress: @escaping (SwitchPhase) -> Void) async throws
    func reconnectAccount(ssid: String, username: String, password: String,
                          progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult
}

extension WiFiServicing {
    func switchAccount(ssid: String, username: String, password: String, synchronizeSystemCredentials: Bool,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        guard synchronizeSystemCredentials else { throw SystemCredentialPreservationError(beforeConnection: true) }
        try await switchAccount(ssid: ssid, username: username, password: password, progress: progress)
    }
}

final class WiFiService: WiFiServicing {
    private let queue = DispatchQueue(label: "org.wifiswitch.WiFiSwitch.wifi", qos: .userInitiated)
    @MainActor private static let authorizationManager = CLLocationManager()

    func snapshot() async -> WiFiSnapshot {
        let ssidIsReadable = await MainActor.run { Self.authorizationManager.authorizationStatus == .authorizedAlways }
        return await withCheckedContinuation { continuation in
            queue.async {
                let interface = CWWiFiClient.shared().interface()
                continuation.resume(returning: WiFiSnapshot(ssid: interface?.ssid(),
                    poweredOn: interface?.powerOn() ?? false, available: interface != nil,
                    ssidIsReadable: ssidIsReadable, hasUsableAddress: interfaceHasUsableAddress(interface)))
            }
        }
    }

    func scan() async throws -> [NearbyWiFi] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
                    guard interface.powerOn() else { throw WiFiError.poweredOff }
                    let networks = try interface.scanForNetworks(withName: nil)
                    var strongest: [String: NearbyWiFi] = [:]
                    for network in networks {
                        guard let ssid = network.ssid, !ssid.isEmpty else { continue }
                        let existing = strongest[ssid]
                        let mode = authentication(for: network)
                        strongest[ssid] = NearbyWiFi(ssid: ssid,
                            rssi: max(existing?.rssi ?? Int.min, network.rssiValue),
                            authentication: existing.map { $0.authentication == mode ? mode : .unknown } ?? mode)
                    }
                    continuation.resume(returning: strongest.values.sorted {
                        $0.rssi == $1.rssi ? $0.ssid < $1.ssid : $0.rssi > $1.rssi
                    })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func switchAccount(ssid: String, username: String, password: String,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        _ = try await connect(ssid: ssid, username: username, password: password, automatic: false, progress: progress)
    }

    func reconnectAccount(ssid: String, username: String, password: String,
                          progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult {
        try await connect(ssid: ssid, username: username, password: password, automatic: true, progress: progress)
    }

    func switchAccount(ssid: String, username: String, password: String, synchronizeSystemCredentials: Bool,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        _ = try await connect(ssid: ssid, username: username, password: password, automatic: false, synchronizeSystemCredentials: synchronizeSystemCredentials, progress: progress)
    }

    private func connect(ssid: String, username: String, password: String, automatic: Bool, synchronizeSystemCredentials: Bool = true,
                         progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WiFiReconnectResult, Error>) in
            queue.async {
                do {
                    let driver = try CoreWLANDriver()
                    let engine = SwitchEngine(driver: driver)
                    let trace: (SwitchPhase) -> Void = { phase in
                        if phase == .authenticating { CredentialDiagnostics.record(.associationRequestStarting) }
                        if phase == .verifying { CredentialDiagnostics.record(.associationReturned) }
                        progress(phase)
                    }
                    if automatic {
                        let result = try engine.reconnectAccount(ssid: ssid, username: username, password: password, progress: trace)
                        CredentialDiagnostics.record(.connectionServiceReturned)
                        continuation.resume(returning: result)
                    } else {
                        try engine.switchAccount(ssid: ssid, username: username, password: password, synchronizeSystemCredentials: synchronizeSystemCredentials, progress: trace)
                        CredentialDiagnostics.record(.connectionServiceReturned)
                        continuation.resume(returning: .associated)
                    }
                } catch {
                    CredentialDiagnostics.record(.connectionServiceFailed, errorCode: (error as NSError).code)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var authorized: Bool { status == .authorizedAlways }
    var denied: Bool { status == .denied || status == .restricted }
    func request() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
