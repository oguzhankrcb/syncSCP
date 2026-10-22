// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

/// Known-answer vectors from RFC 7693 (BLAKE2b) and RFC 9106 §5 (Argon2 version 1.3).
final class Argon2Tests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testBLAKE2bKnownAnswers() {
        XCTAssertEqual(hex(BLAKE2b.hash(Array("abc".utf8))),
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        XCTAssertEqual(hex(BLAKE2b.hash([])),
                       "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        // A message longer than one block exercises the counter and the final-block rule.
        XCTAssertEqual(BLAKE2b.hash([UInt8](repeating: 0x61, count: 300)).count, 64)
    }

    func testRFC9106Vectors() throws {
        let password = [UInt8](repeating: 1, count: 32), salt = [UInt8](repeating: 2, count: 16)
        let secret = [UInt8](repeating: 3, count: 8), associated = [UInt8](repeating: 4, count: 12)
        let expected: [(Argon2.Variant, String)] = [
            (.d, "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb"),
            (.i, "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8"),
            (.id, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"),
        ]
        for (variant, tag) in expected {
            let result = try Argon2.hash(password: password, salt: salt, secret: secret, associated: associated,
                                         memory: 32, passes: 3, lanes: 4, outputLength: 32, variant: variant)
            XCTAssertEqual(hex(result), tag, "Argon2\(variant)")
        }
    }
}
