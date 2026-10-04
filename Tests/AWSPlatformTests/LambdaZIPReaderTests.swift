import Foundation
import XCTest
@testable import AWSPlatform

final class LambdaZIPReaderTests: XCTestCase {
    func testEmptyArchiveHasNoFiles() throws {
        XCTAssertTrue(try read([]).isEmpty)
    }

    func testStoredFilesPreserveUnicodeContentAndSortNestedPaths() throws {
        let files = try read([
            .init("src/处理.py", text: "print('你好')\n", flags: 0x0800),
            .init("README.txt", text: "Lambda source"),
            .init("src/", data: Data(), unixMode: 0o040755),
            .init("src/index.js", text: "exports.handler = async () => {};"),
        ])

        XCTAssertEqual(files.map(\.path), ["README.txt", "src/index.js", "src/处理.py"])
        XCTAssertEqual(files.last?.content, "print('你好')\n")
        XCTAssertTrue(files.allSatisfy { !$0.isBinary })
    }

    func testDotPrefixedArchivePathsAreNormalized() throws {
        let files = try read([.init("./src/main.py", text: "pass")])
        XCTAssertEqual(files.map(\.path), ["src/main.py"])
        assertRejected([
            .init("./src/main.py", text: "one"),
            .init("src/main.py", text: "two"),
        ], as: .unsafeArchivePath)
    }

    func testDeflatedSourceSupportsCompressedAndStoredDeflateBlocks() throws {
        let text = String(repeating: "print('hello')\n", count: 20)
        let files = try read([
            .init("compressed.py", text: text, method: 8,
                  compressedData: Data(base64Encoded: "KyjKzCvRUM9IzcnJV9fkKhjl4uYCAA==")!),
            .init("stored-block.py", text: text, method: 8),
        ])

        XCTAssertEqual(files.map(\.content), [text, text])
    }

    func testDataDescriptorsWithAndWithoutSignatureAreAccepted() throws {
        for signature in [true, false] {
            let files = try read([
                .init("handler.py", text: "def handler(): pass\n", method: 8,
                      usesDescriptor: true, descriptorSignature: signature),
            ])
            XCTAssertEqual(files.first?.content, "def handler(): pass\n")
        }
    }

    func testBinaryInvalidUTF8AndOversizedFilesRemainListedWithoutPreview() throws {
        var limits = LambdaCodePreviewLimits()
        limits.maximumFilePreviewBytes = 4
        let files = try read([
            .init("binary.so", data: Data([1, 2, 3])),
            .init("invalid.py", data: Data([0xff, 0xfe])),
            .init("large.py", text: "12345"),
            .init("small.py", text: "1234"),
        ], limits: limits)

        XCTAssertEqual(files.map(\.path), ["binary.so", "invalid.py", "large.py", "small.py"])
        XCTAssertTrue(files.dropLast().allSatisfy { $0.isBinary && $0.content == nil })
        XCTAssertEqual(files.last?.content, "1234")
    }

    func testHiddenFilesAndHiddenDirectoriesAreNotDisplayed() throws {
        let files = try read([
            .init(".env", text: "hidden"),
            .init(".hidden/module.py", text: "hidden"),
            .init("src/.hidden.py", text: "hidden"),
            .init("src/main.py", text: "visible"),
        ])

        XCTAssertEqual(files.map(\.path), ["src/main.py"])
    }

    func testHiddenEntriesStillCountTowardExpandedLimit() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumExpandedBytes = 5
        assertRejected([
            .init(".hidden.py", text: "123456"),
        ], as: .archiveTooLarge, limits: limits)
    }

    func testHiddenEntriesStillRequireValidCRC() {
        assertRejected([
            .init(".hidden.py", text: "hidden", crc: 1),
        ], as: .invalidArchive)
    }

    func testBinaryEntriesStillRequireValidCRC() {
        assertRejected([
            .init("binary.so", data: Data([1, 2, 3]), crc: 1),
        ], as: .invalidArchive)
    }

    func testArchiveByteLimitIsEnforcedBeforeReadingContents() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumDownloadBytes = 30
        assertRejected([.init("handler.py", text: "pass")], as: .downloadTooLarge, limits: limits)
    }

    func testExpandedLimitAcceptsExactBoundaryAndRejectsDeclaredExcess() throws {
        var limits = LambdaCodePreviewLimits()
        limits.maximumExpandedBytes = 5
        XCTAssertEqual(try read([.init("handler.py", text: "12345")], limits: limits).first?.content, "12345")
        assertRejected([.init("handler.py", text: "123456")], as: .archiveTooLarge, limits: limits)
    }

    func testExpandedLimitIncludesAllFilesNotJustPreviewableFiles() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumExpandedBytes = 5
        assertRejected([
            .init("one.py", text: "123"),
            .init("binary.so", data: Data([1, 2, 3])),
        ], as: .archiveTooLarge, limits: limits)
    }

    func testForgedUncompressedSizeCannotBypassActualExpandedLimit() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumExpandedBytes = 128
        assertRejected([
            .init("bomb.py", data: Data(repeating: 65, count: 4096), method: 8,
                  compressedData: Data(base64Encoded: "7cEBDQAAAMKgbO9fyh4OKAAAAODdAA==")!,
                  declaredExpandedSize: 1),
        ], as: .archiveTooLarge, limits: limits)
    }

    func testFileCountLimitIncludesHiddenAndDirectoryEntries() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumEntries = 2
        assertRejected([
            .init("src/", data: Data(), unixMode: 0o040755),
            .init("src/.hidden.py", text: "pass"),
            .init("src/main.py", text: "pass"),
        ], as: .tooManyFiles, limits: limits)
    }

    func testPreviewBudgetIsCumulativeAndAcceptsExactBoundary() throws {
        var limits = LambdaCodePreviewLimits()
        limits.maximumTotalPreviewBytes = 6
        let entries: [ZIPEntryFixture] = [
            .init("one.py", text: "123"),
            .init("two.py", text: "456"),
        ]
        XCTAssertEqual(try read(entries, limits: limits).count, 2)

        limits.maximumTotalPreviewBytes = 5
        assertRejected(entries, as: .previewTooLarge, limits: limits)
    }

    func testPreviewBudgetCountsUTF8BytesInsteadOfCharacters() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumTotalPreviewBytes = 3
        assertRejected([.init("main.py", text: "你好")], as: .previewTooLarge, limits: limits)
    }

    func testUnsupportedAndOversizedFilesDoNotConsumePreviewBudget() throws {
        var limits = LambdaCodePreviewLimits()
        limits.maximumFilePreviewBytes = 4
        limits.maximumTotalPreviewBytes = 4
        let files = try read([
            .init("binary.bin", data: Data(repeating: 65, count: 20)),
            .init("large.py", text: "12345"),
            .init("main.py", text: "1234"),
            .init(".hidden.py", text: "1234"),
        ], limits: limits)
        XCTAssertEqual(files.first { $0.path == "main.py" }?.content, "1234")
    }

    func testPathLengthUsesUTF8BytesAndPathDepthHasALimit() {
        var limits = LambdaCodePreviewLimits()
        limits.maximumPathBytes = 10
        assertRejected([.init("源代码.py", text: "pass", flags: 0x0800)], as: .unsafeArchivePath, limits: limits)

        limits = LambdaCodePreviewLimits()
        limits.maximumPathDepth = 2
        assertRejected([.init("a/b/main.py", text: "pass")], as: .unsafeArchivePath, limits: limits)
    }

    func testUnsafeArchivePathsAreRejected() {
        for path in ["../escape.py", "src/../../escape.py", "/absolute.py", "C:\\escape.py",
                     "src\\main.py", "src/\0main.py"] {
            assertRejected([.init(path, text: "pass")], as: .unsafeArchivePath)
        }
    }

    func testSymbolicLinksAndSpecialFilesAreRejected() {
        for mode in [UInt32(0o120777), 0o010600, 0o020600, 0o060600, 0o140600] {
            assertRejected([
                .init("handler.py", text: "../outside", unixMode: mode),
            ], as: .unsupportedArchive)
        }
    }

    func testDuplicatePathsAreRejected() {
        assertRejected([
            .init("handler.py", text: "one"),
            .init("handler.py", text: "two"),
        ], as: .unsafeArchivePath)
    }

    func testFileDirectoryConflictsAreRejectedRegardlessOfEntryOrder() {
        let file = ZIPEntryFixture("src", text: "file")
        let nested = ZIPEntryFixture("src/handler.py", text: "pass")
        for entries in [[file, nested], [nested, file]] {
            assertRejected(entries, as: .unsafeArchivePath)
        }
        assertRejected([
            .init("src", text: "file"),
            .init("src/", data: Data(), unixMode: 0o040755),
        ], as: .unsafeArchivePath)
    }

    func testUnsupportedCompressionMethodsAreRejected() {
        assertRejected([.init("main.py", text: "pass", method: 12)], as: .unsupportedArchive)
    }

    func testEncryptionAndUnsupportedFlagsAreRejected() {
        for flags: UInt16 in [0x0001, 0x0020, 0x0040, 0x2000] {
            assertRejected([.init("main.py", text: "pass", flags: flags)], as: .unsupportedArchive)
        }
    }

    func testZIP64AndMultiDiskArchivesAreRejected() throws {
        let entries: [ZIPEntryFixture] = [.init("main.py", text: "pass")]
        var zip64 = makeZIP(entries)
        zip64.replaceInteger(at: zip64.count - 12, with: UInt16.max)
        try withArchive(zip64) { url in
            assertReadError(url, as: .unsupportedArchive)
        }
        var multiDisk = makeZIP(entries)
        multiDisk.replaceInteger(at: multiDisk.count - 18, with: UInt16(1))
        try withArchive(multiDisk) { url in
            assertReadError(url, as: .unsupportedArchive)
        }
    }

    func testZIP64ExtraFieldIsRejected() {
        var extra = Data()
        extra.appendInteger(UInt16(0x0001))
        extra.appendInteger(UInt16(16))
        extra.appendInteger(UInt64(4))
        extra.appendInteger(UInt64(4))
        assertRejected([
            .init("main.py", text: "pass", extra: extra),
        ], as: .unsupportedArchive)
    }

    func testMismatchedCRCAndTruncatedArchiveAreRejected() throws {
        assertRejected([.init("main.py", text: "pass", crc: 1)], as: .invalidArchive)
        let complete = makeZIP([.init("main.py", text: "pass")])
        for amount in [1, 10, 22, complete.count - 1] {
            try withArchive(Data(complete.dropLast(amount))) { url in
                assertReadError(url, as: .invalidArchive)
            }
        }
    }

    func testCentralAndLocalNamesAndSizesMustAgree() {
        assertRejected([
            .init("main.py", text: "pass", localName: "evil.py"),
        ], as: .invalidArchive)
        assertRejected([
            .init("main.py", text: "pass", localExpandedSize: 3),
        ], as: .invalidArchive)
        assertRejected([
            .init("main.py", text: "pass", localCRC: 1),
        ], as: .invalidArchive)
    }

    func testDeclaredSizeMustMatchActualInflatedBytesEvenUnderBudget() {
        assertRejected([
            .init("main.py", text: "pass", method: 8, declaredExpandedSize: 2),
        ], as: .invalidArchive)
    }

    func testCorruptDataDescriptorsAreRejected() {
        assertRejected([
            .init("main.py", text: "pass", method: 8, usesDescriptor: true, descriptorCRC: 1),
        ], as: .invalidArchive)
        assertRejected([
            .init("main.py", text: "pass", method: 8, usesDescriptor: true, descriptorExpandedSize: 3),
        ], as: .invalidArchive)
    }

    func testOverlappingLocalRecordsAreRejectedEvenWhenTheirMetadataIsConsistent() throws {
        let inner = ZIPEntryFixture("inner.py", text: "pass")
        let innerArchive = makeZIP([inner])
        let innerCentral = Int(innerArchive.fixtureUInt32(at: innerArchive.count - 6))
        let prefix = Data([1, 2, 3, 4])
        let outerName = "outer.bin"
        let outer = ZIPEntryFixture(outerName, data: prefix + innerArchive.prefix(innerCentral) + Data([5, 6]))
        var archive = makeZIP([outer, inner])
        let central = Int(archive.fixtureUInt32(at: archive.count - 6))
        let secondCentral = central + 46 + outerName.utf8.count
        let embeddedLocal = 30 + outerName.utf8.count + prefix.count
        // Both entries have valid individual headers and CRCs; inner.py's local
        // record is now nested inside outer.bin's declared payload range.
        archive.replaceInteger(at: secondCentral + 42, with: UInt32(embeddedLocal))

        try withArchive(archive) { assertReadError($0, as: .invalidArchive) }
    }

    func testLocalHeaderAndPayloadCannotExtendIntoCentralDirectory() throws {
        let complete = makeZIP([.init("main.py", text: "pass")])
        let central = Int(complete.fixtureUInt32(at: complete.count - 6))
        var headerOverrun = complete
        headerOverrun.replaceInteger(at: central + 42, with: UInt32(central - 20))
        try withArchive(headerOverrun) { assertReadError($0, as: .invalidArchive) }

        var payloadOverrun = complete
        for field in [18, 22, central + 20, central + 24] {
            payloadOverrun.replaceInteger(at: field, with: UInt32(5))
        }
        try withArchive(payloadOverrun) { assertReadError($0, as: .invalidArchive) }
    }

    func testDataDescriptorCannotBorrowBytesFromCentralDirectory() throws {
        var archive = makeZIP([.init("main.py", text: "pass", method: 8, usesDescriptor: true)])
        let central = Int(archive.fixtureUInt32(at: archive.count - 6))
        // Remove only the final descriptor field while keeping a structurally
        // consistent central directory and EOCD at their new positions.
        archive.removeSubrange((central - 4)..<central)
        archive.replaceInteger(at: archive.count - 6, with: UInt32(central - 4))
        try withArchive(archive) { assertReadError($0, as: .invalidArchive) }
    }

    func testCentralDirectoryLengthAndOffsetMustDescribeItsExactRange() throws {
        let complete = makeZIP([.init("main.py", text: "pass")])
        let central = complete.fixtureUInt32(at: complete.count - 6)
        let length = complete.fixtureUInt32(at: complete.count - 10)
        for invalidLength in [length - 1, length + 1] {
            var archive = complete
            archive.replaceInteger(at: archive.count - 10, with: invalidLength)
            try withArchive(archive) { assertReadError($0, as: .invalidArchive) }
        }
        for invalidOffset in [central - 1, central + 1, UInt32(complete.count)] {
            var archive = complete
            archive.replaceInteger(at: archive.count - 6, with: invalidOffset)
            try withArchive(archive) { assertReadError($0, as: .invalidArchive) }
        }
    }

    func testTruncatedOrTrailingDeflatePayloadIsRejected() {
        var compressed = Data(base64Encoded: "KyjKzCvRUM9IzcnJV9fkKhjl4uYCAA==")!
        let data = Data(String(repeating: "print('hello')\n", count: 20).utf8)
        assertRejected([
            .init("main.py", data: data, method: 8, compressedData: Data(compressed.dropLast())),
        ], as: .invalidArchive)
        compressed.append(0x00)
        assertRejected([
            .init("main.py", data: data, method: 8, compressedData: compressed),
        ], as: .invalidArchive)
    }

    func testReadingSourceNeverExtractsArchiveEntriesToDisk() throws {
        try withArchive(makeZIP([.init("nested/handler.py", text: "pass")])) { url in
            XCTAssertEqual(try LambdaZIPReader.read(at: url).first?.content, "pass")
            let children = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            XCTAssertEqual(children, ["function.zip"])
        }
    }

    func testExpiredExtractionDeadlineStopsReading() throws {
        var limits = LambdaCodePreviewLimits()
        limits.extractionTimeout = 0
        assertRejected([.init("main.py", text: "pass")], as: .extractionTimedOut, limits: limits)
    }

    func testCancelledTaskStopsBeforeReadingArchive() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("function.zip")
        try makeZIP([.init("main.py", text: "pass")]).write(to: url)
        let gate = ZIPReadGate()
        let task = Task.detached {
            await gate.wait()
            return try LambdaZIPReader.read(at: url)
        }
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A cancelled preview must not finish reading the archive.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }

    func testCancellationAfterFirstInflatedChunkStopsBeforeProcessingRemainingBytes() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("function.zip")
        try makeZIP([largeDeflatedBinaryFixture()]).write(to: url)
        let started = expectation(description: "The first real deflate output chunk has been consumed")
        let gate = ZIPChunkGate(started: started)
        let task = Task.detached {
            try LambdaZIPReader.read(at: url) { bytes in
                gate.pauseFirstChunk(bytes: bytes, maximumWait: 5)
            }
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation during decompression must stop before completing the preview.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(gate.snapshot.chunks, 1)
        XCTAssertGreaterThan(gate.snapshot.bytes, 0)
        XCTAssertLessThan(gate.snapshot.bytes, 256 * 1_024)
    }

    func testPositiveTimeoutIsCheckedAfterDecompressionHasAlreadyStarted() throws {
        var limits = LambdaCodePreviewLimits()
        limits.extractionTimeout = 1
        let gate = ZIPChunkGate()
        try withArchive(makeZIP([largeDeflatedBinaryFixture()])) { url in
            XCTAssertThrowsError(try LambdaZIPReader.read(at: url, limits: limits) { bytes in
                // A bounded wait inside the first real output chunk moves beyond
                // the positive deadline without relying on machine throughput.
                gate.pauseFirstChunk(bytes: bytes, maximumWait: 1.05)
            }) { error in
                XCTAssertEqual(error as? LambdaCodeError, .extractionTimedOut)
            }
        }
        XCTAssertEqual(gate.snapshot.chunks, 1)
        XCTAssertGreaterThan(gate.snapshot.bytes, 0)
        XCTAssertLessThan(gate.snapshot.bytes, 256 * 1_024)
    }

    private func largeDeflatedBinaryFixture() -> ZIPEntryFixture {
        let compressed = Data(base64Encoded:
            "7cExAQAAAMKgbOtfytsOQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAvAE="
        )!
        return .init("binary.bin", data: Data(repeating: 65, count: 256 * 1_024), method: 8, compressedData: compressed)
    }

    private func read(
        _ entries: [ZIPEntryFixture],
        limits: LambdaCodePreviewLimits = .init()
    ) throws -> [LambdaCodeFile] {
        try withArchive(makeZIP(entries)) { try LambdaZIPReader.read(at: $0, limits: limits) }
    }

    private func assertRejected(
        _ entries: [ZIPEntryFixture],
        as expected: LambdaCodeError,
        limits: LambdaCodePreviewLimits = .init(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try withArchive(makeZIP(entries)) { url in
                assertReadError(url, as: expected, limits: limits, file: file, line: line)
            }
        } catch {
            XCTFail("Failed to create ZIP fixture: \(error)", file: file, line: line)
        }
    }

    private func assertReadError(
        _ url: URL,
        as expected: LambdaCodeError,
        limits: LambdaCodePreviewLimits = .init(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LambdaZIPReader.read(at: url, limits: limits), file: file, line: line) { error in
            guard let actual = error as? LambdaCodeError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func withArchive<T>(_ data: Data, body: (URL) throws -> T) throws -> T {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("function.zip")
        try data.write(to: url)
        return try body(url)
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LambdaZIPReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Small, independently encoded ZIP fixtures let tests corrupt individual metadata fields.
/// CRC and stored deflate construction deliberately do not use the production reader or zlib.
private struct ZIPEntryFixture {
    let name: String
    let data: Data
    var method: UInt16 = 0
    var flags: UInt16 = 0
    var compressedData: Data?
    var usesDescriptor = false
    var descriptorSignature = true
    var unixMode: UInt32 = 0o100644
    var extra = Data()
    var declaredExpandedSize: UInt32?
    var crc: UInt32?
    var localName: String?
    var localExpandedSize: UInt32?
    var localCRC: UInt32?
    var descriptorCRC: UInt32?
    var descriptorExpandedSize: UInt32?

    init(
        _ name: String,
        text: String? = nil,
        data: Data? = nil,
        method: UInt16 = 0,
        flags: UInt16 = 0,
        compressedData: Data? = nil,
        usesDescriptor: Bool = false,
        descriptorSignature: Bool = true,
        unixMode: UInt32 = 0o100644,
        extra: Data = Data(),
        declaredExpandedSize: UInt32? = nil,
        crc: UInt32? = nil,
        localName: String? = nil,
        localExpandedSize: UInt32? = nil,
        localCRC: UInt32? = nil,
        descriptorCRC: UInt32? = nil,
        descriptorExpandedSize: UInt32? = nil
    ) {
        self.name = name
        self.data = data ?? Data((text ?? "").utf8)
        self.method = method
        self.flags = flags
        self.compressedData = compressedData
        self.usesDescriptor = usesDescriptor
        self.descriptorSignature = descriptorSignature
        self.unixMode = unixMode
        self.extra = extra
        self.declaredExpandedSize = declaredExpandedSize
        self.crc = crc
        self.localName = localName
        self.localExpandedSize = localExpandedSize
        self.localCRC = localCRC
        self.descriptorCRC = descriptorCRC
        self.descriptorExpandedSize = descriptorExpandedSize
    }
}

private func makeZIP(_ entries: [ZIPEntryFixture]) -> Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
        let name = Data(entry.name.utf8)
        let localName = Data((entry.localName ?? entry.name).utf8)
        let compressed = entry.compressedData ?? (entry.method == 8 ? storedDeflate(entry.data) : entry.data)
        let crc = entry.crc ?? fixtureCRC32(entry.data)
        let size = entry.declaredExpandedSize ?? UInt32(entry.data.count)
        let flags = entry.flags | (entry.usesDescriptor ? 0x0008 : 0)
        let offset = UInt32(archive.count)

        archive.appendInteger(UInt32(0x04034b50))
        archive.appendInteger(UInt16(20))
        archive.appendInteger(flags)
        archive.appendInteger(entry.method)
        archive.appendInteger(UInt32(0)) // DOS timestamp and date.
        archive.appendInteger(entry.usesDescriptor ? 0 : (entry.localCRC ?? crc))
        archive.appendInteger(entry.usesDescriptor ? 0 : UInt32(compressed.count))
        archive.appendInteger(entry.usesDescriptor ? 0 : (entry.localExpandedSize ?? size))
        archive.appendInteger(UInt16(localName.count))
        archive.appendInteger(UInt16(entry.extra.count))
        archive.append(localName)
        archive.append(entry.extra)
        archive.append(compressed)

        if entry.usesDescriptor {
            if entry.descriptorSignature { archive.appendInteger(UInt32(0x08074b50)) }
            archive.appendInteger(entry.descriptorCRC ?? crc)
            archive.appendInteger(UInt32(compressed.count))
            archive.appendInteger(entry.descriptorExpandedSize ?? size)
        }

        central.appendInteger(UInt32(0x02014b50))
        central.appendInteger(UInt16(0x0314)) // UNIX host, ZIP 2.0.
        central.appendInteger(UInt16(20))
        central.appendInteger(flags)
        central.appendInteger(entry.method)
        central.appendInteger(UInt32(0))
        central.appendInteger(crc)
        central.appendInteger(UInt32(compressed.count))
        central.appendInteger(size)
        central.appendInteger(UInt16(name.count))
        central.appendInteger(UInt16(entry.extra.count))
        central.appendInteger(UInt16(0)) // Comment length.
        central.appendInteger(UInt16(0)) // Disk number.
        central.appendInteger(UInt16(0)) // Internal attributes.
        central.appendInteger(entry.unixMode << 16)
        central.appendInteger(offset)
        central.append(name)
        central.append(entry.extra)
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.appendInteger(UInt32(0x06054b50))
    archive.appendInteger(UInt16(0))
    archive.appendInteger(UInt16(0))
    archive.appendInteger(UInt16(entries.count))
    archive.appendInteger(UInt16(entries.count))
    archive.appendInteger(UInt32(central.count))
    archive.appendInteger(centralOffset)
    archive.appendInteger(UInt16(0))
    return archive
}

private func storedDeflate(_ data: Data) -> Data {
    var encoded = Data()
    var position = 0
    repeat {
        let length = min(data.count - position, Int(UInt16.max))
        encoded.append(position + length == data.count ? 1 : 0)
        encoded.appendInteger(UInt16(length))
        encoded.appendInteger(~UInt16(length))
        encoded.append(data.subdata(in: position..<(position + length)))
        position += length
    } while position < data.count
    return encoded
}

private func fixtureCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = .max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320)
        }
    }
    return crc ^ .max
}

private extension Data {
    func fixtureUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { result, byte in
            result | UInt32(self[offset + byte]) << (8 * byte)
        }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func replaceInteger<T: FixedWidthInteger>(at offset: Int, with value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
}

private final class ZIPChunkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let started: XCTestExpectation?
    private var released = false
    private var chunks = 0
    private var bytes = 0

    init(started: XCTestExpectation? = nil) {
        self.started = started
    }

    var snapshot: (chunks: Int, bytes: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (chunks, bytes)
    }

    func pauseFirstChunk(bytes count: Int, maximumWait: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        chunks += 1
        bytes += count
        guard chunks == 1 else { return }
        started?.fulfill()
        let deadline = Date().addingTimeInterval(maximumWait)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor ZIPReadGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
