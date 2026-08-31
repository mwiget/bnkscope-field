import Foundation
import Compression

/// gzip inflation.
///
/// Apple's Compression framework speaks raw DEFLATE, not gzip, so the RFC 1952
/// header is parsed off the front and the trailer ignored. The exporter gzips
/// its exposition text roughly twenty-fold — 286 KB becomes 14 KB — which is the
/// difference between a scrape a tablet can afford every two seconds and one it
/// cannot, so this path is on by default rather than an option.
public enum Gzip {
    public enum Failure: Error, CustomStringConvertible {
        case notGzip
        case truncatedHeader
        case inflate

        public var description: String {
            switch self {
            case .notGzip:         return "the body does not start with a gzip magic number"
            case .truncatedHeader: return "the gzip header is truncated"
            case .inflate:         return "the gzip body did not inflate"
            }
        }
    }

    public static func inflate(_ data: Data) throws -> Data {
        try rawInflate(stripHeader(data))
    }

    /// RFC 1952 §2.3: magic, method, flags, mtime, xfl, os, then the optional
    /// FEXTRA / FNAME / FCOMMENT / FHCRC fields the flag byte announces.
    static func stripHeader(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18 else { throw Failure.truncatedHeader }
        guard b[0] == 0x1f, b[1] == 0x8b, b[2] == 0x08 else { throw Failure.notGzip }
        let flags = b[3]
        var i = 10
        func need(_ n: Int) throws { guard i + n <= b.count else { throw Failure.truncatedHeader } }
        if flags & 0x04 != 0 {                                   // FEXTRA
            try need(2)
            let xlen = Int(b[i]) | (Int(b[i + 1]) << 8)
            i += 2 + xlen
        }
        if flags & 0x08 != 0 { i = try skipCString(b, from: i) }  // FNAME
        if flags & 0x10 != 0 { i = try skipCString(b, from: i) }  // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                           // FHCRC
        guard i < b.count - 8 else { throw Failure.truncatedHeader }
        return data.subdata(in: (data.startIndex + i)..<(data.endIndex - 8))
    }

    private static func skipCString(_ b: [UInt8], from start: Int) throws -> Int {
        var i = start
        while i < b.count, b[i] != 0 { i += 1 }
        guard i < b.count else { throw Failure.truncatedHeader }
        return i + 1
    }

    /// Streamed rather than one-shot: the inflated size is not known in advance,
    /// and guessing it wrong on a scrape that grew is a silent truncation.
    static func rawInflate(_ deflated: Data) throws -> Data {
        guard !deflated.isEmpty else { return Data() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { throw Failure.inflate }
        defer { compression_stream_destroy(streamPtr) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var out = Data()
        var status = COMPRESSION_STATUS_OK
        try deflated.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.inflate }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = raw.count
            repeat {
                streamPtr.pointee.dst_ptr = buffer
                streamPtr.pointee.dst_size = bufferSize
                status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.inflate }
                out.append(buffer, count: bufferSize - streamPtr.pointee.dst_size)
            } while status == COMPRESSION_STATUS_OK
        }
        return out
    }
}
