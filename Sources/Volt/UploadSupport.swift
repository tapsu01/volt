import Foundation

enum UploadConflictBatchPolicy {
    case replace, keepBoth, skip
}

/// State is confined to the main actor, including conflict prompts and path reservations.
@MainActor
final class UploadBatchContext {
    let id = UUID()
    let connection: SavedConnection
    let credential: SensitiveCredential
    let tabID: UUID?
    let remoteRoot: String
    let planningLimiter = TransferLimiter(limit: 1)
    var policy: UploadConflictBatchPolicy?
    var reservedPaths: Set<String> = []
    var reservedDirectories: Set<String> = []
    var dirtyDirectories: Set<String> = []
    var warnings: [String] = []
    private(set) var pending: Set<UUID> = []

    init(connection: SavedConnection, credential: SensitiveCredential, tabID: UUID?, remoteRoot: String) {
        self.connection = connection
        self.credential = credential
        self.tabID = tabID
        self.remoteRoot = remoteRoot
    }

    func register(_ id: UUID) { pending.insert(id) }

    /// Duplicate completions cannot trigger another refresh.
    func finish(_ id: UUID) -> Bool {
        guard pending.remove(id) != nil else { return false }
        return pending.isEmpty
    }

    func changed(_ path: String, isDirectory: Bool = false) {
        dirtyDirectories.insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        if isDirectory { dirtyDirectories.insert(path) }
    }
}

struct UploadRefreshKey: Hashable, Sendable {
    let tabID: UUID
    let connectionID: UUID

    func matches(tabID: UUID?, connectionID: UUID?, path: String, dirtyPaths: Set<String>) -> Bool {
        self.tabID == tabID && self.connectionID == connectionID && dirtyPaths.contains(path)
    }
}

final class UploadFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var first: (any Error)?
    func record(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = error }
    }
    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }
}

enum UploadWorkers {
    static func run(files: [PlannedUploadFile], limiter: TransferLimiter, control: TransferControl,
                    failure: UploadFailure = UploadFailure(),
                    operation: @escaping @Sendable ([PlannedUploadFile]) async throws -> Void) async throws {
        guard !files.isEmpty else {
            if control.isCancelled { throw CancellationError() }
            return
        }
        let count = min(4, files.count)
        var batches = Array(repeating: [PlannedUploadFile](), count: count)
        for (index, file) in files.enumerated() { batches[index % count].append(file) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for batch in batches {
                group.addTask {
                    do {
                        try await limiter.withPermit(control: control) { try await operation(batch) }
                    } catch {
                        failure.record(error)
                        control.cancel()
                        throw error
                    }
                }
            }
            do { try await group.waitForAll() } catch {
                control.cancel()
                group.cancelAll()
                throw failure.error ?? error
            }
        }
    }
}

struct LocalUploadEntry: Sendable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let size: UInt64
}

struct LocalUploadScan: Sendable {
    var entries: [LocalUploadEntry] = []
    var skippedItems = 0

    static func collect(root: URL, control: TransferControl, limits: TraversalLimits = .standard) throws -> Self {
        let state = TraversalState(scope: "Folder upload", limits: limits)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var scan = Self()
        func checkCancellation() throws {
            try Task.checkCancellation()
            if control.isCancelled { throw CancellationError() }
        }
        func visit(_ url: URL, relative: String, depth: Int) throws {
            try checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { scan.skippedItems += 1; return }
            guard values.isDirectory == true else {
                guard values.isRegularFile == true else { scan.skippedItems += 1; return }
                scan.entries.append(LocalUploadEntry(url: url, relativePath: relative, isDirectory: false,
                                                     size: UInt64(max(0, values.fileSize ?? 0))))
                return
            }
            try state.visitDirectory(depth: depth)
            scan.entries.append(LocalUploadEntry(url: url, relativePath: relative, isDirectory: true, size: 0))
            var enumerationError: Error?
            // Shallow enumeration avoids allocating an unbounded array before checking the budget.
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw AppError.commandFailed("Could not scan \(url.path)") }
            while let child = enumerator.nextObject() as? URL {
                try checkCancellation()
                try state.visitEntries(1)
                let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                try visit(child, relative: childRelative, depth: depth + 1)
            }
            if let enumerationError { throw enumerationError }
        }
        try visit(root, relative: "", depth: 0)
        return scan
    }
}

struct PlannedUploadFile: Sendable {
    let localPath: String
    let remotePath: String
    let size: UInt64
    let policy: UploadPublishPolicy
}

struct FolderUploadPlan: Sendable {
    var files: [PlannedUploadFile] = []
    var skippedItems = 0
    var warnings: [String] = []

    var totalBytes: UInt64 {
        get throws {
            try files.reduce(0) { sum, file in
                let (value, overflow) = sum.addingReportingOverflow(file.size)
                guard !overflow else { throw AppError.commandFailed("Folder upload size is too large.") }
                return value
            }
        }
    }
}

/// O(1) progress aggregation; callbacks from C workers are synchronous and may race.
final class UploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: UInt64] = [:]
    private var transferred: UInt64 = 0
    private var completed = 0
    private var warnings = 0
    private var lastUpdate: TimeInterval = 0
    let total: UInt64

    init(total: UInt64) { self.total = total }

    func update(_ path: String, bytes count: UInt64, completed: Bool = false, warning: Bool = false)
        -> (transferred: UInt64, completed: Int, warnings: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let previous = bytes[path] ?? 0
        let bounded = max(previous, min(count, total))
        transferred += min(bounded - previous, total - transferred)
        bytes[path] = bounded
        if completed { self.completed += 1 }
        if warning { warnings += 1 }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastUpdate >= 0.1 else { return nil }
        lastUpdate = now
        return (transferred, self.completed, warnings)
    }

    var snapshot: (transferred: UInt64, completed: Int, warnings: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (transferred, completed, warnings)
    }
}
