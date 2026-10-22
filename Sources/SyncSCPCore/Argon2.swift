// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// BLAKE2b (RFC 7693), unkeyed, for Argon2.
struct BLAKE2b {
    private static let iv: [UInt64] = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                                       0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]]

    private var h: [UInt64]
    private var buffer: [UInt8] = []
    private var counter: UInt64 = 0
    private let outputLength: Int

    init(outputLength: Int) {
        precondition((1...64).contains(outputLength))
        self.outputLength = outputLength
        h = Self.iv
        h[0] ^= 0x0101_0000 ^ UInt64(outputLength)
    }

    mutating func update(_ data: [UInt8]) {
        buffer += data
        // Keep the last block back: it must be compressed with the final flag.
        while buffer.count > 128 {
            counter &+= 128
            compress(Array(buffer[0..<128]), last: false)
            buffer.removeFirst(128)
        }
    }

    mutating func finalize() -> [UInt8] {
        counter &+= UInt64(buffer.count)
        compress(buffer + [UInt8](repeating: 0, count: 128 - buffer.count), last: true)
        var out: [UInt8] = []
        for word in h { for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) } }
        return Array(out.prefix(outputLength))
    }

    static func hash(_ data: [UInt8], outputLength: Int = 64) -> [UInt8] {
        var state = BLAKE2b(outputLength: outputLength); state.update(data); return state.finalize()
    }

    private mutating func compress(_ block: [UInt8], last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 { for j in 0..<8 { m[i] |= UInt64(block[i * 8 + j]) << UInt64(8 * j) } }
        var v = h + Self.iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d]; v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d]; v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }
        for round in 0..<12 {
            let s = Self.sigma[round % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }
}

extension UInt64 {
    @inline(__always) func rotatedRight(_ count: UInt64) -> UInt64 { (self >> count) | (self << (64 - count)) }
}

/// Argon2 version 1.3 (RFC 9106), as PuTTY uses it to derive key-file keys.
enum Argon2 {
    enum Variant: UInt32 { case d = 0, i = 1, id = 2 }

    /// `memory` is in KiB (1 KiB blocks); `lanes` is the parallelism, computed sequentially here.
    static func hash(password: [UInt8], salt: [UInt8], secret: [UInt8] = [], associated: [UInt8] = [],
                     memory: Int, passes: Int, lanes: Int, outputLength: Int, variant: Variant) throws -> [UInt8] {
        guard lanes >= 1, lanes <= 255, passes >= 1, passes <= 64, memory >= 8 * lanes, memory <= 1 << 21, outputLength >= 4 else {
            throw ClientError.invalid("The key's Argon2 parameters are outside the supported range.")
        }
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        var h0 = BLAKE2b(outputLength: 64)
        for part in [le32(lanes), le32(outputLength), le32(memory), le32(passes), le32(0x13), le32(Int(variant.rawValue))] { h0.update(part) }
        for value in [password, salt, secret, associated] { h0.update(le32(value.count)); h0.update(value) }
        let seed = h0.finalize()

        let segment = memory / (4 * lanes), laneLength = segment * 4, blockCount = laneLength * lanes
        var memoryBlocks = [UInt64](repeating: 0, count: blockCount * 128)
        func store(_ bytes: [UInt8], at block: Int) {
            for w in 0..<128 {
                var value: UInt64 = 0
                for b in 0..<8 { value |= UInt64(bytes[w * 8 + b]) << UInt64(8 * b) }
                memoryBlocks[block * 128 + w] = value
            }
        }
        for lane in 0..<lanes {
            store(variableHash(seed + le32(0) + le32(lane), length: 1024), at: lane * laneLength)
            store(variableHash(seed + le32(1) + le32(lane), length: 1024), at: lane * laneLength + 1)
        }

        let zero = [UInt64](repeating: 0, count: 128)
        var input = [UInt64](repeating: 0, count: 128), address = [UInt64](repeating: 0, count: 128)
        var scratch = [UInt64](repeating: 0, count: 128), r = [UInt64](repeating: 0, count: 128), z = [UInt64](repeating: 0, count: 128)
        memoryBlocks.withUnsafeMutableBufferPointer { memoryBuffer in
        zero.withUnsafeBufferPointer { zeroBuffer in
        input.withUnsafeMutableBufferPointer { inputBuffer in
        address.withUnsafeMutableBufferPointer { addressBuffer in
        scratch.withUnsafeMutableBufferPointer { scratchBuffer in
        r.withUnsafeMutableBufferPointer { rBuffer in
        z.withUnsafeMutableBufferPointer { zBuffer in
            let mem = memoryBuffer.baseAddress!, zeroBlock = zeroBuffer.baseAddress!, inputBlock = inputBuffer.baseAddress!
            let addressBlock = addressBuffer.baseAddress!, scratchBlock = scratchBuffer.baseAddress!, rBlock = rBuffer.baseAddress!, zBlock = zBuffer.baseAddress!
            for pass in 0..<passes {
                for slice in 0..<4 {
                    for lane in 0..<lanes {
                        let independent = variant == .i || (variant == .id && pass == 0 && slice < 2)
                        if independent {
                            for k in 0..<128 { inputBlock[k] = 0 }
                            inputBlock[0] = UInt64(pass); inputBlock[1] = UInt64(lane); inputBlock[2] = UInt64(slice)
                            inputBlock[3] = UInt64(blockCount); inputBlock[4] = UInt64(passes); inputBlock[5] = UInt64(variant.rawValue)
                        }
                        func nextAddresses() {
                            inputBlock[6] &+= 1
                            compress(zeroBlock, inputBlock, into: scratchBlock, xor: false, r: rBlock, z: zBlock)
                            compress(zeroBlock, scratchBlock, into: addressBlock, xor: false, r: rBlock, z: zBlock)
                        }
                        var start = 0
                        if pass == 0 && slice == 0 { start = 2; if independent { nextAddresses() } }
                        for index in start..<segment {
                            let column = slice * segment + index
                            let current = lane * laneLength + column
                            let previous = lane * laneLength + (column == 0 ? laneLength - 1 : column - 1)
                            let random: UInt64
                            if independent {
                                if index % 128 == 0 { nextAddresses() }
                                random = addressBlock[index % 128]
                            } else {
                                random = mem[previous * 128]
                            }
                            var referenceLane = Int((random >> 32) % UInt64(lanes))
                            if pass == 0 && slice == 0 { referenceLane = lane }
                            let sameLane = referenceLane == lane
                            let area: Int
                            if pass == 0 {
                                area = slice == 0 ? index - 1 : (sameLane ? slice * segment + index - 1 : slice * segment + (index == 0 ? -1 : 0))
                            } else {
                                area = sameLane ? laneLength - segment + index - 1 : laneLength - segment + (index == 0 ? -1 : 0)
                            }
                            let j1 = random & 0xFFFF_FFFF
                            let x = (j1 &* j1) >> 32
                            let relative = UInt64(area) - 1 - ((UInt64(area) &* x) >> 32)
                            let startPosition = pass == 0 ? 0 : (slice == 3 ? 0 : (slice + 1) * segment)
                            let reference = referenceLane * laneLength + (startPosition + Int(relative)) % laneLength
                            compress(mem + previous * 128, mem + reference * 128, into: mem + current * 128, xor: pass > 0, r: rBlock, z: zBlock)
                        }
                    }
                }
            }
        } } } } } } }
        var final = [UInt64](repeating: 0, count: 128)
        for lane in 0..<lanes {
            let last = lane * laneLength + laneLength - 1
            for w in 0..<128 { final[w] ^= memoryBlocks[last * 128 + w] }
        }
        var bytes: [UInt8] = []
        for word in final { for b in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(8 * b))) } }
        return variableHash(bytes, length: outputLength)
    }

    /// H' from RFC 9106 §3.3.
    static func variableHash(_ input: [UInt8], length: Int) -> [UInt8] {
        let prefix = (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) }
        if length <= 64 { return BLAKE2b.hash(prefix + input, outputLength: length) }
        let rounds = (length + 31) / 32 - 2
        var block = BLAKE2b.hash(prefix + input)
        var output = Array(block.prefix(32))
        for _ in 1..<rounds { block = BLAKE2b.hash(block); output += block.prefix(32) }
        output += BLAKE2b.hash(block, outputLength: length - 32 * rounds)
        return output
    }

    /// G from RFC 9106 §3.5: R = X ⊕ Y, permuted by rows then columns, result Z ⊕ R (⊕ the old block when `xor`).
    private static func compress(_ x: UnsafePointer<UInt64>, _ y: UnsafePointer<UInt64>, into out: UnsafeMutablePointer<UInt64>, xor: Bool,
                                 r: UnsafeMutablePointer<UInt64>, z: UnsafeMutablePointer<UInt64>) {
        for i in 0..<128 { let value = x[i] ^ y[i]; r[i] = value; z[i] = value }
        for row in 0..<8 {
            let b = row * 16
            permute(z, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        for column in 0..<8 {
            let c = column * 2
            permute(z, c, c + 1, c + 16, c + 17, c + 32, c + 33, c + 48, c + 49, c + 64, c + 65, c + 80, c + 81, c + 96, c + 97, c + 112, c + 113)
        }
        if xor { for i in 0..<128 { out[i] ^= z[i] ^ r[i] } } else { for i in 0..<128 { out[i] = z[i] ^ r[i] } }
    }

    @inline(__always)
    private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int, _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int,
                                _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(v, i0, i4, i8, i12); gb(v, i1, i5, i9, i13); gb(v, i2, i6, i10, i14); gb(v, i3, i7, i11, i15)
        gb(v, i0, i5, i10, i15); gb(v, i1, i6, i11, i12); gb(v, i2, i7, i8, i13); gb(v, i3, i4, i9, i14)
    }

    /// BLAKE2b's G with Argon2's multiply-add (BlaMka).
    @inline(__always)
    private static func gb(_ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        var va = v[a], vb = v[b], vc = v[c], vd = v[d]
        va = va &+ vb &+ 2 &* (va & 0xFFFF_FFFF) &* (vb & 0xFFFF_FFFF); vd = (vd ^ va).rotatedRight(32)
        vc = vc &+ vd &+ 2 &* (vc & 0xFFFF_FFFF) &* (vd & 0xFFFF_FFFF); vb = (vb ^ vc).rotatedRight(24)
        va = va &+ vb &+ 2 &* (va & 0xFFFF_FFFF) &* (vb & 0xFFFF_FFFF); vd = (vd ^ va).rotatedRight(16)
        vc = vc &+ vd &+ 2 &* (vc & 0xFFFF_FFFF) &* (vd & 0xFFFF_FFFF); vb = (vb ^ vc).rotatedRight(63)
        v[a] = va; v[b] = vb; v[c] = vc; v[d] = vd
    }
}
