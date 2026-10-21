// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Converts PuTTY private key files (.ppk, format 2 and 3, no passphrase) to OpenSSH's
/// `openssh-key-v1` format, as `puttygen -O private-openssh` would. The file's MAC is verified
/// first. Layouts follow upstream `sshpubk.c`, `rsa.c` and `ecc-ssh.c`.
public enum PuTTYKey {
    public struct Converted: Equatable {
        public let privateKey: String
        public let publicKeyLine: String
        public let algorithm: String
        public let comment: String
    }

    public static func convert(_ text: String) throws -> Converted {
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
        guard encryption == "none" else {
            throw ClientError.unsupported("This PuTTY key is protected by a passphrase. Convert it with puttygen (-O private-openssh), then choose it in Advanced ▸ Authentication.")
        }
        var comment = ""
        (key, comment) = try header()
        guard key == "Comment" else { throw ClientError.invalid("The PuTTY key file has no Comment header.") }
        let publicBlob = try base64("Public-Lines")
        // Format 3 lists key-derivation headers only for encrypted keys.
        let privateBlob = try base64("Private-Lines")
        let (macName, macValue) = try header()
        guard macName == "Private-MAC" else { throw ClientError.invalid("The PuTTY key file has no MAC.") }
        let macText = macValue.lowercased()

        var macData = Data()
        for field in [Data(algorithm.utf8), Data("none".utf8), Data(comment.utf8), publicBlob, privateBlob] { macData += sshString(field) }
        let expected: String
        if version == 3 {
            expected = S3Signer.hex(Array(HMAC<SHA256>.authenticationCode(for: macData, using: SymmetricKey(data: Data()))))
        } else {
            let macKey = SymmetricKey(data: Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8))))
            expected = S3Signer.hex(Array(HMAC<Insecure.SHA1>.authenticationCode(for: macData, using: macKey)))
        }
        guard macText == expected else { throw ClientError.invalid("The PuTTY key file is corrupt (MAC mismatch).") }

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
