import Foundation
import Testing
@testable import Volt

@Suite(.timeLimit(.minutes(1)))
struct UploadTests {
    @Test func remoteEditSurvivesRepeatedUploadsAndAtomicSaves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("edit.txt")
        let baseline = root.appendingPathComponent("original")
        try Data("initial".utf8).write(to: file)
        try Data("initial".utf8).write(to: baseline)
        var session = RemoteEditSession(remotePath: "/edit.txt", localPath: file.path,
                                        originalSnapshotPath: baseline.path, fileName: "edit.txt")
        let id = session.id
        try Data("first save".utf8).write(to: file, options: .atomic)
        let first = try RemoteEditUploadSnapshot(localPath: file.path)
        defer { first.remove() }
        // The editor replaces the local file while the first upload is in flight.
        try Data("second save".utf8).write(to: file, options: .atomic)
        session.state = .uploading
        try session.didUpload(first)
        #expect(session.id == id)
        #expect(session.state == .modified)
        #expect(session.lastPromptedChangeSignature == nil)
        #expect(try String(contentsOf: baseline, encoding: .utf8) == "first save")
        #expect(try String(contentsOf: file, encoding: .utf8) == "second save")
        let second = try RemoteEditUploadSnapshot(localPath: file.path)
        defer { second.remove() }
        try session.didUpload(second)
        #expect(session.state == .uploaded)
        #expect(session.id == id)
        #expect(try String(contentsOf: baseline, encoding: .utf8) == "second save")
        second.remove()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: baseline.path))
    }

    @Test func remoteEditFailedUploadPreservesBaselineAndWorkingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("edit.txt")
        let baseline = root.appendingPathComponent("original")
        try Data("saved".utf8).write(to: file)
        try Data("server".utf8).write(to: baseline)
        let snapshot = try RemoteEditUploadSnapshot(localPath: file.path)
        // Failure never promotes the upload snapshot to the diff baseline.
        snapshot.remove()
        #expect(try String(contentsOf: baseline, encoding: .utf8) == "server")
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved")
        let retry = try RemoteEditUploadSnapshot(localPath: file.path)
        defer { retry.remove() }
        #expect(retry.matches(localPath: file.path))
    }

    @Test func remoteEditSaveMonitoringDebouncesAndResumesAfterUpload() {
        let date = Date(timeIntervalSince1970: 100)
        var session = RemoteEditSession(remotePath: "/file", localPath: "/tmp/file", fileName: "file")
        let observation1 = session.observeSave(size: 10, modifiedAt: date, now: date)
        #expect(!observation1)
        let observation2 = session.observeSave(size: 10, modifiedAt: date, now: date.addingTimeInterval(0.7))
        #expect(!observation2)
        let observation3 = session.observeSave(size: 10, modifiedAt: date, now: date.addingTimeInterval(1.4))
        #expect(observation3)
        #expect(session.state == .modified) // also updated in Manual mode
        let observation4 = session.observeSave(size: 10, modifiedAt: date, now: date.addingTimeInterval(3))
        #expect(!observation4) // Later
        session.state = .uploading
        let observation5 = session.observeSave(size: 20, modifiedAt: date, now: date.addingTimeInterval(4))
        #expect(!observation5)
        #expect(session.state == .uploading)
        session.state = .modified
        session.lastPromptedChangeSignature = nil
        let observation6 = session.observeSave(size: 20, modifiedAt: date, now: date.addingTimeInterval(5))
        #expect(!observation6)
        let observation7 = session.observeSave(size: 20, modifiedAt: date, now: date.addingTimeInterval(7))
        #expect(observation7)
    }

    @Test @MainActor func batchCompletesOnlyOnceAfterEveryOutcome() {
        let batch = UploadBatchContext(connection: SavedConnection(), credential: SensitiveCredential(),
                                       tabID: UUID(), remoteRoot: "/uploads")
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { batch.register(id) }
        // The last selected file completes first; failed/skipped/cancelled jobs also finish.
        #expect(!batch.finish(ids[3]))
        #expect(!batch.finish(ids[0]))
        #expect(!batch.finish(ids[3]))
        #expect(!batch.finish(ids[2]))
        #expect(batch.finish(ids[1]))
        #expect(!batch.finish(ids[1]))
    }

    @Test @MainActor func batchesKeepIndependentConflictAndDirtyState() {
        let connection = SavedConnection()
        let first = UploadBatchContext(connection: connection, credential: SensitiveCredential(), tabID: UUID(), remoteRoot: "/one")
        let second = UploadBatchContext(connection: connection, credential: SensitiveCredential(), tabID: UUID(), remoteRoot: "/two")
        first.policy = .skip
        first.reservedPaths.insert("/one/file")
        first.changed("/one/subdir", isDirectory: true)
        #expect(second.policy == nil)
        #expect(second.reservedPaths.isEmpty)
        #expect(second.dirtyDirectories.isEmpty)
        #expect(first.dirtyDirectories == ["/one", "/one/subdir"])
        let key = UploadRefreshKey(tabID: first.tabID!, connectionID: connection.id)
        #expect(key.matches(tabID: first.tabID, connectionID: connection.id, path: "/one", dirtyPaths: first.dirtyDirectories))
        #expect(!key.matches(tabID: second.tabID, connectionID: connection.id, path: "/one", dirtyPaths: first.dirtyDirectories))
        #expect(!key.matches(tabID: first.tabID, connectionID: UUID(), path: "/one", dirtyPaths: first.dirtyDirectories))
        #expect(!key.matches(tabID: first.tabID, connectionID: connection.id, path: "/elsewhere", dirtyPaths: first.dirtyDirectories))
    }

    @Test func scanSkipsHiddenAndSymlinksAndHonorsLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: root.appendingPathComponent("sub/file"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let control = TransferControl { _, _ in }
        let scan = try LocalUploadScan.collect(root: root, control: control)
        #expect(Set(scan.entries.map(\.relativePath)) == ["", "sub", "sub/file"])
        #expect(scan.skippedItems == 1)
        #expect(scan.entries.last?.size == 3)
        for limits in [TraversalLimits(maxDepth: 0, maxDirectories: 10, maxEntries: 10, maxSearchResults: 1),
                       TraversalLimits(maxDepth: 10, maxDirectories: 1, maxEntries: 10, maxSearchResults: 1),
                       TraversalLimits(maxDepth: 10, maxDirectories: 10, maxEntries: 1, maxSearchResults: 1)] {
            #expect(throws: (any Error).self) { try LocalUploadScan.collect(root: root, control: control, limits: limits) }
        }
        control.cancel()
        #expect(throws: CancellationError.self) { try LocalUploadScan.collect(root: root, control: control) }
    }

    @Test func workersShareGlobalLimitAcrossFoldersAndReleaseAfterCompletion() async throws {
        let limiter = TransferLimiter(limit: 4)
        let probe = WorkerProbe()
        let files = (0..<24).map { PlannedUploadFile(localPath: "local-\($0)", remotePath: "/\($0)", size: 1, policy: .createNew) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await UploadWorkers.run(files: files, limiter: limiter, control: TransferControl { _, _ in }) { batch in
                        await probe.enter(count: batch.count)
                        try await Task.sleep(for: .milliseconds(30))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let result = await probe.snapshot
        #expect(result.peak <= 4)
        #expect(result.active == 0)
        #expect(result.files == 48)
        #expect(result.workers == 8) // four reused worker sessions per folder, not one per file
        try await limiter.withPermit(control: TransferControl { _, _ in }) {}
    }

    @Test func cancellationWhileQueuedDoesNotRunOrLeakPermit() async throws {
        let limiter = TransferLimiter(limit: 1)
        let gate = TestGate()
        let holder = Task {
            try await limiter.withPermit(control: TransferControl { _, _ in }) {
                await gate.enterAndWait()
            }
        }
        while !(await gate.entered) { await Task.yield() }
        let control = TransferControl { _, _ in }
        let queued = Task {
            try await limiter.withPermit(control: control) {
                _ = Issue.record("Cancelled queued work must not start")
            }
        }
        control.cancel()
        do { try await queued.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { throw error }
        await gate.release()
        try await holder.value
        try await limiter.withPermit(control: TransferControl { _, _ in }) {}
    }

    @Test func workerFailureStopsOthersAndPreservesOriginalError() async throws {
        let limiter = TransferLimiter(limit: 2)
        let control = TransferControl { _, _ in }
        let files = (0..<8).map { PlannedUploadFile(localPath: "\($0)", remotePath: "/\($0)", size: 1, policy: .createNew) }
        do {
            try await UploadWorkers.run(files: files, limiter: limiter, control: control) { _ in
                throw AppError.commandFailed("Injected publish rejection")
            }
            Issue.record("Expected failure")
        } catch { #expect(error.localizedDescription.contains("Injected publish rejection")) }
        #expect(control.isCancelled)
        try await limiter.withPermit(control: TransferControl { _, _ in }) {}
    }

    @Test func progressCountsPublishedFilesAndPermissionWarningsSeparately() throws {
        let progress = UploadProgress(total: 10)
        _ = progress.update("a", bytes: 6)
        #expect(progress.snapshot.completed == 0)
        _ = progress.update("a", bytes: 3) // delayed progress cannot move backwards
        _ = progress.update("b", bytes: 4, completed: true, warning: true)
        #expect(progress.snapshot.transferred == 10)
        #expect(progress.snapshot.completed == 1)
        #expect(progress.snapshot.warnings == 1)
        _ = progress.update("a", bytes: 6, completed: true)
        #expect(progress.snapshot.completed == 2)
        let plan = FolderUploadPlan(files: [
            PlannedUploadFile(localPath: "a", remotePath: "/a", size: UInt64.max, policy: .createNew),
            PlannedUploadFile(localPath: "b", remotePath: "/b", size: 1, policy: .createNew)
        ])
        #expect(throws: (any Error).self) { try plan.totalBytes }
    }

    @Test func scanTenThousandFilesAndDeepTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10000 {
            try Data("x".utf8).write(to: root.appendingPathComponent("file-\(index)"))
        }
        var directory = root
        for _ in 0..<64 {
            directory.appendPathComponent("level")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let started = ContinuousClock.now
        let scan = try await Task.detached {
            try LocalUploadScan.collect(root: root, control: TransferControl { _, _ in })
        }.value
        print("Upload scan: 10000 files + depth 64 in \(started.duration(to: .now))")
        #expect(scan.entries.count == 10065)
        #expect(scan.skippedItems == 0)
        directory.appendPathComponent("too-deep")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try LocalUploadScan.collect(root: root, control: TransferControl { _, _ in })
        }
    }
}

private actor WorkerProbe {
    var active = 0, peak = 0, files = 0, workers = 0
    func enter(count: Int) { active += 1; peak = max(peak, active); files += count; workers += 1 }
    func leave() { active -= 1 }
    var snapshot: (active: Int, peak: Int, files: Int, workers: Int) { (active, peak, files, workers) }
}

private actor TestGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
