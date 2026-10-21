// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct PacketWriter {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) { var value = value.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    mutating func uint64(_ value: UInt64) { var value = value.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func bytes(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
}

struct PacketReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ClientError.protocolError("Truncated SFTP packet.") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uint32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { try take(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func bytes() throws -> Data { let count = try uint32(); return try take(Int(count)) }
    mutating func string() throws -> String {
        guard let text = String(data: try bytes(), encoding: .utf8) else {
            throw ClientError.unsupported("The server returned a file name that is not UTF-8.")
        }
        return text
    }
    mutating func attributes(path: String, name: String) throws -> FileEntry {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw ClientError.protocolError("Unknown SFTP v3 attribute flags.") }
        let size = flags & 1 != 0 ? try uint64() : 0
        if flags & 2 != 0 { _ = try uint32(); _ = try uint32() }
        let permissions = flags & 4 != 0 ? try uint32() : 0
        var modified: Date?
        if flags & 8 != 0 { _ = try uint32(); modified = Date(timeIntervalSince1970: TimeInterval(try uint32())) }
        if flags & 0x80000000 != 0 {
            let count = try uint32()
            guard count <= 4096 else { throw ClientError.protocolError("Too many extended SFTP attributes.") }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        return FileEntry(path: path, name: name, size: size, permissions: permissions, modified: modified, permissionsKnown: flags & 4 != 0)
    }
}
