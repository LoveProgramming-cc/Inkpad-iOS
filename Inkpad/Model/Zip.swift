import Foundation
import Compression
import zlib

/// A minimal zip reader and writer: stored and deflated entries, no zip64.
/// It is all the .inkpad format needs, and what Python's zipfile reads and writes.

struct ZipError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ZipEntry {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compSize: Int
    let size: Int
    let offset: Int   // of the local header
}

final class ZipReader {
    let data: Data
    private(set) var entries: [ZipEntry] = []
    private var index: [String: Int] = [:]

    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        // Slices keep their parent's indices; rebase so offsets start at zero.
        self.data = data.startIndex == 0 ? data : Data(data)
        try parse()
    }

    private func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    private func parse() throws {
        let n = data.count
        guard n >= 22 else { throw ZipError("not a zip file") }
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65535)
        while i >= stop {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError("not a zip file") }
        let count = u16(eocd + 10)
        var o = u32(eocd + 16)
        for _ in 0..<count {
            guard o + 46 <= n, u32(o) == 0x02014b50 else { throw ZipError("damaged zip directory") }
            let nameLen = u16(o + 28), extraLen = u16(o + 30), commentLen = u16(o + 32)
            guard o + 46 + nameLen <= n else { throw ZipError("damaged zip directory") }
            let name = String(decoding: data[(o + 46)..<(o + 46 + nameLen)], as: UTF8.self)
            let entry = ZipEntry(name: name, flags: UInt16(u16(o + 8)), method: UInt16(u16(o + 10)),
                                 crc: UInt32(u32(o + 16)), compSize: u32(o + 20), size: u32(o + 24), offset: u32(o + 42))
            index[name] = entries.count   // a later entry of the same name wins, as in zipfile
            entries.append(entry)
            o += 46 + nameLen + extraLen + commentLen
        }
    }

    var names: [String] { entries.map(\.name) }

    func has(_ name: String) -> Bool { index[name] != nil }

    func entry(_ name: String) -> ZipEntry? { index[name].map { entries[$0] } }

    /// The entry's bytes as they are in the file (still compressed).
    func raw(_ entry: ZipEntry) throws -> Data {
        let o = entry.offset
        guard o + 30 <= data.count, u32(o) == 0x04034b50 else { throw ZipError("damaged zip entry") }
        let start = o + 30 + u16(o + 26) + u16(o + 28)
        guard start + entry.compSize <= data.count else { throw ZipError("damaged zip entry") }
        return data[start..<(start + entry.compSize)]
    }

    func read(_ name: String) throws -> Data {
        guard let entry = entry(name) else { throw ZipError("missing \(name)") }
        let raw = try raw(entry)
        switch entry.method {
        case 0: return Data(raw)
        case 8: return try Self.inflate(raw, size: entry.size)
        default: throw ZipError("unsupported compression")
        }
    }

    static func inflate(_ src: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            src.withUnsafeBytes { s -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw ZipError("damaged zip data") }
        return out
    }
}

final class ZipWriter {
    private let handle: FileHandle
    private let tmp: URL
    private let dest: URL
    private var central = Data()
    private var offset = 0
    private var count = 0
    private let stamp: (time: UInt16, date: UInt16)

    /// Writes next to `url` and moves into place on finish, so a crash never leaves half a file.
    init(url: URL) throws {
        dest = url
        tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        handle = try FileHandle(forWritingTo: tmp)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        stamp = (UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2),
                 UInt16((max(1980, c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)))
    }

    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf -> UInt32 in
            var value = crc32(0, nil, 0)
            var p = buf.bindMemory(to: UInt8.self).baseAddress
            var left = buf.count
            while left > 0, let q = p {
                let n = min(left, 1 << 30)
                value = crc32(value, q, uInt(n))
                p = q + n
                left -= n
            }
            return UInt32(value)
        }
    }

    static func deflate(_ src: Data) -> Data? {
        guard src.count > 32 else { return nil }
        let cap = src.count
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            src.withUnsafeBytes { s -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < src.count else { return nil }   // did not fit, or not worth it
        out.count = n
        return out
    }

    func add(_ name: String, _ data: Data, compress: Bool = true) throws {
        if compress, let packed = Self.deflate(data) {
            try addRaw(name, method: 8, crc: Self.crc(data), size: data.count, raw: packed)
        } else {
            try addRaw(name, method: 0, crc: Self.crc(data), size: data.count, raw: data)
        }
    }

    func add(_ name: String, _ text: String, compress: Bool = true) throws {
        try add(name, Data(text.utf8), compress: compress)
    }

    /// Adds an entry whose bytes are already in their stored form (copied from another zip).
    func addRaw(_ name: String, method: UInt16, crc: UInt32, size: Int, raw: Data) throws {
        guard raw.count < 0xffff_ffff, size < 0xffff_ffff, offset < 0xffff_ffff else { throw ZipError("file too large") }
        let nameBytes = Data(name.utf8)
        let flags: UInt16 = name.utf8.contains(where: { $0 > 127 }) ? 0x800 : 0
        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(flags); local.le16(method)
        local.le16(stamp.time); local.le16(stamp.date)
        local.le32(crc); local.le32(UInt32(raw.count)); local.le32(UInt32(size))
        local.le16(UInt16(nameBytes.count)); local.le16(0)
        local.append(nameBytes)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: raw)
        central.le32(0x02014b50); central.le16(0x031e); central.le16(20); central.le16(flags); central.le16(method)
        central.le16(stamp.time); central.le16(stamp.date)
        central.le32(crc); central.le32(UInt32(raw.count)); central.le32(UInt32(size))
        central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(UInt32(0o100644) << 16); central.le32(UInt32(offset))
        central.append(nameBytes)
        offset += local.count + raw.count
        count += 1
    }

    func finish() throws {
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: tmp)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xff)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xffff)); le16(UInt16(v >> 16)) }
}
