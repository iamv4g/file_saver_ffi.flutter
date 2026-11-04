import XCTest

@testable import file_saver_ffi

/// The bytes that saves to a directory report through `onProgress`.
final class SaveProgressTests: XCTestCase {
    private struct Update: Equatable {
        let bytes: Int64
        let total: Int64?

        init(_ bytes: Int64, _ total: Int64?) {
            self.bytes = bytes
            self.total = total
        }
    }

    /// Collects the updates of a save. Downloads report on URLSession's queue.
    private final class Recorder {
        private let lock = NSLock()
        private var _updates: [Update] = []

        var updates: [Update] {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }

        func record(_ bytes: Int64, _ total: Int64?) {
            lock.lock()
            _updates.append(Update(bytes, total))
            lock.unlock()
        }
    }

    private var directory: URL!
    private let recorder = Recorder()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveProgressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var chunk: Int64 { Int64(Constants.chunkSize) }

    // MARK: - Bytes and files

    func testSavingBytesReportsTheBytesWrittenOfTheSize() throws {
        let data = Data(count: 2 * Constants.chunkSize + 1)
        let size = Int64(data.count)

        try CustomFileSaver().saveBytesAs(
            fileData: data,
            directoryURL: directory,
            fileName: "a.bin",
            conflictResolution: .autoRename,
            onProgress: recorder.record,
            onSuccess: { _ in },
            cancellationToken: nil
        )

        XCTAssertEqual(recorder.updates, [Update(chunk, size), Update(2 * chunk, size), Update(size, size)])
    }

    func testSavingAFileReportsTheBytesCopiedOfItsSize() throws {
        let source = directory.appendingPathComponent("source.bin")
        try Data(count: 2 * Constants.chunkSize + 1).write(to: source)
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let size = Int64(2 * Constants.chunkSize + 1)

        try CustomFileSaver().saveFileAs(
            filePath: source.path,
            directoryURL: target,
            fileName: "copy.bin",
            conflictResolution: .autoRename,
            onProgress: recorder.record,
            onSuccess: { _ in },
            cancellationToken: nil
        )

        XCTAssertEqual(recorder.updates, [Update(chunk, size), Update(2 * chunk, size), Update(size, size)])
    }

    func testASkipReportsNoProgress() throws {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("a.txt").path, contents: Data("x".utf8))
        var saved: String?

        try CustomFileSaver().saveBytesAs(
            fileData: Data("hello".utf8),
            directoryURL: directory,
            fileName: "a.txt",
            conflictResolution: .skip,
            onProgress: recorder.record,
            onSuccess: { saved = $0 },
            cancellationToken: nil
        )

        XCTAssertNotNil(saved)
        XCTAssertEqual(recorder.updates, [])
    }

    // MARK: - Downloads

    /// 256 KiB that gzip compresses well.
    private let payload = Data((0..<256 * 1024).map { UInt8($0 % 251) })

    /// Downloads `path` of a `TestHTTPServer` into `directory`, and returns the
    /// file's content.
    private func download(_ path: String) throws -> Data {
        let server = try TestHTTPServer(payload: payload)
        defer { server.close() }
        let done = expectation(description: "download")
        var saved: String?
        var failure: FileSaverError?

        CustomFileSaver().saveNetworkAs(
            urlString: server.url(path),
            headers: nil,
            timeoutSeconds: 10,
            directoryURL: directory,
            fileName: "download.bin",
            conflictResolution: .autoRename,
            onProgress: recorder.record,
            onSuccess: { saved = $0 },
            onError: { failure = $0 },
            onCancelled: {},
            onCancelHandlerReady: { _ in },
            onComplete: { done.fulfill() },
            cancellationToken: nil
        )
        wait(for: [done], timeout: 10)

        XCTAssertNil(failure)
        let url = try XCTUnwrap(saved.flatMap(URL.init(string:)))
        return try Data(contentsOf: url)
    }

    /// Checks that the byte counts grow up to the payload's size.
    private func assertBytesGrowToThePayloadSize(file: StaticString = #filePath, line: UInt = #line) {
        let bytes = recorder.updates.map(\.bytes)
        XCTAssertFalse(bytes.isEmpty, file: file, line: line)
        XCTAssertEqual(bytes, bytes.sorted(), file: file, line: line)
        XCTAssertEqual(bytes.last, Int64(payload.count), file: file, line: line)
    }

    func testADownloadReportsTheBytesOfItsContentLength() throws {
        XCTAssertEqual(try download("/sized"), payload)

        assertBytesGrowToThePayloadSize()
        XCTAssertEqual(Set(recorder.updates.map(\.total)), [Int64(payload.count)])
    }

    func testADownloadWithoutContentLengthReportsTheBytesOfAnUnknownSize() throws {
        XCTAssertEqual(try download("/chunked"), payload)

        assertBytesGrowToThePayloadSize()
        XCTAssertEqual(recorder.updates.map(\.total), recorder.updates.map { _ in nil })
    }

    /// URLSession writes the body decompressed, so the Content-Length of the
    /// encoded body isn't the size of the file.
    func testACompressedDownloadReportsTheBytesOfAnUnknownSize() throws {
        XCTAssertEqual(try download("/gzip"), payload)

        assertBytesGrowToThePayloadSize()
        XCTAssertEqual(recorder.updates.map(\.total), recorder.updates.map { _ in nil })
    }

    func testTheDownloadSizeIsTheExpectedLengthOfAnUncompressedBody() {
        func response(_ headers: [String: String]) -> HTTPURLResponse? {
            HTTPURLResponse(url: URL(string: "http://a")!, statusCode: 200, httpVersion: nil, headerFields: headers)
        }

        XCTAssertEqual(NetworkHelper.downloadSize(10, of: response([:])), 10)
        XCTAssertEqual(NetworkHelper.downloadSize(10, of: response(["Content-Encoding": "identity"])), 10)
        XCTAssertNil(NetworkHelper.downloadSize(10, of: response(["Content-Encoding": "gzip"])))
        XCTAssertNil(NetworkHelper.downloadSize(10, of: response(["content-encoding": "br"])))
        XCTAssertNil(NetworkHelper.downloadSize(NSURLSessionTransferSizeUnknown, of: response([:])))
        XCTAssertNil(NetworkHelper.downloadSize(0, of: nil))
    }
}
