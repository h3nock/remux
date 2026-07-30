import Foundation
import XCTest

@testable import Remux

final class TerminalPreviewFileLoaderTests: XCTestCase {
    func testStreamsToUniqueFileUsingMonotonicOffsetsAndCleansOnRelease() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let recorder = PreviewReadRecorder()
        let provider = PreviewSFTPProvider(client: PreviewSFTPClient(
            data: Data("abcdefghij".utf8),
            declaredSize: 10,
            recorder: recorder
        ))
        let loader = TerminalPreviewFileLoader(
            provider: provider,
            temporaryDirectory: tempRoot,
            maximumByteCount: 64
        )

        var resource: TerminalPreviewFileResource? = try await loader.load(
            remotePath: "/srv/report.final.txt"
        )
        let fileURL = try XCTUnwrap(resource?.url)
        XCTAssertEqual(fileURL.lastPathComponent, "report.final.txt")
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("abcdefghij".utf8))
        let offsets = await recorder.offsets()
        XCTAssertEqual(offsets, [0, 10])
        let scopedDirectory = fileURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedDirectory.path))

        resource = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopedDirectory.path))
    }

    func testStagesExtensionlessPlainTextWithTextExtension() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let contents = Data("127.0.0.1\tlocalhost\n::1\tlocalhost\n".utf8)
        let loader = TerminalPreviewFileLoader(
            provider: PreviewSFTPProvider(client: PreviewSFTPClient(
                data: contents,
                declaredSize: UInt64(contents.count),
                recorder: PreviewReadRecorder()
            )),
            temporaryDirectory: tempRoot,
            maximumByteCount: 64
        )

        let resource = try await loader.load(remotePath: "/etc/hosts")

        XCTAssertEqual(resource.url.lastPathComponent, "hosts.txt")
        XCTAssertEqual(try Data(contentsOf: resource.url), contents)
    }

    func testRecognizesPlainTextWhenUTF8SequenceSpansReadChunks() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let contents = Data("A😀B\n".utf8)
        let loader = TerminalPreviewFileLoader(
            provider: PreviewSFTPProvider(client: PreviewSFTPClient(
                data: contents,
                declaredSize: UInt64(contents.count),
                recorder: PreviewReadRecorder(),
                maximumReturnedChunkLength: 2
            )),
            temporaryDirectory: tempRoot,
            maximumByteCount: 64
        )

        let resource = try await loader.load(remotePath: "/tmp/Makefile")

        XCTAssertEqual(resource.url.lastPathComponent, "Makefile.txt")
        XCTAssertEqual(try Data(contentsOf: resource.url), contents)
    }

    func testDoesNotRelabelExtensionlessBinaryAsText() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let contents = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let loader = TerminalPreviewFileLoader(
            provider: PreviewSFTPProvider(client: PreviewSFTPClient(
                data: contents,
                declaredSize: UInt64(contents.count),
                recorder: PreviewReadRecorder()
            )),
            temporaryDirectory: tempRoot,
            maximumByteCount: 64
        )

        let resource = try await loader.load(remotePath: "/tmp/artifact")

        XCTAssertEqual(resource.url.lastPathComponent, "artifact")
        XCTAssertEqual(try Data(contentsOf: resource.url), contents)
    }

    func testRejectsDeclaredOversizeWithoutReadingOrLeavingTempFiles() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let recorder = PreviewReadRecorder()
        let loader = TerminalPreviewFileLoader(
            provider: PreviewSFTPProvider(client: PreviewSFTPClient(
                data: Data("abcdef".utf8),
                declaredSize: 6,
                recorder: recorder
            )),
            temporaryDirectory: tempRoot,
            maximumByteCount: 5
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await loader.load(remotePath: "/srv/large.bin")
        } verify: { error in
            XCTAssertEqual(
                error as? TerminalPreviewFileError,
                .tooLarge(maximumByteCount: 5)
            )
        }
        let offsets = await recorder.offsets()
        XCTAssertEqual(offsets, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), [])
    }

    func testRejectsActualOversizeWhenServerOmitsSizeAndCleansTempFiles() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let recorder = PreviewReadRecorder()
        let loader = TerminalPreviewFileLoader(
            provider: PreviewSFTPProvider(client: PreviewSFTPClient(
                data: Data("abcdef".utf8),
                declaredSize: nil,
                recorder: recorder
            )),
            temporaryDirectory: tempRoot,
            maximumByteCount: 5
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await loader.load(remotePath: "/srv/unknown-size.bin")
        } verify: { error in
            XCTAssertEqual(
                error as? TerminalPreviewFileError,
                .tooLarge(maximumByteCount: 5)
            )
        }
        let offsets = await recorder.offsets()
        XCTAssertEqual(offsets, [0])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), [])
    }

    func testCancellationDuringReadCleansPartialTempFile() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let recorder = PreviewReadRecorder()
        let loader = TerminalPreviewFileLoader(
            provider: PreviewSFTPProvider(client: PreviewSFTPClient(
                data: Data("abcdefgh".utf8),
                declaredSize: nil,
                recorder: recorder,
                delayFromOffset: 8
            )),
            temporaryDirectory: tempRoot,
            maximumByteCount: 8
        )

        let task = Task {
            try await loader.load(remotePath: "/srv/cancelled.txt")
        }
        for _ in 0..<100 {
            if await recorder.offsets().contains(8) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), [])
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalPreviewFileLoaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private struct PreviewSFTPProvider: RemuxSFTPClientProvider {
    let client: PreviewSFTPClient

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (PreviewSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await operation(client)
    }
}

private struct PreviewSFTPClient: RemuxSFTPReadOnlyClient {
    let data: Data
    let declaredSize: UInt64?
    let recorder: PreviewReadRecorder
    var delayFromOffset: UInt64? = nil
    var maximumReturnedChunkLength: Int? = nil

    func realPath(atPath path: String) async throws -> String {
        path
    }

    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry] {
        []
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        RemuxSFTPFileMetadata(
            size: declaredSize,
            permissions: nil,
            modificationDate: nil
        )
    }

    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        try await metadata(atPath: path)
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        let data = data
        let recorder = recorder
        return try await operation(RemuxSFTPReadableFile { offset, length in
            await recorder.record(offset: offset, length: Int(length))
            if let delayFromOffset, offset >= delayFromOffset {
                try await Task.sleep(for: .seconds(10))
            }
            let start = min(Int(offset), data.count)
            let returnedLength = min(
                Int(length),
                maximumReturnedChunkLength ?? Int(length)
            )
            let end = min(start + returnedLength, data.count)
            return data.subdata(in: start..<end)
        })
    }
}

private actor PreviewReadRecorder {
    private var requests: [(UInt64, Int)] = []

    func record(offset: UInt64, length: Int) {
        requests.append((offset, length))
    }

    func offsets() -> [UInt64] {
        requests.map(\.0)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
