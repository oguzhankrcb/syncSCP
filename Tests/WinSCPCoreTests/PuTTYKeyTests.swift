// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

/// PPK test files were written by a separate Python implementation of PuTTY's format
/// (sshpubk.c) from throwaway OpenSSH keys; conversion must reproduce each original public key.
final class PuTTYKeyTests: XCTestCase {
    static let ed25519v3 = "PuTTY-User-Key-File-3: ssh-ed25519\r\nEncryption: none\r\nComment: imported test key\r\nPublic-Lines: 2\r\nAAAAC3NzaC1lZDI1NTE5AAAAIIpsDcrYfSrajgRwBISilLHAZthqeSdc1+zJXcfZ\r\nsEYt\r\nPrivate-Lines: 1\r\nAAAAIGy2WW0ChuuRdagKeDZj6l3zaOcqwd29X37dRTVDxh8r\r\nPrivate-MAC: 51623dea0ae6ac81548e61004262f584e77522f4d81460ea95fe41e343b36b42\r\n"
    static let ed25519Public = "AAAAC3NzaC1lZDI1NTE5AAAAIIpsDcrYfSrajgRwBISilLHAZthqeSdc1+zJXcfZsEYt"
    static let rsaV2 = "PuTTY-User-Key-File-2: ssh-rsa\r\nEncryption: none\r\nComment: imported test key\r\nPublic-Lines: 4\r\nAAAAB3NzaC1yc2EAAAADAQABAAAAgQDTA7EuX8rs0OXQz7PS+BjaQ0C4cByWfNpL\r\nSjPUdsdX8uQ+9ZDQyvNX4FNOSafcnH+tOhombxadlo06lawN3vdjl0cjqF+Wl0lb\r\nkpws3ZX8Bko0+Q/56NeQohAuN+QiTDjl0z3Wyl1yPf5LtoiA6VJrHNbdsjiJAhNd\r\nanbvnbXXlQ==\r\nPrivate-Lines: 8\r\nAAAAgQCMxmfMMmgk+XB4kDi9xHqAEmH5KgJIe17+37AYTG3NROP1BMrqIJubwrKR\r\nBh6Q1W9wV9TeUzpZQ/lQXk38qwWLG1FEb0W1fVCtoBmODnh+WGnxkQPwjudUH/kO\r\nw4xFHuk+h7JB0yDD/HytbrroN8h9qvQbjzNya4t5FBmNi95HeQAAAEEA7SlOIrun\r\nJBFaqNSX6wVb9BF95jrVGzY3G8UdlQadjdcMzd+UVk0f6HAfeW7ROASBjvWk1vnY\r\nDd/ChxSHC8CvBwAAAEEA48av5L1CqGf8sWMqJiJVGKAbHwalWsObsTFqPYGTnuEV\r\nf9qXWGaD1pZ81TFA8ZoLZn/J+aOZ/u3LxQ0HxpjBgwAAAEEAjPw+kXuj5riUk4od\r\nSQHUner+w71rc4BWqUd5H7nOX0qiaeh8zSOuy3dSAts5yepermij4AyZ2VO3KZwI\r\n4VALDQ==\r\nPrivate-MAC: 761890f34e7a995bec594c790fa883dda1e08f47\r\n"
    static let rsaPublic = "AAAAB3NzaC1yc2EAAAADAQABAAAAgQDTA7EuX8rs0OXQz7PS+BjaQ0C4cByWfNpLSjPUdsdX8uQ+9ZDQyvNX4FNOSafcnH+tOhombxadlo06lawN3vdjl0cjqF+Wl0lbkpws3ZX8Bko0+Q/56NeQohAuN+QiTDjl0z3Wyl1yPf5LtoiA6VJrHNbdsjiJAhNdanbvnbXXlQ=="
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    /// `ssh-keygen -y` derives the public key from the converted private key file.
    static func derivedPublic(_ privateKey: String, in directory: URL) throws -> String {
        let file = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(privateKey.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); process.arguments = ["-y", "-f", file.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    func testFormat3Ed25519AndFormat2RSAConvertToWorkingOpenSSHKeys() throws {
        let ed = try PuTTYKey.convert(Self.ed25519v3)
        XCTAssertEqual(ed.algorithm, "ssh-ed25519"); XCTAssertEqual(ed.comment, "imported test key")
        XCTAssertTrue(ed.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertEqual(try Self.derivedPublic(ed.privateKey, in: directory), Self.ed25519Public)
        XCTAssertEqual(ed.publicKeyLine, "ssh-ed25519 \(Self.ed25519Public) imported test key\n")
        let rsa = try PuTTYKey.convert(Self.rsaV2)
        XCTAssertEqual(rsa.algorithm, "ssh-rsa")
        XCTAssertEqual(try Self.derivedPublic(rsa.privateKey, in: directory), Self.rsaPublic)
    }

    func testCorruptEncryptedAndForeignFilesAreRefused() {
        let tampered = Self.ed25519v3.replacingOccurrences(of: "Comment: imported test key", with: "Comment: changed")
        XCTAssertThrowsError(try PuTTYKey.convert(tampered)) { XCTAssertTrue("\($0.localizedDescription)".contains("MAC")) }
        let encrypted = Self.ed25519v3.replacingOccurrences(of: "Encryption: none", with: "Encryption: aes256-cbc")
        XCTAssertThrowsError(try PuTTYKey.convert(encrypted)) { error in
            guard case ClientError.unsupported(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("passphrase"))
        }
        XCTAssertThrowsError(try PuTTYKey.convert("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertThrowsError(try PuTTYKey.convert(Self.ed25519v3.replacingOccurrences(of: "Public-Lines: 2", with: "Public-Lines: 9")))
    }
}
