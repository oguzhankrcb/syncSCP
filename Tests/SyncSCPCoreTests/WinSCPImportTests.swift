// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

/// Import of WinSCP's own storage (exported INI and `reg export`), with key names and encodings
/// from upstream TSessionData::DoLoad. Host-key vectors were derived independently: OpenSSH
/// public keys from ssh-keygen, converted to PuTTY's form with separate Ed25519 decompression math.
final class WinSCPImportTests: XCTestCase {
    private static let ed25519 = ("0x12ebf98f7d0eafc69760cd3e8b90d27804b4420f881d9567d3d17d6b7dd23f54,0x2d46b0d9c75dc9ecd75c27796ad866c0b194a2840470048eda2a7dd8ca0d6c8a",
                                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpsDcrYfSrajgRwBISilLHAZthqeSdc1+zJXcfZsEYt")
    private static let rsa = ("0x10001,0xd303b12e5fcaecd0e5d0cfb3d2f818da4340b8701c967cda4b4a33d476c757f2e43ef590d0caf357e0534e49a7dc9c7fad3a1a266f169d968d3a95ac0ddef763974723a85f9697495b929c2cdd95fc064a34f90ff9e8d790a2102e37e4224c38e5d33dd6ca5d723dfe4bb68880e9526b1cd6ddb2388902135d6a76ef9db5d795",
                              "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDTA7EuX8rs0OXQz7PS+BjaQ0C4cByWfNpLSjPUdsdX8uQ+9ZDQyvNX4FNOSafcnH+tOhombxadlo06lawN3vdjl0cjqF+Wl0lbkpws3ZX8Bko0+Q/56NeQohAuN+QiTDjl0z3Wyl1yPf5LtoiA6VJrHNbdsjiJAhNdanbvnbXXlQ==")
    private static let ecdsa = ("nistp256,0x889de5f895c0b682fc682cacc83d418f724716d16c9165bfca1c11f97daf9c65,0xbb13efd225dff697fb11022ed9855d538cb78c8ebb69258c91fe9343bf48a3e8",
                                "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIid5fiVwLaC/GgsrMg9QY9yRxbRbJFlv8ocEfl9r5xluxPv0iXf9pf7EQIu2YVdU4y3jI67aSWMkf6TQ79Io+g=")

    private static let ini = """
    [Configuration\\Interface]
    Theme=Light
    [Sessions\\Default%20Settings]
    HostName=should-not-import
    [Sessions\\Production/root@db-1]
    HostName=db-1.example.com
    UserName=deploy
    FSProtocol=0
    Password=A35C435B9556B1237C2D2E2F
    Shell=sudo%20su%20-
    ReturnVar=status
    LookupUserGroups2=off
    Note=Database%20primary
    Color=5198809
    PublicKeyFile=C:%5CUsers%5Cme%5Ckeys%5Cdb.ppk
    LocalDirectory=C:%5CUsers%5Cme%5CDocuments
    RemoteDirectory=/etc/nginx
    Cipher=chacha20,aes,aesgcm,WARN,3des,arcfour,des,blowfish
    KEX=ecdh,mlkem-curve25519,dh-gex-sha1,WARN,dh-group1-sha1,rsa
    PingType=2
    PingIntervalSecs=45
    Timeout=40
    AddressFamily=1
    ProxyMethod=socks5
    ProxyHost=proxy.internal
    ProxyPort=1081
    ProxyDNS=0
    Tunnel=1
    TunnelHostName=jump@bastion.example.com
    TunnelPortNumber=2222
    BugHMAC2=2
    BugWinAdj=1
    Compression=1
    TryAgent=0
    AuthKI=0
    AgentFwd=1
    AuthGSSAPI=1
    RekeyTime=30
    RekeyBytes=512M
    TimeDifference=0.0416666666666667
    TimeDifferenceAuto=0
    ConsiderDST=0
    Utf=on
    [Sessions\\%EF%BB%BFStaging/%C4%B0stanbul%20sunucu]
    FSProtocol=2
    HostName=admin@app.example.com
    PortNumber=2222
    SftpServer=sudo%20/usr/lib/openssh/sftp-server
    SFTPMaxVersion=6
    [Sessions\\backups]
    FSProtocol=7
    Ftps=1
    HostName=s3.eu-central-1.amazonaws.com
    UserName=AKIAEXAMPLE
    S3DefaultRegion=eu-central-1
    S3UrlStyle=1
    S3RequesterPays=1
    S3SessionToken=secret-token
    [Sessions\\ftp.partner]
    FSProtocol=5
    Ftps=3
    HostName=ftp.partner.example
    UserName=partner
    FtpPasvMode=0
    MinTlsVersion=11
    MaxTlsVersion=12
    [Sessions\\dav]
    FSProtocol=6
    HostName=dav.example.com
    UserName=me
    [Sessions\\My%20Workspace/0000]
    IsWorkspace=1
    HostName=x.example.com
    [Sessions\\nohost]
    UserName=me
    [SshHostKeys]
    ssh-ed25519@22:db-1.example.com=\(ed25519.0)
    rsa2@2222:app.example.com=\(rsa.0)
    ecdsa-sha2-nistp256@22:10.0.0.5=\(ecdsa.0)
    dss@22:old.example.com=0x1,0x2,0x3,0x4
    """

    func testINIExportMapsSitesSettingsAndSecretsPolicy() throws {
        let result = try WinSCPImport.parse(Data(Self.ini.utf8))
        XCTAssertEqual(result.sites.map(\.site.name), ["Production/root@db-1", "Staging/İstanbul sunucu", "backups", "dav", "ftp.partner"])
        XCTAssertTrue(result.skipped.contains { $0.hasPrefix("My Workspace/0000:") })
        XCTAssertTrue(result.skipped.contains { $0.hasPrefix("nohost:") })
        XCTAssertTrue(result.skipped.contains { $0.contains("DSA") })
        XCTAssertFalse(result.sites.contains { $0.site.host == "should-not-import" })

        let db = try XCTUnwrap(result.sites.first { $0.site.host == "db-1.example.com" })
        let site = db.site, s = site.settings
        XCTAssertEqual(site.transferProtocol, .scp); XCTAssertEqual(site.port, 22); XCTAssertEqual(site.username, "deploy")
        XCTAssertEqual(site.remotePath, "/etc/nginx"); XCTAssertEqual(site.privateKey, "")
        XCTAssertEqual(site.localPath, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(s.shell, "sudo su -"); XCTAssertEqual(s.returnCodeVariable, "status"); XCTAssertEqual(s.lookupUserGroups, .off)
        XCTAssertEqual(s.note, "Database primary"); XCTAssertEqual(s.color, "#D9534F")
        XCTAssertEqual(s.ciphers, [.chacha20, .aes, .aesGCM, .warn, .tripleDES, .arcfour, .des, .blowfish])
        XCTAssertEqual(s.kex.prefix(6), [.ecdh, .mlkem, .dhGEX, .warn, .dhGroup1, .rsa])
        XCTAssertEqual(Set(s.kex), Set(KexGroup.defaultOrder))
        XCTAssertEqual(s.keepalive, .nullPacket); XCTAssertEqual(s.keepaliveSeconds, 45); XCTAssertEqual(s.timeoutSeconds, 40)
        XCTAssertEqual(s.addressFamily, .ipv4)
        XCTAssertEqual(s.proxyMethod, .socks5); XCTAssertEqual(s.proxyHost, "proxy.internal"); XCTAssertEqual(s.proxyPort, 1081); XCTAssertEqual(s.proxyDNS, .off)
        XCTAssertTrue(s.tunnel); XCTAssertEqual(s.tunnelHost, "bastion.example.com"); XCTAssertEqual(s.tunnelUsername, "jump"); XCTAssertEqual(s.tunnelPort, 2222)
        XCTAssertEqual(s.bugHMAC2, .on); XCTAssertEqual(s.bugWinAdj, .off); XCTAssertEqual(s.bugRekey2, .auto)
        XCTAssertTrue(s.compression); XCTAssertFalse(s.tryAgent); XCTAssertFalse(s.keyboardInteractive); XCTAssertTrue(s.agentForwarding); XCTAssertTrue(s.gssapiAuthentication)
        XCTAssertEqual(s.rekeyMinutes, 30); XCTAssertEqual(s.rekeyData, "512M")
        XCTAssertEqual(s.timeOffsetMinutes, 60); XCTAssertFalse(s.timeOffsetAuto); XCTAssertEqual(s.dstMode, .win); XCTAssertEqual(s.utf8, .on)
        let warnings = db.warnings.joined(separator: "\n")
        // The sample's Password value is truncated, so it cannot be decoded and the user is told.
        XCTAssertTrue(warnings.contains("password could not be read"), warnings)
        XCTAssertNil(db.password)
        XCTAssertTrue(warnings.contains("db.ppk") && warnings.contains("Convert PuTTY Key"), warnings)
        XCTAssertTrue(warnings.contains("Windows path"), warnings)
        XCTAssertTrue(warnings.contains("dummy commands"), warnings)

        let sftp = try XCTUnwrap(result.sites.first { $0.site.host == "app.example.com" })
        XCTAssertEqual(sftp.site.transferProtocol, .sftp); XCTAssertEqual(sftp.site.port, 2222); XCTAssertEqual(sftp.site.username, "admin")
        XCTAssertEqual(sftp.site.settings.sftpServer, "sudo /usr/lib/openssh/sftp-server"); XCTAssertFalse(sftp.site.settings.allowSCPFallback)
        XCTAssertEqual(sftp.site.settings.sftpMaxVersion, 3); XCTAssertTrue(sftp.warnings.contains { $0.contains("lowered to 3") })

        let s3 = try XCTUnwrap(result.sites.first { $0.site.name == "backups" }).site
        XCTAssertEqual(s3.transferProtocol, .s3); XCTAssertEqual(s3.port, 443); XCTAssertEqual(s3.username, "AKIAEXAMPLE")
        XCTAssertEqual(s3.s3Region, "eu-central-1"); XCTAssertTrue(s3.s3PathStyle); XCTAssertTrue(s3.settings.s3RequesterPays)
        XCTAssertTrue(result.sites.first { $0.site.name == "backups" }!.warnings.contains { $0.contains("session token") })
        let ftp = try XCTUnwrap(result.sites.first { $0.site.name == "ftp.partner" })
        XCTAssertEqual(ftp.site.transferProtocol, .ftpsExplicit); XCTAssertEqual(ftp.site.port, 21)
        XCTAssertEqual(ftp.site.settings.tlsMinimum, .tls11); XCTAssertEqual(ftp.site.settings.tlsMaximum, .tls12)
        XCTAssertTrue(ftp.warnings.contains { $0.contains("active mode") })
        let dav = try XCTUnwrap(result.sites.first { $0.site.name == "dav" }).site
        XCTAssertEqual(dav.transferProtocol, .webdav); XCTAssertEqual(dav.port, 80)
        for imported in result.sites {
            XCTAssertNoThrow(try imported.site.validate(), imported.site.name)
            let json = String(decoding: try JSONEncoder().encode(imported.site), as: UTF8.self).lowercased()
            XCTAssertFalse(json.contains("a35c435b") || json.contains("secret-token"), "a secret reached the site file")
        }
    }

    func testHostKeysConvertToOpenSSHExactly() throws {
        let keys = try WinSCPImport.parse(Data(Self.ini.utf8)).hostKeys
        XCTAssertEqual(Set(keys.map(\.knownHostsLine)), [
            "db-1.example.com \(Self.ed25519.1)\n", "[app.example.com]:2222 \(Self.rsa.1)\n", "10.0.0.5 \(Self.ecdsa.1)\n"])
        let ed = try XCTUnwrap(keys.first { $0.algorithm == "ssh-ed25519" })
        XCTAssertTrue(ed.fingerprint.hasPrefix("SHA256:")); XCTAssertEqual(ed.port, 22)
        XCTAssertThrowsError(try WinSCPImport.hostKey(name: "ssh-ed25519@22:bad host", value: Self.ed25519.0))
        XCTAssertThrowsError(try WinSCPImport.hostKey(name: "ssh-ed25519@x:host", value: Self.ed25519.0))
        XCTAssertThrowsError(try WinSCPImport.hostKey(name: "ecdsa-sha2-nistp256@22:h", value: "nistp384,0x1,0x2"))
        XCTAssertThrowsError(try WinSCPImport.hostKey(name: "ssh-ed448@22:h", value: "0x1,0x2"))
    }

    /// The same configuration exported with `reg export`: UTF-16LE, dwords, wrapped hex, escaped quotes.
    func testRegistryExportParsesLikeTheINI() throws {
        let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Sessions\\Production/root@db-1]
        "HostName"="db-1.example.com"
        "UserName"="deploy"
        "FSProtocol"=dword:00000000
        "Shell"="sudo%20su%20-"
        "Note"="Says \\"hello\\""
        "Color"=dword:004f53d9
        "PortNumber"=dword:00000016
        "TimeDifference"=hex:55,55,55,55,\\
          55,55,a5,3f
        "Compression"=dword:00000001
        "ProxyMethod"=dword:00000003
        "ProxyHost"="gateway"

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Sessions\\Other%20Site]
        "HostName"="other.example.com"
        "UserName"="me"
        "LocalDirectory"="C:\\\\Users\\\\me\\\\"

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\SshHostKeys]
        "ssh-ed25519@22:db-1.example.com"="\(Self.ed25519.0)"

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\ignored]
        "HostName"="putty.example.com"
        """
        var data = Data([0xFF, 0xFE]); data.append(reg.replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf16LittleEndian)!)
        let result = try WinSCPImport.parse(data)
        XCTAssertEqual(result.sites.map(\.site.name), ["Other Site", "Production/root@db-1"])
        let db = try XCTUnwrap(result.sites.last).site
        XCTAssertEqual(db.transferProtocol, .scp); XCTAssertEqual(db.port, 22); XCTAssertEqual(db.settings.shell, "sudo su -")
        XCTAssertEqual(db.settings.note, "Says \"hello\""); XCTAssertEqual(db.settings.color, "#D9534F")
        XCTAssertEqual(db.settings.timeOffsetMinutes, 60); XCTAssertTrue(db.settings.compression)
        XCTAssertEqual(db.settings.proxyMethod, .http); XCTAssertEqual(db.settings.proxyHost, "gateway")
        XCTAssertTrue(result.sites.first!.warnings.contains { $0.contains("Windows path") })
        XCTAssertEqual(result.hostKeys.map(\.knownHostsLine), ["db-1.example.com \(Self.ed25519.1)\n"])
        XCTAssertFalse(result.sites.contains { $0.site.host == "putty.example.com" })
    }

    func testUnmungingAndRejectedInput() throws {
        XCTAssertEqual(WinSCPImport.unmunge("a%20b%25c%5Cd"), "a b%c\\d")
        XCTAssertEqual(WinSCPImport.unmunge("%EF%BB%BF%E6%97%A5%E6%9C%AC"), "日本")
        XCTAssertEqual(WinSCPImport.unmunge("100%"), "100%")
        XCTAssertThrowsError(try WinSCPImport.parse(Data("[Configuration\\Interface]\nTheme=Dark\n".utf8)))
        XCTAssertThrowsError(try WinSCPImport.parse(Data([0xFF, 0xD8, 0xFF, 0x00, 0x81])))
        let unknown = try WinSCPImport.parse(Data("[Sessions\\x]\nHostName=h\nFSProtocol=9\n".utf8))
        XCTAssertTrue(unknown.sites.isEmpty); XCTAssertEqual(unknown.skipped.count, 1)
    }

    /// A Wine/Whisky prefix: C:\ paths resolve through dosdevices, the .ppk key is converted,
    /// names stay unique, a conflicting trusted host key is kept, and a backup is written first.
    func testCommitFromWinePrefixConvertsKeysAndProtectsExistingData() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("wine-import-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let prefix = root.appendingPathComponent("Bottle"), driveC = prefix.appendingPathComponent("drive_c")
        try manager.createDirectory(at: driveC.appendingPathComponent("users/me/keys"), withIntermediateDirectories: true)
        try manager.createDirectory(at: driveC.appendingPathComponent("WinSCP"), withIntermediateDirectories: true)
        try manager.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try PuTTYKeyTests.ed25519v3.write(to: driveC.appendingPathComponent("users/me/keys/server key.ppk"), atomically: true, encoding: .utf8)
        let ini = driveC.appendingPathComponent("WinSCP/WinSCP.ini")
        try """
        [Sessions\\db]
        HostName=db.example.com
        UserName=root
        FSProtocol=0
        Shell=sudo%20su%20-
        PublicKeyFile=C:%5Cusers%5Cme%5Ckeys%5Cserver%20key.ppk
        LocalDirectory=C:%5Cusers%5Cme
        [Sessions\\web]
        HostName=web.example.com
        UserName=deploy
        PublicKeyFile=C:%5Cusers%5Cme%5Ckeys%5Cserver%20key.ppk
        [SshHostKeys]
        ssh-ed25519@22:db.example.com=\(Self.ed25519.0)
        rsa2@2222:app.example.com=\(Self.rsa.0)
        """.write(to: ini, atomically: true, encoding: .utf8)

        let result = try WinSCPImport.parse(Data(contentsOf: ini), source: ini)
        let db = try XCTUnwrap(result.sites.first { $0.site.name == "db" })
        XCTAssertEqual(db.keySource, driveC.appendingPathComponent("users/me/keys/server key.ppk").resolvingSymlinksInPath().path)
        XCTAssertEqual(db.site.localPath, driveC.appendingPathComponent("users/me").resolvingSymlinksInPath().path)
        XCTAssertTrue(db.warnings.contains { $0.contains("will be converted") })

        let store = try SiteStore(directory: root.appendingPathComponent("Store"))
        let existing = [Site(name: "db", host: "old.example.com", username: "u")]
        try store.save(existing)
        try "app.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpsDcrYfSrajgRwBISilLHAZthqeSdc1+zJXcfZsEYt\n[app.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpsDcrYfSrajgRwBISilLHAZthqeSdc1+zJXcfZsEYt\n"
            .write(to: store.knownHostsFile, atomically: true, encoding: .utf8)
        let summary = try WinSCPImport.commit(result.sites, hostKeys: result.hostKeys, into: store, existing: existing)

        XCTAssertEqual(summary.sites.map(\.name), ["db (imported)", "web"]); XCTAssertEqual(summary.problems, [])
        XCTAssertEqual(summary.convertedKeys.count, 1, "one key file shared by two sites is converted once")
        let key = try XCTUnwrap(summary.convertedKeys.first)
        XCTAssertEqual(summary.sites.map(\.privateKey), [key, key])
        XCTAssertEqual((try manager.attributesOfItem(atPath: key)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try PuTTYKeyTests.derivedPublic(String(contentsOfFile: key), in: root), PuTTYKeyTests.ed25519Public)
        XCTAssertEqual(summary.hostKeysAdded, 2, "different algorithm for app.example.com:2222 is added")
        let hosts = try String(contentsOf: store.knownHostsFile)
        XCTAssertTrue(hosts.contains("db.example.com \(Self.ed25519.1)")); XCTAssertTrue(hosts.contains("[app.example.com]:2222 \(Self.rsa.1)"))
        XCTAssertEqual(try store.load().count, 3)
        let backup = try XCTUnwrap(summary.backup)
        XCTAssertEqual(try JSONDecoder().decode([Site].self, from: Data(contentsOf: backup.appendingPathComponent("sites.json"))), existing)
        // Re-importing the same host key is recognised; a different key for a trusted host is never swapped in.
        let again = try WinSCPImport.commit([], hostKeys: result.hostKeys, into: store, existing: try store.load())
        XCTAssertEqual(again.hostKeysAdded, 0); XCTAssertEqual(again.hostKeysAlreadyKnown, 2)
        let impostor = try WinSCPImport.hostKey(name: "ssh-ed25519@22:db.example.com", value: "0x1,0x2")
        let conflict = try WinSCPImport.commit([], hostKeys: [impostor], into: store, existing: try store.load())
        XCTAssertEqual(conflict.hostKeyConflicts, ["db.example.com (ssh-ed25519)"]); XCTAssertEqual(conflict.hostKeysAdded, 0)
    }

    /// WinSCP running under Wine/CrossOver keeps its settings in the prefix's user.reg.
    func testWineUserRegistryFile() throws {
        let wine = """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        #arch=win64

        [Software\\\\Martin Prikryl\\\\WinSCP 2\\\\Sessions\\\\Wine%20Site] 1792500000
        #time=1db4f0e7a8b9c00
        "HostName"="wine.example.com"
        "UserName"="w"
        "FSProtocol"=dword:00000002
        "Note"="Caf\\xe9 \\"quoted\\""

        [Software\\\\Martin Prikryl\\\\WinSCP 2\\\\SshHostKeys] 1792500000
        "ssh-ed25519@22:wine.example.com"="\(Self.ed25519.0)"
        """
        let result = try WinSCPImport.parse(Data(wine.utf8))
        XCTAssertEqual(result.sites.map(\.site.name), ["Wine Site"])
        XCTAssertEqual(result.sites.first?.site.transferProtocol, .sftp)
        XCTAssertEqual(result.sites.first?.site.settings.note, "Café \"quoted\"")
        XCTAssertEqual(result.hostKeys.map(\.knownHostsLine), ["wine.example.com \(Self.ed25519.1)\n"])
    }

    /// WinSCP's `EncryptPassword` (simple algorithm): flag, internal byte, length, shift, random
    /// padding, then key + password; each byte stored as hex of `~byte ^ 0xA3`.
    private func winSCPEncoded(_ password: String, key: String, flagged: Bool = true, shift: Int = 5) -> String {
        func encoded(_ byte: UInt8) -> String { String(format: "%02X", ~byte ^ 0xA3) }
        let plain = Array(((flagged ? key : "") + password).utf8)
        var text = flagged ? encoded(0xFF) + encoded(0) : ""
        text += encoded(UInt8(plain.count)) + encoded(UInt8(shift))
        for _ in 0..<shift { text += encoded(.random(in: 0...255)) }
        for byte in plain { text += encoded(byte) }
        for _ in 0..<7 { text += encoded(.random(in: 0...255)) }
        return text
    }

    func testSavedPasswordsDecodeLikeWinSCP() throws {
        let key = "deploy" + "db-1.example.com"
        XCTAssertEqual(WinSCPImport.decodePassword(winSCPEncoded("p@ss wörd;$1", key: key), key: key), "p@ss wörd;$1")
        XCTAssertEqual(WinSCPImport.decodePassword(winSCPEncoded("old-format", key: key, flagged: false), key: key), "old-format")
        XCTAssertEqual(WinSCPImport.decodePassword(winSCPEncoded("p", key: key, shift: 0).lowercased(), key: key), "p")
        XCTAssertNil(WinSCPImport.decodePassword(winSCPEncoded("secret", key: key), key: "someone" + "else.example.com"), "the user+host prefix must match")
        for junk in ["", "A35C435B9556B1237C2D2E2F", "XYZ0", "ABC", String(repeating: "F", count: 64)] {
            XCTAssertNil(WinSCPImport.decodePassword(junk, key: key), junk)
        }
        let ini = """
        [Sessions\\Encoded]
        HostName=db-1.example.com
        UserName=deploy
        Password=\(winSCPEncoded("s3cret!", key: key))
        [Sessions\\Plain]
        HostName=plain.example.com
        UserName=ops
        PasswordPlain=plain%20pass
        [Sessions\\Master]
        HostName=master.example.com
        UserName=ops
        Password=\(winSCPEncoded("hidden", key: "other"))
        """
        let sites = try WinSCPImport.parse(Data(ini.utf8)).sites
        XCTAssertEqual(sites.first { $0.site.name == "Encoded" }?.password, "s3cret!")
        XCTAssertEqual(sites.first { $0.site.name == "Plain" }?.password, "plain pass")
        let master = try XCTUnwrap(sites.first { $0.site.name == "Master" })
        XCTAssertNil(master.password)
        XCTAssertTrue(master.warnings.contains { $0.contains("master password") })
        XCTAssertFalse(sites.first { $0.site.name == "Encoded" }!.warnings.contains { $0.lowercased().contains("password") })
    }
}
