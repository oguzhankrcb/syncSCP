// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CommonCrypto

/// Converts PuTTY private key files (.ppk, format 2 and 3) to OpenSSH's `openssh-key-v1`
/// format, as `puttygen -O private-openssh` would. Passphrase-protected keys (aes256-cbc;
/// SHA-1 key derivation in format 2, Argon2 in format 3) are decrypted with the passphrase.
/// The file's MAC is verified first. Layouts follow upstream `sshpubk.c`, `rsa.c` and `ecc-ssh.c`.
public enum PuTTYKey {
    public struct Converted: Equatable {
        public let privateKey: String
        public let publicKeyLine: String
        public let algorithm: String
        public let comment: String
    }

    /// Whether the key file needs a passphrase.
    public static func isEncrypted(_ text: String) -> Bool {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").contains { $0.hasPrefix("Encryption:") && !$0.hasSuffix(" none") }
    }

    public static func convert(_ text: String, passphrase: String? = nil) throws -> Converted {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        func header() throws -> (String, String) {
            guard let line = lines.popFirst(), let colon = line.firstIndex(of: ":") else { throw ClientError.invalid("This is not a PuTTY private key file.") }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        func base64(_ name: String) throws -> Data {
            let (key, value) = try header()
            guard key == name, let count = Int(value), (0...10_000).contains(count), lines.count >= count else { throw ClientError.invalid("The PuTTY key file is truncated.") }
            let joined = lines.prefix(count).joined(); lines = lines.dropFirst(count)
            guard let data = Data(base64Encoded: joined) else { throw ClientError.invalid("The PuTTY key file contains invalid base64.") }
            return data
        }
        let (first, algorithm) = try header()
        guard first.hasPrefix("PuTTY-User-Key-File-"), let version = Int(first.dropFirst("PuTTY-User-Key-File-".count)), (2...3).contains(version) else {
            throw ClientError.unsupported("Only PuTTY key file formats 2 and 3 are supported.")
        }
        var (key, encryption) = try header()
        guard key == "Encryption" else { throw ClientError.invalid("The PuTTY key file has no Encryption header.") }
        guard encryption == "none" || encryption == "aes256-cbc" else { throw ClientError.unsupported("PuTTY key encryption \(encryption) is not supported.") }
        let encrypted = encryption == "aes256-cbc"
        guard !encrypted || !(passphrase ?? "").isEmpty else {
            throw ClientError.invalid("This PuTTY key is protected by a passphrase. Enter it to convert the key.")
        }
        var comment = ""
        (key, comment) = try header()
        guard key == "Comment" else { throw ClientError.invalid("The PuTTY key file has no Comment header.") }
        let publicBlob = try base64("Public-Lines")
        // Format 3 lists key-derivation headers only for encrypted keys.
        var derivation: [String: String] = [:]
        while let next = lines.first, next.hasPrefix("Key-Derivation:") || next.hasPrefix("Argon2-") {
            let (name, value) = try header(); derivation[name] = value
        }
        var privateBlob = try base64("Private-Lines")
        let (macName, macValue) = try header()
        guard macName == "Private-MAC" else { throw ClientError.invalid("The PuTTY key file has no MAC.") }
        let macText = macValue.lowercased()

        let secret = Data((passphrase ?? "").utf8)
        var macKey = Data()
        if encrypted {
            var cipherKey: Data, iv: Data
            if version == 3 {
                guard derivation["Key-Derivation"].map({ ["Argon2id", "Argon2i", "Argon2d"].contains($0) }) == true,
                      let memory = derivation["Argon2-Memory"].flatMap(Int.init), let passes = derivation["Argon2-Passes"].flatMap(Int.init),
                      let lanes = derivation["Argon2-Parallelism"].flatMap(Int.init), let salt = derivation["Argon2-Salt"].flatMap(hexBytes) else {
                    throw ClientError.invalid("The PuTTY key's key-derivation headers are missing or invalid.")
                }
                let variant: Argon2.Variant = derivation["Key-Derivation"] == "Argon2id" ? .id : derivation["Key-Derivation"] == "Argon2i" ? .i : .d
                let derived = try Argon2.hash(password: Array(secret), salt: salt, memory: memory, passes: passes, lanes: lanes, outputLength: 80, variant: variant)
                cipherKey = Data(derived[0..<32]); iv = Data(derived[32..<48]); macKey = Data(derived[48..<80])
            } else {
                cipherKey = Data(Insecure.SHA1.hash(data: Data([0, 0, 0, 0]) + secret)) + Data(Insecure.SHA1.hash(data: Data([0, 0, 0, 1]) + secret))
                cipherKey = cipherKey.prefix(32); iv = Data(count: 16)
                macKey = Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8) + secret))
            }
            privateBlob = try decrypt(privateBlob, key: cipherKey, iv: iv)
        } else if version == 2 {
            macKey = Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8)))
        }
        var macData = Data()
        for field in [Data(algorithm.utf8), Data(encryption.utf8), Data(comment.utf8), publicBlob, privateBlob] { macData += sshString(field) }
        let expected = version == 3 ? S3Signer.hex(Array(HMAC<SHA256>.authenticationCode(for: macData, using: SymmetricKey(data: macKey))))
                                    : S3Signer.hex(Array(HMAC<Insecure.SHA1>.authenticationCode(for: macData, using: SymmetricKey(data: macKey))))
        guard macText == expected else {
            throw ClientError.invalid(encrypted ? "The passphrase is wrong, or the PuTTY key file is corrupt." : "The PuTTY key file is corrupt (MAC mismatch).")
        }

        var publicFields = Reader(publicBlob), privateFields = Reader(privateBlob)
        guard try publicFields.string() == Data(algorithm.utf8) else { throw ClientError.invalid("The PuTTY key's public part does not match its type.") }
        var body = Data()
        switch algorithm {
        case "ssh-ed25519":
            let pub = try publicFields.string(), seed = try privateFields.string()
            guard pub.count == 32, seed.count <= 32 else { throw ClientError.invalid("Invalid Ed25519 key.") }
            // PuTTY stores the seed as an unsigned little-endian integer; restore leading zero bytes.
            let fullSeed = seed + Data(repeating: 0, count: 32 - seed.count)
            body = sshString(Data(algorithm.utf8)) + sshString(pub) + sshString(fullSeed + pub)
        case "ssh-rsa":
            let e = try publicFields.string(), n = try publicFields.string()
            let d = try privateFields.string(), p = try privateFields.string(), q = try privateFields.string(), iqmp = try privateFields.string()
            body = sshString(Data(algorithm.utf8)) + sshString(n) + sshString(e) + sshString(d) + sshString(iqmp) + sshString(p) + sshString(q)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = try publicFields.string(), point = try publicFields.string(), scalar = try privateFields.string()
            body = sshString(Data(algorithm.utf8)) + sshString(curve) + sshString(point) + sshString(scalar)
        default:
            throw ClientError.unsupported("\(algorithm) PuTTY keys are not supported.")
        }
        var check = UInt32.random(in: .min ... .max).bigEndian
        var section = Data(bytes: &check, count: 4) + Data(bytes: &check, count: 4) + body + sshString(Data(comment.utf8))
        var pad: UInt8 = 1
        while section.count % 8 != 0 { section.append(pad); pad += 1 }
        let file = Data("openssh-key-v1".utf8) + Data([0]) + sshString(Data("none".utf8)) + sshString(Data("none".utf8)) + sshString(Data())
            + Data([0, 0, 0, 1]) + sshString(publicBlob) + sshString(section)
        let wrapped = stride(from: 0, to: file.base64EncodedString().count, by: 70).map { offset -> String in
            let encoded = file.base64EncodedString()
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            return String(encoded[start..<encoded.index(start, offsetBy: min(70, encoded.count - offset))])
        }.joined(separator: "\n")
        return Converted(privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)\n-----END OPENSSH PRIVATE KEY-----\n",
                         publicKeyLine: "\(algorithm) \(publicBlob.base64EncodedString())\(comment.isEmpty ? "" : " " + comment)\n",
                         algorithm: algorithm, comment: comment)
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: digits.count, by: 2).map { index -> UInt8? in
            UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)
        }.reduce(into: [UInt8]?([])) { result, byte in if let byte { result?.append(byte) } else { result = nil } }
    }

    /// AES-256-CBC without padding; PuTTY pads the private blob to whole blocks itself.
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard data.count % kCCBlockSizeAES128 == 0, key.count == 32, iv.count == 16 else { throw ClientError.invalid("The encrypted PuTTY key has an invalid length.") }
        var output = Data(count: data.count), moved = 0
        let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, 32, ivBytes.baseAddress,
                    input.baseAddress, data.count, out.baseAddress, data.count, &moved)
        } } } }
        guard status == kCCSuccess, moved == data.count else { throw ClientError.invalid("The PuTTY key could not be decrypted.") }
        return output
    }

    /// The inverse, for tests that build encrypted key files.
    static func encrypt(_ data: Data, key: Data, iv: Data) -> Data {
        var output = Data(count: data.count), moved = 0
        _ = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, 32, ivBytes.baseAddress,
                    input.baseAddress, data.count, out.baseAddress, data.count, &moved)
        } } } }
        return output
    }

    static func sshString(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return Data(bytes: &length, count: 4) + data
    }

    private struct Reader {
        var data: Data
        init(_ data: Data) { self.data = data }
        mutating func string() throws -> Data {
            guard data.count >= 4 else { throw ClientError.invalid("Truncated key data.") }
            let length = Int(data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard data.count - 4 >= length else { throw ClientError.invalid("Truncated key data.") }
            let value = Data(data.dropFirst(4).prefix(length)); data = Data(data.dropFirst(4 + length)); return value
        }
    }
}

/// Local OpenSSH private key files.
public enum OpenSSHKey {
    /// Encrypts an unencrypted key in place. `ssh-keygen -p` asks for the new passphrase twice
    /// through `askpass` (an SSH_ASKPASS environment that answers with it), so the passphrase
    /// never appears in an argument list. The result is checked: an empty passphrase must fail.
    public static func protect(_ file: URL, askpass: [String: String]) throws {
        let environment = ProcessInfo.processInfo.environment.merging(askpass) { _, new in new }
        let (status, output) = try keygen(["-p", "-P", "", "-f", file.path], environment: environment)
        guard status == 0 else { throw ClientError.invalid("ssh-keygen could not protect the key: \(output)") }
        let (check, _) = try keygen(["-y", "-P", "", "-f", file.path], environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SSH_ASKPASS") })
        guard check != 0 else { throw ClientError.invalid("The converted key could not be protected with its passphrase.") }
    }

    private static func keygen(_ arguments: [String], environment: [String: String]) throws -> (Int32, String) {
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
