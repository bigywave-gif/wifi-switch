import AppKit
import Darwin
import Foundation

/// The open descriptor owns the lock. Never unlink the file: another process may
/// already have opened the same inode. A crash automatically releases the lock.
final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return SingleInstanceLock(descriptor: descriptor)
    }
}

@MainActor
enum SingleInstanceController {
    static let reopenNotification = Notification.Name("org.wifiswitch.WiFiSwitch.showMainWindow")
    private static var instanceLock: SingleInstanceLock?

    static func claimGUIInstance() throws -> Bool {
        // Also recognize an older installed version that does not hold our lock.
        if let existing = runningGUIInstance() {
            activate(existing)
            return false
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiFiSwitch", isDirectory: true)
        guard let acquired = try SingleInstanceLock.acquire(at: directory.appendingPathComponent("application.lock")) else {
            if let existing = runningGUIInstance() { activate(existing) }
            return false
        }
        // The lock resolves simultaneous launches from different copies/paths.
        // Recheck in case a legacy instance finished launching in the meantime.
        if let existing = runningGUIInstance() {
            withExtendedLifetime(acquired) { activate(existing) }
            return false
        }
        instanceLock = acquired
        return true
    }

    private static func runningGUIInstance() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier?.hasSuffix(".WiFiSwitch") == true &&
                $0.executableURL?.lastPathComponent == "WiFiSwitch" &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                !$0.isTerminated && $0.activationPolicy != .prohibited }
    }

    private static func activate(_ application: NSRunningApplication) {
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let notification = application.bundleIdentifier.map { Notification.Name($0 + ".showMainWindow") } ?? reopenNotification
        DistributedNotificationCenter.default().postNotificationName(notification,
            object: String(application.processIdentifier), userInfo: nil, deliverImmediately: true)
    }
}
