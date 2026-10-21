// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

final class SiteSettingsTests: XCTestCase {
    private func options(_ settings: SiteSettings, host: String = "example.com") throws -> [String] {
        try SSHOptions.arguments(settings, host: host, knownHostsFile: "/tmp/known hosts")
    }
    private func value(_ name: String, in options: [String]) -> String? {
        options.last { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    func testDefaultsKeepPreviousBehaviorAndOpenSSHAlgorithmDefaults() throws {
        let args = try options(SiteSettings())
        XCTAssertEqual(value("ConnectTimeout", in: args), "15"); XCTAssertEqual(value("ServerAliveInterval", in: args), "15")
        XCTAssertEqual(value("ServerAliveCountMax", in: args), "2"); XCTAssertEqual(value("ForwardAgent", in: args), "no")
        XCTAssertEqual(value("AddressFamily", in: args), "any"); XCTAssertEqual(value("Compression", in: args), "no")
        XCTAssertEqual(value("RekeyLimit", in: args), "1073741824 3600s")
        XCTAssertNil(value("Ciphers", in: args)); XCTAssertNil(value("KexAlgorithms", in: args)); XCTAssertNil(value("ProxyCommand", in: args))
        XCTAssertNil(value("IdentityAgent", in: args))
        let site = Site(host: "example.com", username: "u", transferProtocol: .sftp)
        XCTAssertEqual(try SSHConfiguration(site: site, knownHostsFile: "/tmp/k").arguments().suffix(4), ["-s", "--", "example.com", "sftp"])
    }

    func testEditedSettingsMapToOpenSSHOptions() throws {
        var settings = SiteSettings()
        settings.timeoutSeconds = 40; settings.keepalive = .off; settings.addressFamily = .ipv6; settings.compression = true
        settings.ciphers = [.chacha20, .aesGCM, .warn, .aes, .tripleDES, .blowfish, .arcfour, .des]
        settings.kex = [.ecdh, .rsa, .warn, .mlkem, .ntru, .dhGEX, .dhGroup18, .dhGroup17, .dhGroup16, .dhGroup15, .dhGroup14, .dhGroup1]
        settings.rekeyMinutes = 0; settings.rekeyData = "0"; settings.tryAgent = false; settings.keyboardInteractive = false
        settings.agentForwarding = true; settings.gssapiAuthentication = true; settings.gssapiDelegation = true; settings.certificateFile = "/keys/a b-cert.pub"
        let args = try options(settings)
        XCTAssertEqual(value("ConnectTimeout", in: args), "40"); XCTAssertEqual(value("ServerAliveInterval", in: args), "0")
        XCTAssertEqual(value("AddressFamily", in: args), "inet6"); XCTAssertEqual(value("Compression", in: args), "yes")
        XCTAssertEqual(value("Ciphers", in: args), "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com")
        XCTAssertEqual(value("KexAlgorithms", in: args), "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521")
        XCTAssertEqual(value("RekeyLimit", in: args), "default none"); XCTAssertEqual(value("IdentityAgent", in: args), "none")
        XCTAssertEqual(value("KbdInteractiveAuthentication", in: args), "no"); XCTAssertEqual(value("ForwardAgent", in: args), "yes")
        XCTAssertEqual(value("GSSAPIAuthentication", in: args), "yes"); XCTAssertEqual(value("GSSAPIDelegateCredentials", in: args), "yes")
        XCTAssertEqual(value("CertificateFile", in: args), "\"/keys/a b-cert.pub\"")
        var site = Site(host: "example.com", username: "u", transferProtocol: .sftp)
        site.settings.sftpServer = "sudo /usr/lib/openssh/sftp-server"
        XCTAssertEqual(try SSHConfiguration(site: site, knownHostsFile: "/tmp/k").arguments().suffix(3), ["--", "example.com", "sudo /usr/lib/openssh/sftp-server"])
    }

    func testProxyAndTunnelCommands() throws {
        var settings = SiteSettings()
        settings.proxyMethod = .socks5; settings.proxyHost = "proxy.internal"; settings.proxyPort = 1080
        XCTAssertEqual(value("ProxyCommand", in: try options(settings)), "/usr/bin/nc -X 5 -x 'proxy.internal:1080' %h %p")
        XCTAssertNil(value("ProxyCommand", in: try options(settings, host: "localhost")))
        settings.proxyLocalhost = true
        XCTAssertNotNil(value("ProxyCommand", in: try options(settings, host: "127.0.0.1")))
        settings.proxyMethod = .http; settings.proxyHost = "::1"
        XCTAssertEqual(value("ProxyCommand", in: try options(settings)), "/usr/bin/nc -X connect -x '[::1]:1080' %h %p")
        settings.proxyMethod = .local; settings.proxyLocalCommand = "/usr/local/bin/corkscrew gw 8080 %host %port"
        XCTAssertEqual(value("ProxyCommand", in: try options(settings)), "/usr/local/bin/corkscrew gw 8080 %h %p")
        settings.proxyMethod = .telnet
        XCTAssertThrowsError(try options(settings)) { XCTAssertEqual($0 as? ClientError, .unsupported("Telnet proxies are not implemented yet.")) }
        settings.proxyMethod = .socks4; settings.proxyHost = "proxy"; settings.proxyUsername = "me"
        XCTAssertThrowsError(try options(settings))

        var tunnel = SiteSettings()
        tunnel.tunnel = true; tunnel.tunnelHost = "bastion.example.com"; tunnel.tunnelPort = 2222; tunnel.tunnelUsername = "jump"
        tunnel.tunnelPrivateKey = "/keys/100% key"
        let command = try XCTUnwrap(value("ProxyCommand", in: try options(tunnel)))
        XCTAssertTrue(command.hasPrefix("'/usr/bin/ssh' '-F' '/dev/null' '-T' '-o' 'StrictHostKeyChecking=yes' '-o' 'UserKnownHostsFile=\"/tmp/known hosts\"'"), command)
        XCTAssertTrue(command.contains("'-p' '2222' '-l' 'jump' '-i' '/keys/100%% key' '-o' 'IdentitiesOnly=yes'"), command)
        XCTAssertTrue(command.hasSuffix("'-W' %h:%p '--' 'bastion.example.com'"), command)
        tunnel.proxyMethod = .socks5; tunnel.proxyHost = "proxy"
        XCTAssertTrue(try XCTUnwrap(value("ProxyCommand", in: try options(tunnel))).contains("'ProxyCommand=/usr/bin/nc -X 5 -x '\\''proxy:1080'\\'' %%h %%p'"))

        var dummy = SiteSettings(); dummy.keepalive = .dummyCommand
        XCTAssertThrowsError(try options(dummy))
    }

    func testValidationLimitsAndDataSizes() {
        XCTAssertEqual(SiteSettings.dataLimit("1G"), 1 << 30); XCTAssertEqual(SiteSettings.dataLimit("512m"), 512 << 20)
        XCTAssertEqual(SiteSettings.dataLimit("0"), 0); XCTAssertNil(SiteSettings.dataLimit("1T")); XCTAssertNil(SiteSettings.dataLimit("-1"))
        var settings = SiteSettings()
        XCTAssertNoThrow(try settings.validate())
        settings.shell = "sudo su -\nrm -rf /"; XCTAssertThrowsError(try settings.validate())
        settings = SiteSettings(); settings.timeoutSeconds = 0; XCTAssertThrowsError(try settings.validate())
        settings = SiteSettings(); settings.tlsMinimum = .tls13; settings.tlsMaximum = .tls12; XCTAssertThrowsError(try settings.validate())
        settings = SiteSettings(); settings.ciphers = [.warn, .aes, .chacha20, .aesGCM, .tripleDES, .blowfish, .arcfour, .des]; XCTAssertThrowsError(try settings.validate())
        settings = SiteSettings(); settings.ciphers = [.blowfish, .warn, .aes, .chacha20, .aesGCM, .tripleDES, .arcfour, .des]; XCTAssertThrowsError(try settings.validate())
        settings = SiteSettings(); settings.tunnel = true; XCTAssertThrowsError(try settings.validate())
        settings.tunnelHost = "-oProxyCommand=x"; XCTAssertThrowsError(try settings.validate())
        settings = SiteSettings(); settings.proxyMethod = .socks5; XCTAssertThrowsError(try settings.validate())
    }

    func testLenientDecodingAndRoundTrip() throws {
        var settings = SiteSettings()
        settings.shell = "sudo su -"; settings.sftpServer = "sudo /usr/libexec/sftp-server"; settings.note = "db primary"; settings.color = "#D9534F"
        settings.ciphers = [.chacha20, .aes, .aesGCM, .tripleDES, .warn, .blowfish, .arcfour, .des]
        let site = Site(host: "h", username: "u", transferProtocol: .scp, settings: settings)
        XCTAssertEqual(try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site)), site)
        let partial = try JSONDecoder().decode(SiteSettings.self, from: Data(#"{"shell":"sudo -s","keepalive":"fromTheFuture","timeoutSeconds":"x","unknownKey":1}"#.utf8))
        XCTAssertEqual(partial.shell, "sudo -s"); XCTAssertEqual(partial.keepalive, .nullPacket); XCTAssertEqual(partial.timeoutSeconds, 15)
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"","host":"h","port":22,"username":"u","privateKey":"","remotePath":".","localPath":"/"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Site.self, from: legacy).settings, SiteSettings())
    }
}
