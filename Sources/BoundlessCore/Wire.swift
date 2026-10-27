import Foundation

public enum WireError: Error, Equatable {
    case truncated
    case unknownMessage(UInt8)
    case invalidValue
    case frameTooLarge(Int)
}

/// 小端序二进制写入
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { appendLE(UInt64(v), count: 2) }
    mutating func u32(_ v: UInt32) { appendLE(UInt64(v), count: 4) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { appendLE(v, count: 8) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func bytes(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
    mutating func string(_ s: String) { bytes(Data(s.utf8)) }

    private mutating func appendLE(_ v: UInt64, count: Int) {
        for i in 0..<count { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }
}

/// 小端序二进制读取
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, data.endIndex - offset >= n else { throw WireError.truncated }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func u8() throws -> UInt8 { UInt8(try readLE(1)) }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { UInt16(try readLE(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try readLE(4)) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func u64() throws -> UInt64 { try readLE(8) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func bytes() throws -> Data { try take(Int(try u32())) }

    mutating func string() throws -> String {
        guard let s = String(data: try bytes(), encoding: .utf8) else { throw WireError.invalidValue }
        return s
    }

    private mutating func readLE(_ n: Int) throws -> UInt64 {
        let d = try take(n)
        var v: UInt64 = 0
        for (i, b) in d.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }
}
