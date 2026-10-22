import SwiftUI
import WiFiSwitchCore

@main
struct Launcher {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--system-identity" {
            exit(SystemConnectionReader.runIdentityHelper(ssid: CommandLine.arguments[2]))
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try runStorageSelfTest(); print("PASS: Keychain CRUD, JSON persistence, restart, secret isolation, cleanup"); exit(0) }
            catch { fputs("Storage self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        WiFiSwitchApp.main()
    }
}

@MainActor
struct WiFiSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = launchModel()

    var body: some Scene {
        Window("WiFi Switch", id: "main") {
            ContentView(location: model.location).environmentObject(model)
        }
        .defaultSize(width: 800, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("关于 WiFi Switch") { AppInformation.showAbout() }
            }
            CommandGroup(replacing: .help) {
                Button("WiFi Switch 使用说明") { AppInformation.showUserGuide() }
            }
        }

        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Image(nsImage: model.isSwitching ? MenuBarIcon.connecting : MenuBarIcon.idle)
                .accessibilityLabel("WiFi Switch")
                .help("WiFi Switch")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Give AppKit an explicit image size; MenuBarExtra can ignore SwiftUI font/frame sizing.
@MainActor
private enum MenuBarIcon {
    static let idle = make("arrow.left.arrow.right.circle")
    static let connecting = make("arrow.triangle.2.circlepath")

    private static func make(_ symbol: String) -> NSImage {
        let size: CGFloat = 16
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WiFi Switch")?
            .withSymbolConfiguration(configuration) else {
            preconditionFailure("Missing menu bar symbol: \(symbol)")
        }
        let aspectRatio = image.size.width / image.size.height
        image.size = NSSize(width: size * aspectRatio, height: size)
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The system must be allowed to terminate the app during logout/shutdown.
        .terminateNow
    }
}

private func runStorageSelfTest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WiFiSwitch-selftest-\(UUID())")
    let storage = JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json"))
    let vault = KeychainVault(service: "org.wifiswitch.WiFiSwitch.selftest.\(UUID())")
    var cleanupIDs: [UUID] = []
    defer {
        for id in cleanupIDs { try? vault.deletePassword(for: id) }
        try? FileManager.default.removeItem(at: directory)
    }
    let repository = try AccountRepository(storage: storage, vault: vault)
    let network = try repository.addNetwork(ssid: "WiFiSwitch-SelfTest")
    let secret = UUID().uuidString
    let account = try repository.saveAccount(networkID: network, label: "Self test", username: "synthetic-user", newPassword: secret)
    cleanupIDs.append(account)
    guard try vault.password(for: account) == secret else { throw SelfTestFailure() }
    let contents = try String(contentsOf: storage.url, encoding: .utf8)
    guard !contents.contains(secret), !contents.contains("password") else { throw SelfTestFailure() }
    let reopened = try AccountRepository(storage: storage, vault: vault)
    guard try reopened.password(for: account) == secret else { throw SelfTestFailure() }
    try reopened.saveAccount(networkID: network, accountID: account, label: "Updated", username: "synthetic-updated", newPassword: "updated-\(secret)")
    guard try reopened.password(for: account) == "updated-\(secret)" else { throw SelfTestFailure() }
    try reopened.deleteAccount(networkID: network, accountID: account)
    guard try vault.password(for: account) == nil else { throw SelfTestFailure() }
    try reopened.removeNetwork(id: network)
    guard try storage.load().networks.isEmpty else { throw SelfTestFailure() }
}

private struct SelfTestFailure: Error {}
