import Foundation
import WiFiSwitchCore

/// Explicit visual QA only: both the network service and credentials are synthetic.
@MainActor
func launchModel() -> AppModel {
    let demo = CommandLine.arguments.contains("--demo")
    if demo && CommandLine.arguments.contains("--demo-import") {
        return AppModel(demoMode: true, wifi: ImportDemoWiFi(), automaticReconnectEnabled: false,
                        systemReader: ImportDemoReader())
    }
    return AppModel(demoMode: demo)
}

private final class ImportDemoWiFi: WiFiServicing {
    func snapshot() async -> WiFiSnapshot {
        WiFiSnapshot(ssid: "示例家庭热点", poweredOn: true, available: true, hasUsableAddress: true)
    }
    func scan() async throws -> [NearbyWiFi] { [] }
    func switchAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws {
        throw WiFiError.demoMode
    }
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult {
        throw WiFiError.demoMode
    }
}

private final class ImportDemoReader: SystemConnectionReading {
    func identity(ssid: String) async -> SystemConnectionIdentity? {
        .init(ssid: ssid, authentication: .personal, username: nil)
    }
    func configuration(ssid: String) async throws -> SystemConnectionConfiguration {
        .init(identity: .init(ssid: ssid, authentication: .personal, username: nil), password: "EXAMPLE-ONLY-NOT-A-REAL-PASSWORD")
    }
}
