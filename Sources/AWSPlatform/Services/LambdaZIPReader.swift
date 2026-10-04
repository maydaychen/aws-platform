import CZlib
import CoreFoundation
import Foundation

/// A bounded, read-only ZIP reader. Nothing from an entry (including its path,
/// permissions or extra fields) is ever materialized in the filesystem.
enum LambdaZIPReader {
    private struct Entry {
        let path: String
        let isDirectory: Bool
        let method: UInt16
        let crc: UInt32
        let size: Int
        let payload: Range<Int>
        let record: Range<Int>
    }

    static func read(
        at url: URL, limits: LambdaCodePreviewLimits = .init(),
        didReadChunk: (@Sendable (Int) -> Void)? = nil
    ) throws -> [LambdaCodeFile] {
        let deadline = ProcessInfo.processInfo.systemUptime + limits.extractionTimeout
        try checkProgress(deadline)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limits.maximumDownloadBytes else { throw LambdaCodeError.downloadTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limits.maximumDownloadBytes else { throw LambdaCodeError.downloadTooLarge }
        let entries = try parse(data, limits: limits, deadline: deadline)
        var expanded = 0
        var previewBytes = 0
        var files: [LambdaCodeFile] = []
        for entry in entries {
            try checkProgress(deadline)
            let visible = !entry.isDirectory && !entry.path.split(separator: "/").contains { $0.hasPrefix(".") }
            let keepText = visible && entry.size <= limits.maximumFilePreviewBytes
                && textExtensions.contains((entry.path as NSString).pathExtension.lowercased())
            var text = Data()
            var actual = 0
            var crc = crc32(0, nil, 0)
            try readPayload(data, entry: entry, deadline: deadline) { bytes in
                try checkProgress(deadline)
                guard bytes.count <= limits.maximumExpandedBytes - expanded else {
                    throw LambdaCodeError.archiveTooLarge
                }
                expanded += bytes.count
                actual += bytes.count
                guard actual <= entry.size else { throw LambdaCodeError.invalidArchive }
                crc = crc32(crc, bytes.baseAddress, uInt(bytes.count))
                if keepText {
                    guard bytes.count <= limits.maximumTotalPreviewBytes - previewBytes else {
                        throw LambdaCodeError.previewTooLarge
                    }
                    previewBytes += bytes.count
                    text.append(bytes.baseAddress!, count: bytes.count)
                }
                didReadChunk?(bytes.count)
            }
            guard actual == entry.size, UInt32(crc) == entry.crc else {
                throw LambdaCodeError.invalidArchive
            }
            if visible {
                let content = keepText ? String(data: text, encoding: .utf8) : nil
                files.append(LambdaCodeFile(path: entry.path, content: content, isBinary: content == nil))
            }
        }
        try checkProgress(deadline)
        return files.sorted { $0.path < $1.path }
    }

    private static func parse(
        _ data: Data, limits: LambdaCodePreviewLimits, deadline: TimeInterval
    ) throws -> [Entry] {
        guard data.count >= 22 else { throw LambdaCodeError.invalidArchive }
        // EOCD may be followed only by its own (at most 65535-byte) comment.
        let lower = max(0, data.count - 22 - 65_535)
        var end: Int?
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if data.u32(offset) == 0x06054b50,
               offset + 22 + Int(data.u16(offset + 20)) == data.count {
                end = offset
                break
            }
        }
        guard let end else { throw LambdaCodeError.invalidArchive }
        let count = Int(data.u16(end + 10))
        let directorySize = Int(data.u32(end + 12))
        let directoryStart = Int(data.u32(end + 16))
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10),
              count != 0xffff, directorySize != 0xffffffff, directoryStart != 0xffffffff else {
            throw LambdaCodeError.unsupportedArchive
        }
        guard count <= limits.maximumEntries else { throw LambdaCodeError.tooManyFiles }
        guard directoryStart <= end, directorySize == end - directoryStart else {
            throw LambdaCodeError.invalidArchive
        }
        var cursor = directoryStart
        var entries: [Entry] = []
        var paths: [String: Bool] = [:]
        var declaredBytes = 0
        for _ in 0..<count {
            try checkProgress(deadline)
            guard cursor + 46 <= end, data.u32(cursor) == 0x02014b50 else {
                throw LambdaCodeError.invalidArchive
            }
            let flags = data.u16(cursor + 8)
            let method = data.u16(cursor + 10)
            // Deflate tuning bits, descriptor and UTF-8 are the only supported flags.
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  method == 8 || flags & 0x0006 == 0,
                  data.u16(cursor + 6) <= 20, data.u16(cursor + 34) == 0 else {
                throw LambdaCodeError.unsupportedArchive
            }
            let compressed = Int(data.u32(cursor + 20))
            let size = Int(data.u32(cursor + 24))
            let local = Int(data.u32(cursor + 42))
            guard compressed != 0xffffffff, size != 0xffffffff, local != 0xffffffff else {
                throw LambdaCodeError.unsupportedArchive
            }
            guard size <= limits.maximumExpandedBytes - declaredBytes else {
                throw LambdaCodeError.archiveTooLarge
            }
            declaredBytes += size
            let nameCount = Int(data.u16(cursor + 28))
            let extraCount = Int(data.u16(cursor + 30))
            let commentCount = Int(data.u16(cursor + 32))
            let next = cursor + 46 + nameCount + extraCount + commentCount
            guard next <= end else { throw LambdaCodeError.invalidArchive }
            let name = data.subdata(in: cursor + 46..<cursor + 46 + nameCount)
            let path = try validatedPath(name, utf8: flags & 0x0800 != 0, limits: limits)
            let isDirectory = path.hasSuffix("/")
            let canonical = isDirectory ? String(path.dropLast()) : path
            guard paths[canonical] == nil else { throw LambdaCodeError.unsafeArchivePath }
            paths[canonical] = isDirectory
            let host = data.u16(cursor + 4) >> 8
            let mode = (data.u32(cursor + 38) >> 16) & 0xf000
            if host == 3 || host == 19 {
                guard mode == 0 || mode == 0x8000 || mode == 0x4000 else {
                    throw LambdaCodeError.unsupportedArchive
                }
                guard mode != 0x4000 || isDirectory, mode != 0x8000 || !isDirectory else {
                    throw LambdaCodeError.invalidArchive
                }
            }
            guard !isDirectory || size == 0 else { throw LambdaCodeError.invalidArchive }
            try validateExtra(data, range: cursor + 46 + nameCount..<cursor + 46 + nameCount + extraCount)
            guard local + 30 <= directoryStart, data.u32(local) == 0x04034b50,
                  data.u16(local + 4) == data.u16(cursor + 6),
                  data.u16(local + 6) == flags, data.u16(local + 8) == method,
                  Int(data.u16(local + 26)) == nameCount else {
                throw LambdaCodeError.invalidArchive
            }
            let localExtraCount = Int(data.u16(local + 28))
            let payloadStart = local + 30 + nameCount + localExtraCount
            guard payloadStart <= directoryStart, compressed <= directoryStart - payloadStart,
                  data.subdata(in: local + 30..<local + 30 + nameCount) == name else {
                throw LambdaCodeError.invalidArchive
            }
            try validateExtra(data, range: local + 30 + nameCount..<payloadStart)
            let crc = data.u32(cursor + 16)
            let payloadEnd = payloadStart + compressed
            var recordEnd = payloadEnd
            if flags & 8 == 0 {
                guard data.u32(local + 14) == crc,
                      Int(data.u32(local + 18)) == compressed, Int(data.u32(local + 22)) == size else {
                    throw LambdaCodeError.invalidArchive
                }
            } else {
                // A streaming ZIP may leave these fields zero until its descriptor.
                guard [0, crc].contains(data.u32(local + 14)),
                      [0, UInt32(compressed)].contains(data.u32(local + 18)),
                      [0, UInt32(size)].contains(data.u32(local + 22)) else {
                    throw LambdaCodeError.invalidArchive
                }
                let starts = [payloadEnd, payloadEnd + 4]
                guard let descriptor = starts.first(where: { start in
                    (start == payloadEnd || data.u32(payloadEnd) == 0x08074b50)
                        && start + 12 <= directoryStart
                        && data.u32(start) == crc
                        && Int(data.u32(start + 4)) == compressed
                        && Int(data.u32(start + 8)) == size
                }) else { throw LambdaCodeError.invalidArchive }
                recordEnd = descriptor + 12
            }
            if method == 0, compressed != size { throw LambdaCodeError.invalidArchive }
            entries.append(Entry(path: canonical, isDirectory: isDirectory, method: method,
                                 crc: crc, size: size, payload: payloadStart..<payloadEnd,
                                 record: local..<recordEnd))
            cursor = next
        }
        guard cursor == end else { throw LambdaCodeError.invalidArchive }
        var previousEnd = 0
        for entry in entries.sorted(by: { $0.record.lowerBound < $1.record.lowerBound }) {
            try checkProgress(deadline)
            guard entry.record.lowerBound >= previousEnd else { throw LambdaCodeError.invalidArchive }
            previousEnd = entry.record.upperBound
            let components = entry.path.split(separator: "/")
            for depth in 1..<components.count {
                let ancestor = components.prefix(depth).joined(separator: "/")
                if paths[ancestor] == false { throw LambdaCodeError.unsafeArchivePath }
            }
        }
        return entries
    }

    private static func validatedPath(
        _ bytes: Data, utf8: Bool, limits: LambdaCodePreviewLimits
    ) throws -> String {
        guard !bytes.isEmpty, bytes.count <= limits.maximumPathBytes,
              !bytes.contains(0), let name = String(data: bytes, encoding: utf8 ? .utf8 : cp437),
              !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":") else {
            throw LambdaCodeError.unsafeArchivePath
        }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let directory = parts.last == ""
        if directory { parts.removeLast() }
        while parts.first == "." { parts.removeFirst() }
        guard !parts.isEmpty, parts.count <= limits.maximumPathDepth,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LambdaCodeError.unsafeArchivePath
        }
        return parts.joined(separator: "/") + (directory ? "/" : "")
    }

    private static func validateExtra(_ data: Data, range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor + 4 <= range.upperBound else { throw LambdaCodeError.invalidArchive }
            let type = data.u16(cursor)
            let size = Int(data.u16(cursor + 2))
            guard cursor + 4 + size <= range.upperBound else { throw LambdaCodeError.invalidArchive }
            // ZIP64 and alternate path/link metadata are not interpreted by this reader.
            guard type != 0x0001, type != 0x7075, type != 0x756e,
                  !(type == 0x000d && size > 12) else { throw LambdaCodeError.unsupportedArchive }
            cursor += 4 + size
        }
    }

    private static func readPayload(
        _ data: Data, entry: Entry, deadline: TimeInterval,
        consume: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        try data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self)
            if entry.method == 0 {
                var offset = entry.payload.lowerBound
                while offset < entry.payload.upperBound {
                    try checkProgress(deadline)
                    let count = min(65_536, entry.payload.upperBound - offset)
                    try consume(UnsafeBufferPointer(start: input.baseAddress! + offset, count: count))
                    offset += count
                }
                return
            }
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw LambdaCodeError.invalidArchive
            }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress! + entry.payload.lowerBound)
            stream.avail_in = uInt(entry.payload.count)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            try buffer.withUnsafeMutableBufferPointer { output in
                while true {
                    try checkProgress(deadline)
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    let before = stream.avail_in
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let written = output.count - Int(stream.avail_out)
                    if written > 0 { try consume(UnsafeBufferPointer(start: output.baseAddress, count: written)) }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw LambdaCodeError.invalidArchive }
                        break
                    }
                    guard status == Z_OK, written > 0 || stream.avail_in < before else {
                        throw LambdaCodeError.invalidArchive
                    }
                }
            }
        }
    }

    private static func checkProgress(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw LambdaCodeError.extractionTimedOut }
    }

    private static let textExtensions: Set<String> = [
        "c", "conf", "cpp", "cs", "css", "go", "h", "html", "java", "js", "json",
        "jsx", "kt", "mjs", "php", "properties", "py", "rb", "rs", "sh", "swift",
        "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]

    private static let cp437 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
    )
}

private extension Data {
    // Each caller checks record bounds before reading. The fallback also makes
    // optional descriptor probes safe at the end of truncated input.
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
