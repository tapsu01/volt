#if canImport(XCTest)
import Foundation
import XCTest
@testable import Volt

final class AppPerformanceTests: XCTestCase {
    func testTraversalLimitsDepthDirectoriesEntriesAndMatches() throws {
        let limits = TraversalLimits(maxDepth: 1, maxDirectories: 2, maxEntries: 3, maxSearchResults: 2)

        let depthState = TraversalState(scope: "Test", limits: limits)
        try depthState.visitDirectory(depth: 0)
        try depthState.visitDirectory(depth: 1)
        XCTAssertThrowsError(try depthState.visitDirectory(depth: 2))

        let entryState = TraversalState(scope: "Test", limits: limits)
        try entryState.visitEntries(2)
        try entryState.visitEntries(1)
        XCTAssertThrowsError(try entryState.visitEntries(1))

        try entryState.recordMatch()
        try entryState.recordMatch()
        XCTAssertThrowsError(try entryState.recordMatch())
    }

    func testLocalSyncScanHonorsEntryLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<4 {
            try Data("item \(index)".utf8).write(to: root.appendingPathComponent("file-\(index).txt"))
        }
        let limits = TraversalLimits(maxDepth: 8, maxDirectories: 8, maxEntries: 3, maxSearchResults: 1)
        XCTAssertThrowsError(try AppModel.collectLocalSyncEntries(root: root.path, limits: limits))
    }

    func testRemoteDirectoryCacheUsesItemBudgetAndLRU() {
        var cache = RemoteDirectoryCache(maxDirectories: 2, maxItems: 2, maxEstimatedCost: 1_000_000)
        let first = listing(named: "first")
        let second = listing(named: "second")
        let third = listing(named: "third")
        cache.store(first, for: "first", now: Date(timeIntervalSince1970: 1))
        cache.store(second, for: "second", now: Date(timeIntervalSince1970: 2))
        XCTAssertNotNil(cache.listing(for: "first", now: Date(timeIntervalSince1970: 3)))
        cache.store(third, for: "third", now: Date(timeIntervalSince1970: 4))
        XCTAssertNotNil(cache.listing(for: "first"))
        XCTAssertNil(cache.listing(for: "second"))
        XCTAssertNotNil(cache.listing(for: "third"))
    }

    func testTerminalOutputUsesHysteresis() {
        var output = String(repeating: "a", count: 90)
        appendBoundedTerminalOutput(String(repeating: "b", count: 5), to: &output, retainedCount: 80, trimThreshold: 100)
        XCTAssertEqual(output.count, 95)
        appendBoundedTerminalOutput(String(repeating: "c", count: 10), to: &output, retainedCount: 80, trimThreshold: 100)
        XCTAssertEqual(output.count, 80)
        XCTAssertTrue(output.hasSuffix(String(repeating: "c", count: 10)))
    }

    func testCancelledFileItemComputationDoesNotPublishResult() async {
        let coordinator = FileItemComputationCoordinator()
        let items = (0..<10_000).map { index in
            FileItem(name: "file-\(index)", path: "/tmp/file-\(index)", isDirectory: false)
        }
        let task = Task {
            try await coordinator.compute(items: items, preferences: FileBrowserPreferences(), searchText: "file")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandRunnerDrainsAndBoundsLargeOutput() async throws {
        let result = try await CommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "/usr/bin/yes 0123456789 | /usr/bin/head -c 300000"],
            stdin: "",
            maximumOutputBytes: 64 * 1024
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 64 * 1024)
    }

    private func listing(named name: String) -> RemoteListingResult {
        RemoteListingResult(
            items: [FileItem(name: name, path: "/\(name)", isDirectory: false)],
            skippedUnsafeCount: 0,
            isTruncated: false
        )
    }
}

#else
#warning("XCTest is unavailable: run this legacy suite with a full Xcode toolchain. UploadTests uses Swift Testing.")
#endif
