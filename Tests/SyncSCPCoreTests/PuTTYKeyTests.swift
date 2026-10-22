// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore
import CryptoKit

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
        XCTAssertTrue(PuTTYKey.isEncrypted(encrypted)); XCTAssertFalse(PuTTYKey.isEncrypted(Self.ed25519v3))
        XCTAssertThrowsError(try PuTTYKey.convert(encrypted)) { error in
            guard case ClientError.invalid(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("passphrase"))
        }
        XCTAssertThrowsError(try PuTTYKey.convert("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertThrowsError(try PuTTYKey.convert(Self.ed25519v3.replacingOccurrences(of: "Public-Lines: 2", with: "Public-Lines: 9")))
    }

    /// Builds an encrypted key file from an unencrypted one, following sshpubk.c: the private
    /// blob is padded to whole AES blocks, encrypted with AES-256-CBC and MACed in plaintext.
    private func encryptedVersion(of text: String, passphrase: String, version: Int) throws -> String {
        let lines = text.components(separatedBy: "\r\n")
        func block(_ name: String) -> (Data, [String]) {
            let index = lines.firstIndex { $0.hasPrefix(name + ":") }!
            let count = Int(lines[index].split(separator: " ").last!)!
            let body = Array(lines[(index + 1)...(index + count)])
            return (Data(base64Encoded: body.joined())!, body)
        }
        let algorithm = String(lines[0].split(separator: " ").last!)
        let comment = String(lines[2].dropFirst("Comment: ".count))
        let (publicBlob, publicLines) = block("Public-Lines")
        var (privateBlob, _) = block("Private-Lines")
        while privateBlob.count % 16 != 0 { privateBlob.append(UInt8.random(in: 0...255)) }
        let secret = Data(passphrase.utf8)
        var headers: [String] = []
        let key: Data, iv: Data, macKey: Data
        if version == 3 {
            let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
            let derived = try Argon2.hash(password: Array(secret), salt: salt, memory: 256, passes: 2, lanes: 1, outputLength: 80, variant: .id)
            key = Data(derived[0..<32]); iv = Data(derived[32..<48]); macKey = Data(derived[48..<80])
            headers = ["Key-Derivation: Argon2id", "Argon2-Memory: 256", "Argon2-Passes: 2", "Argon2-Parallelism: 1", "Argon2-Salt: " + salt.map { String(format: "%02x", $0) }.joined()]
        } else {
            key = (Data(Insecure.SHA1.hash(data: Data([0, 0, 0, 0]) + secret)) + Data(Insecure.SHA1.hash(data: Data([0, 0, 0, 1]) + secret))).prefix(32)
            iv = Data(count: 16); macKey = Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8) + secret))
        }
        var macData = Data()
        for field in [Data(algorithm.utf8), Data("aes256-cbc".utf8), Data(comment.utf8), publicBlob, privateBlob] { macData += PuTTYKey.sshString(field) }
        let mac = version == 3 ? HMAC<SHA256>.authenticationCode(for: macData, using: SymmetricKey(data: macKey)).map { String(format: "%02x", $0) }.joined()
                               : HMAC<Insecure.SHA1>.authenticationCode(for: macData, using: SymmetricKey(data: macKey)).map { String(format: "%02x", $0) }.joined()
        let encrypted = PuTTYKey.encrypt(privateBlob, key: key, iv: iv).base64EncodedString()
        let privateLines = stride(from: 0, to: encrypted.count, by: 64).map { String(Array(encrypted)[$0..<min($0 + 64, encrypted.count)]) }
        var output: [String] = [lines[0], "Encryption: aes256-cbc", "Comment: \(comment)", "Public-Lines: \(publicLines.count)"]
        output += publicLines
        output += headers
        output.append("Private-Lines: \(privateLines.count)")
        output += privateLines
        output += ["Private-MAC: \(mac)", ""]
        return output.joined(separator: "\n")
    }

    func testPassphraseProtectedKeysInBothFormatsConvertWithTheRightPassphraseOnly() throws {
        for (original, version, publicKey) in [(Self.ed25519v3, 3, Self.ed25519Public), (Self.rsaV2, 2, Self.rsaPublic)] {
            let file = try encryptedVersion(of: original, passphrase: "çok gizli parola", version: version)
            XCTAssertTrue(PuTTYKey.isEncrypted(file))
            let converted = try PuTTYKey.convert(file, passphrase: "çok gizli parola")
            XCTAssertEqual(try Self.derivedPublic(converted.privateKey, in: directory), publicKey, "format \(version)")
            XCTAssertEqual(converted.comment, "imported test key")
            XCTAssertThrowsError(try PuTTYKey.convert(file, passphrase: "wrong")) { XCTAssertTrue($0.localizedDescription.contains("passphrase is wrong"), "\($0)") }
            XCTAssertThrowsError(try PuTTYKey.convert(file)) { XCTAssertTrue($0.localizedDescription.contains("Enter it"), "\($0)") }
        }
    }

    func testPuTTYDefaultArgon2CostIsBearable() throws {
        // puttygen's defaults: Argon2id, 8 MiB, 1 lane, passes calibrated near 100 ms of C; 21 is typical.
        let started = Date()
        _ = try Argon2.hash(password: Array("x".utf8), salt: [UInt8](repeating: 7, count: 16), memory: 8192, passes: 21, lanes: 1, outputLength: 80, variant: .id)
        XCTAssertLessThan(Date().timeIntervalSince(started), 120)
        print("Argon2id 8 MiB × 21 passes took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }

    func testConvertedKeyIsProtectedThroughAskpassOnly() throws {
        let converted = try PuTTYKey.convert(Self.ed25519v3)
        let file = directory.appendingPathComponent("converted")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(converted.privateKey.utf8), attributes: [.posixPermissions: 0o600]))
        let askpass = directory.appendingPathComponent("askpass")
        try "#!/bin/sh\necho 'parola 123'\n".write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        try OpenSSHKey.protect(file, askpass: ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "syncscp:0"])
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); process.arguments = ["-y", "-P", "parola 123", "-f", file.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init), Self.ed25519Public)
        // Without a working askpass the key must not be left looking protected when it is not.
        let second = directory.appendingPathComponent("second")
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data(converted.privateKey.utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertThrowsError(try OpenSSHKey.protect(second, askpass: ["SSH_ASKPASS": "/nonexistent", "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "syncscp:0"]))
    }
}
