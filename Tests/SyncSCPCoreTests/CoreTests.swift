// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Darwin
@testable import SyncSCPCore

final class CoreTests: XCTestCase {
    func testPacketCodecRoundTrip() throws {
        var writer = PacketWriter()
        writer.byte(103); writer.uint32(0x12345678); writer.uint64(UInt64.max)
        writer.string("İstanbul\n日本語 \"' $;"); writer.bytes(Data([0, 1, 255]))
        var reader = PacketReader(data: writer.data)
        XCTAssertEqual(try reader.byte(), 103)
        XCTAssertEqual(try reader.uint32(), 0x12345678)
        XCTAssertEqual(try reader.uint64(), UInt64.max)
        XCTAssertEqual(try reader.string(), "İstanbul\n日本語 \"' $;")
        XCTAssertEqual(try reader.bytes(), Data([0, 1, 255]))
        XCTAssertEqual(reader.remaining, 0)
        XCTAssertThrowsError(try reader.byte())
    }

    func testTruncatedAndInvalidUTF8PacketsAreRejected() throws {
        var truncated = PacketReader(data: Data([0, 0, 0, 12, 1]))
        XCTAssertThrowsError(try truncated.bytes())
        var invalid = PacketReader(data: Data([0, 0, 0, 1, 255]))
        XCTAssertThrowsError(try invalid.string())
        var flags = PacketWriter(); flags.uint32(0x10)
        var attributes = PacketReader(data: flags.data)
        XCTAssertThrowsError(try attributes.attributes(path: "/test", name: "test"))
    }

    func testSSHArgumentsPinHostKeysAndDoNotInvokeAShell() throws {
        let site = Site(host: "example.com", port: 2222, username: "user;$(touch injected)")
        let args = try SSHConfiguration(site: site, knownHostsFile: "/tmp/known hosts").arguments()
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("UserKnownHostsFile=\"/tmp/known hosts\""))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains(site.username))
        XCTAssertEqual(Array(args.suffix(4)), ["-s", "--", "example.com", "sftp"])
        XCTAssertFalse(args.contains("sh"))
    }

    func testInvalidHostsPortsAndNamesAreRejected() throws {
        for host in ["", "-oProxyCommand=anything", "host\nname", "user@host", "host/path"] {
            XCTAssertThrowsError(try Site(host: host).validate())
        }
        XCTAssertThrowsError(try Site(host: "host", port: 0).validate())
        XCTAssertThrowsError(try Site(host: "host", port: 65536).validate())
        for name in ["", ".", "..", "a/b", "null\0byte"] { XCTAssertThrowsError(try RemotePath.validateName(name)) }
        for name in ["a b", "a\nb", "\"'`$()", "Türkçe"] { XCTAssertNoThrow(try RemotePath.validateName(name)) }
    }

    func testLegacyDataFolderIsCopiedOnceWithPathsRewritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("WinSCPMac"), new = root.appendingPathComponent("SyncSCP")
        let legacy = try SiteStore(directory: old)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try Data("key".utf8).write(to: old.appendingPathComponent("keys/server"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: legacy.knownHostsFile)
        var site = Site(name: "Imported", host: "example.com", privateKey: old.path + "/keys/server", localPath: "/Users/me")
        site.settings.tunnelPrivateKey = old.path + "/keys/server"
        try legacy.save([site])

        XCTAssertTrue(try SiteStore.migrateLegacy(from: old, to: new))
        let migrated = try SiteStore(directory: new).load()
        XCTAssertEqual(migrated.first?.privateKey, new.path + "/keys/server")
        XCTAssertEqual(migrated.first?.settings.tunnelPrivateKey, new.path + "/keys/server")
        XCTAssertEqual(migrated.first?.localPath, "/Users/me")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("known_hosts"), encoding: .utf8), "host ssh-ed25519 AAAA\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("keys/server").path))
        // The old folder stays as a backup, and a second run never overwrites the new data.
        XCTAssertEqual(try legacy.load().first?.privateKey, old.path + "/keys/server")
        XCTAssertFalse(try SiteStore.migrateLegacy(from: old, to: new))
    }

    func testSiteStoreRoundTripHasNoPasswordField() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SiteStore(directory: directory)
        let sites = [Site(name: "Test server", host: "example.com", port: 2222, username: "test")]
        try store.save(sites)
        XCTAssertEqual(try store.load(), sites)
        let json = try String(contentsOf: directory.appendingPathComponent("sites.json"))
        XCTAssertFalse(json.lowercased().contains("password"))
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("sites.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLocalListingKeepsNoFollowTypesAndBasicMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-local-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: file.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: root.appendingPathComponent("missing").path)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        let entries = try LocalFiles.list(root.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(entries.first?.name, "directory")
        XCTAssertEqual(byName["file"]?.size, 3); XCTAssertEqual(byName["file"]?.permissions, 0o100750)
        XCTAssertNotNil(byName["file"]?.modified)
        XCTAssertEqual(byName["link"]?.isSymbolicLink, true); XCTAssertEqual(byName["dangling"]?.isSymbolicLink, true)
        XCTAssertEqual(byName["pipe"]?.isRegularFile, false); XCTAssertEqual(byName["pipe"]?.isDirectory, false)
    }

    func testSyncPlannerNeverDeletesOrFollowsSymlinksAndDetectsConflicts() {
        let date = Date(timeIntervalSince1970: 10000)
        let local: [String: FileEntry] = [
            "same": FileEntry(path: "same", name: "same", size: 20, modified: date),
            "changed": FileEntry(path: "changed", name: "changed", size: 30, modified: date),
            "new": FileEntry(path: "new", name: "new", size: 40),
            "dir": FileEntry(path: "dir", name: "dir", permissions: 0o040755),
            "link": FileEntry(path: "link", name: "link", permissions: 0o120777),
            "conflict": FileEntry(path: "conflict", name: "conflict", permissions: 0o040755)
        ]
        let remote: [String: FileEntry] = [
            "same": FileEntry(path: "same", name: "same", size: 20, modified: date.addingTimeInterval(1)),
            "changed": FileEntry(path: "changed", name: "changed", size: 20, modified: date),
            "remote-only": FileEntry(path: "remote-only", name: "remote-only"),
            "conflict": FileEntry(path: "conflict", name: "conflict")
        ]
        let items = SyncPlanner.compare(local: local, remote: remote)
        XCTAssertEqual(items.map(\.relativePath), ["changed", "conflict", "dir", "new"])
        XCTAssertEqual(items.map(\.action), [.upload, .conflict, .createDirectory, .upload])
        XCTAssertTrue(items[0].replacesFile)
        XCTAssertFalse(items[3].replacesFile)
    }

    func testSyncDirectionsNewerOnlyMirrorAndBothWays() {
        let old = Date(timeIntervalSince1970: 10_000), new = old.addingTimeInterval(600)
        func file(_ name: String, _ size: UInt64, _ date: Date?) -> FileEntry { FileEntry(path: name, name: name, size: size, modified: date) }
        func folder(_ name: String) -> FileEntry { FileEntry(path: name, name: name, permissions: 0o040755) }
        let local = ["newer-here": file("newer-here", 5, new), "newer-there": file("newer-there", 5, old), "unknown": file("unknown", 4, nil),
                     "only-local": file("only-local", 1, old), "local-dir": folder("local-dir"), "same": file("same", 3, old)]
        let remote = ["newer-here": file("newer-here", 6, old), "newer-there": file("newer-there", 6, new), "unknown": file("unknown", 5, new),
                      "only-remote": file("only-remote", 2, old), "remote-dir": folder("remote-dir"), "remote-dir/inner": file("remote-dir/inner", 1, old),
                      "same": file("same", 3, old.addingTimeInterval(1))]
        func plan(_ options: SyncOptions) -> [String: SyncAction] {
            Dictionary(uniqueKeysWithValues: SyncPlanner.compare(local: local, remote: remote, options: options).map { ($0.relativePath, $0.action) })
        }
        let both = plan(SyncOptions(direction: .both))
        XCTAssertEqual(both["newer-here"], .upload); XCTAssertEqual(both["newer-there"], .download)
        XCTAssertEqual(both["unknown"], .conflict, "no time on one side: undecidable")
        XCTAssertEqual(both["only-local"], .upload); XCTAssertEqual(both["only-remote"], .download)
        XCTAssertEqual(both["local-dir"], .createDirectory); XCTAssertEqual(both["remote-dir"], .createLocalDirectory)
        XCTAssertNil(both["same"])
        XCTAssertFalse(both.values.contains(.deleteLocal) || both.values.contains(.deleteRemote), "two-way never deletes")
        let newerUpload = plan(SyncOptions(direction: .upload, newerOnly: true))
        XCTAssertEqual(newerUpload["newer-here"], .upload); XCTAssertNil(newerUpload["newer-there"])
        let download = plan(SyncOptions(direction: .download))
        XCTAssertEqual(download["newer-here"], .download, "plain one-way copies any difference")
        XCTAssertNil(download["only-local"], "nothing is deleted without the option")
        let mirror = plan(SyncOptions(direction: .upload, deleteExtras: true))
        XCTAssertEqual(mirror["only-remote"], .deleteRemote); XCTAssertEqual(mirror["remote-dir"], .deleteRemote)
        XCTAssertNil(mirror["remote-dir/inner"], "a deleted folder covers its contents")
        XCTAssertEqual(plan(SyncOptions(direction: .download, deleteExtras: true))["only-local"], .deleteLocal)
        let sizes = plan(SyncOptions(direction: .upload, sizeOnly: true))
        XCTAssertNil(sizes["same"]); XCTAssertEqual(sizes["newer-here"], .upload)
        let link = FileEntry(path: "link", name: "link", permissions: 0o120777)
        XCTAssertEqual(SyncPlanner.compare(local: ["link": file("link", 1, old)], remote: ["link": link], options: SyncOptions(direction: .upload)).first?.action, .conflict)
    }
}
