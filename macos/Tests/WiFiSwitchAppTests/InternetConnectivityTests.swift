import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct InternetConnectivityTests {
    @Test func eitherIndependentEndpointCanProveReachability() async {
        let checker = InternetConnectivity { $0 == "www.microsoft.com" }
        #expect(await checker.isReachable())
    }

    @Test func bothEndpointsMustFailTwice() async {
        let counter = ProbeCounter()
        let checker = InternetConnectivity { host in await counter.probe(host) }
        #expect(await checker.isReachable() == false)
        #expect(await counter.count == 4)
    }

    @Test func transientFailureRecoversOnSecondRound() async {
        let counter = ProbeCounter(recover: true)
        let checker = InternetConnectivity { host in await counter.probe(host) }
        #expect(await checker.isReachable())
        #expect(await counter.count == 4)
    }
}

private actor ProbeCounter {
    var count = 0
    let recover: Bool
    init(recover: Bool = false) { self.recover = recover }
    func probe(_ host: String) -> Bool { count += 1; return recover && count > 2 }
}

@MainActor struct InternetMenuStatusTests {
    @Test func outageRecoveryAndThirtySecondRefresh() async throws {
        let f = try HealthFixture()
        await f.model.refresh()
        await f.settle()
        #expect(f.model.menuNetworkStatus == .unregistered)
        f.internet.result = false
        f.date += 31
        await f.model.refresh()
        await f.settle()
        #expect(f.model.menuNetworkStatus == .internetUnavailable)
        #expect(f.model.menuNetworkStatus.symbol == "xmark.circle.fill")
        #expect(!f.model.canAddMenuSystemConnection)
        f.internet.result = true
        f.date += 31
        await f.model.refresh()
        await f.settle()
        #expect(f.model.menuNetworkStatus == .unregistered)
        #expect(f.internet.reads == 3)
    }

    @Test func staleInternetSuccessCannotOverwriteDisconnectedState() async throws {
        let f = try HealthFixture()
        f.internet.hold = true
        await f.model.refresh()
        while f.internet.continuation == nil { await Task.yield() }
        f.wifi.current.ssid = nil
        f.wifi.current.hasUsableAddress = false
        await f.model.connectionDidChange()
        f.internet.continuation?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(f.model.menuNetworkStatus == .disconnected)
        #expect(f.model.internetStatus == .checking)
    }

    @Test func noAddressGetsGraceThenRedWithoutInternetProbe() async throws {
        let f = try HealthFixture()
        f.wifi.current.hasUsableAddress = false
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .waitingForAddress)
        f.date += 31
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .addressUnavailable)
        #expect(f.internet.reads == 0)
    }
}

@MainActor private final class HealthFixture {
    let wifi = HealthWiFi()
    let internet = HealthProbe()
    let repository: AccountRepository
    var date = Date(timeIntervalSince1970: 100)
    lazy var model = AppModel(demoMode: true, wifi: wifi, repository: repository,
        automaticReconnectEnabled: false, passwordCheckDate: { [unowned self] in self.date }, internetChecker: internet)
    init() throws { repository = try AccountRepository(storage: MemoryStorage(), vault: MemoryVault()) }
    func settle() async {
        for _ in 0..<100 {
            await Task.yield()
            if model.internetStatus != .checking { break }
        }
        // Allow an already-published status's scheduled refresh to finish too.
        for _ in 0..<10 { await Task.yield() }
    }
}
private final class HealthProbe: InternetChecking {
    var result = true, hold = false, reads = 0
    var continuation: CheckedContinuation<Bool, Never>?
    func isReachable() async -> Bool {
        reads += 1
        if hold { return await withCheckedContinuation { continuation = $0 } }
        return result
    }
}
private final class HealthWiFi: WiFiServicing {
    var current = WiFiSnapshot(ssid: "Test", poweredOn: true, available: true, hasUsableAddress: true)
    func snapshot() async -> WiFiSnapshot { current }
    func scan() async throws -> [NearbyWiFi] { [] }
    func switchAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws { throw WiFiError.demoMode }
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult { throw WiFiError.demoMode }
}
