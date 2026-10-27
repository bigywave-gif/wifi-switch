import Foundation
import Testing
@testable import WiFiSwitch

struct SingleInstanceTests {
    @Test func onlyOneOwnerAndReleaseAllowsNextLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-instance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("application.lock")
        var first = try SingleInstanceLock.acquire(at: url)
        #expect(first != nil)
        #expect(try SingleInstanceLock.acquire(at: url) == nil)
        first = nil
        let next = try SingleInstanceLock.acquire(at: url)
        #expect(next != nil)
        withExtendedLifetime(next) { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func staleFileDoesNotPreventStartup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-instance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("application.lock")
        try Data("old process".utf8).write(to: url)
        let owner = try SingleInstanceLock.acquire(at: url)
        #expect(owner != nil)
        defer { withExtendedLifetime(owner) {} }
        #expect(try SingleInstanceLock.acquire(at: url) == nil)
    }

    @Test func invalidLockLocationFailsInsteadOfAllowingAnotherInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-instance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try SingleInstanceLock.acquire(at: directory) }
    }
}
