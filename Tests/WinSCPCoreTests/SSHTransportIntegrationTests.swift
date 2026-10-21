// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

final class SSHTransportIntegrationTests: XCTestCase {
    func testOpenSSHEndToEndWithPinnedHostAndPrivateKey() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixture = environment["WINSCP_TEST_SSH_FIXTURE"], let portText = environment["WINSCP_TEST_SSH_PORT"], let port = Int(portText) else {
            throw XCTSkip("Run scripts/test-ssh.sh to enable the disposable localhost SSH fixture.")
        }
        let root = URL(fileURLWithPath: fixture)
        let site = Site(host: "127.0.0.1", port: port, username: NSUserName(), privateKey: root.appendingPathComponent("client_key").path)
        let configuration = SSHConfiguration(site: site, knownHostsFile: root.appendingPathComponent("known hosts").path)
        let client = RemoteSession()
        do {
            _ = try await client.connect(site: site, password: "", sshConfiguration: configuration)
            let data = Data("SFTP through real SSH · 日本語 · İstanbul\n".utf8)
            let source = root.appendingPathComponent("source")
            let target = root.appendingPathComponent("remote/ssh upload with spaces.txt")
            let downloaded = root.appendingPathComponent("downloaded")
            try data.write(to: source)
            try await client.upload(local: source, remote: target.path)
            try await client.download(remote: target.path, local: downloaded)
            XCTAssertEqual(try Data(contentsOf: downloaded), data)
            await client.disconnect()

            let untrusted = root.appendingPathComponent("untrusted_hosts")
            try Data().write(to: untrusted)
            do {
                _ = try await client.connect(site: site, password: "", sshConfiguration: SSHConfiguration(site: site, knownHostsFile: untrusted.path))
                XCTFail("SSH connected without an approved host key")
            } catch ClientError.connection { }
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
    }
}
