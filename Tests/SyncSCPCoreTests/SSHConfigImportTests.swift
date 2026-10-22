// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

final class SSHConfigImportTests: XCTestCase {
    func testHostsTakeTheFirstValueAndWildcardDefaults() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sshconfig-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("key".utf8).write(to: home.appendingPathComponent(".ssh/id_deploy"))
        let config = """
        # personal servers
        Include ~/.ssh/config.d/*
        Host web prod-web
            HostName 203.0.113.10
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_deploy
            LocalForward 5433 127.0.0.1:5432
            LocalForward 127.0.0.1:8080 [::1]:80

        Host db
            HostName db.internal
            ProxyJump admin@bastion.example.com:2200,second-hop
            ServerAliveInterval 30

        Host legacy
            HostName=legacy.example.com
            ProxyCommand nc -X 5 -x proxy:1080 %h %p
            IdentityFile ~/.ssh/missing
            RemoteForward 9000 localhost:9000

        Host *.example.com !legacy
            Compression yes

        Host *
            User fallback
            ConnectTimeout 20
            Port 22
        """
        let result = SSHConfigImport.parse(config, home: home.path)
        let byName = Dictionary(uniqueKeysWithValues: result.sites.map { ($0.site.name, $0) })
        XCTAssertEqual(result.sites.map(\.site.name), ["SSH config/web", "SSH config/prod-web", "SSH config/db", "SSH config/legacy"])
        let web = try XCTUnwrap(byName["SSH config/web"])
        XCTAssertEqual(web.site.host, "203.0.113.10"); XCTAssertEqual(web.site.port, 2222); XCTAssertEqual(web.site.username, "deploy")
        XCTAssertEqual(web.site.privateKey, home.path + "/.ssh/id_deploy")
        XCTAssertEqual(web.site.settings.timeoutSeconds, 20, "Host * fills what the host leaves unset")
        XCTAssertEqual(web.site.settings.portForwards.map(\.summary), ["localhost:5433 → 127.0.0.1:5432", "localhost:8080 → ::1:80"])
        XCTAssertTrue(web.warnings.contains { $0.contains("Include") })
        let db = try XCTUnwrap(byName["SSH config/db"])
        XCTAssertEqual(db.site.username, "fallback"); XCTAssertEqual(db.site.port, 22)
        XCTAssertTrue(db.site.settings.tunnel); XCTAssertEqual(db.site.settings.tunnelHost, "bastion.example.com")
        XCTAssertEqual(db.site.settings.tunnelPort, 2200); XCTAssertEqual(db.site.settings.tunnelUsername, "admin")
        XCTAssertEqual(db.site.settings.keepalive, .nullPacket); XCTAssertEqual(db.site.settings.keepaliveSeconds, 30)
        XCTAssertTrue(db.warnings.contains { $0.contains("2 hops") })
        let legacy = try XCTUnwrap(byName["SSH config/legacy"])
        XCTAssertEqual(legacy.site.host, "legacy.example.com")
        XCTAssertEqual(legacy.site.settings.proxyMethod, .local); XCTAssertEqual(legacy.site.settings.proxyLocalCommand, "nc -X 5 -x proxy:1080 %h %p")
        XCTAssertFalse(legacy.site.settings.compression, "a negated pattern excludes the host")
        XCTAssertTrue(legacy.site.privateKey.isEmpty)
        XCTAssertTrue(legacy.warnings.contains { $0.contains("does not exist") } && legacy.warnings.contains { $0.contains("remoteforward") })
        XCTAssertTrue(SSHConfigImport.parse("Host *\n  User x\n").skipped.first?.contains("No concrete Host") == true)
    }
}
