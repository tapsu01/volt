import Foundation

func filteredSortedFileItems(
    items: [FileItem],
    preferences: FileBrowserPreferences,
    searchText: String
) -> [FileItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return items
        .filter { preferences.showHiddenFiles || !$0.isHidden }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        .sorted { lhs, rhs in
            fileItemsSortBefore(lhs, rhs, preferences: preferences)
        }
}

private func fileItemsSortBefore(_ lhs: FileItem, _ rhs: FileItem, preferences: FileBrowserPreferences) -> Bool {
    if preferences.foldersFirst && lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
    let order: ComparisonResult = switch preferences.sortField {
    case .name: lhs.name.localizedStandardCompare(rhs.name)
    case .size: compareFileItemValues(lhs.size ?? -1, rhs.size ?? -1)
    case .date: compareFileItemValues(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
    case .kind: lhs.kind.localizedStandardCompare(rhs.kind)
    case .owner: (lhs.owner ?? "").localizedStandardCompare(rhs.owner ?? "")
    case .group: (lhs.group ?? "").localizedStandardCompare(rhs.group ?? "")
    case .permissions: compareFileItemValues(lhs.permissions ?? 0, rhs.permissions ?? 0)
    }
    if order == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
    return preferences.sortAscending ? order == .orderedAscending : order == .orderedDescending
}

private func compareFileItemValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
}

enum RemoteTraversalTuning {
    static let maxDepth = 64
    static let maxDirectories = 2_000
    static let maxEntries = 100_000
    static let maxSearchResults = 500
}

final class RemoteTraversalState {
    private(set) var visitedDirectories = 0
    private(set) var visitedEntries = 0
    private(set) var matchedResults = 0
    private var lastProgressUpdate = Date.distantPast

    func visitDirectory(path: String, depth: Int) throws {
        try Task.checkCancellation()
        guard depth <= RemoteTraversalTuning.maxDepth else {
            throw AppError.commandFailed("Remote traversal stopped at depth \(RemoteTraversalTuning.maxDepth). Narrow the folder and try again.")
        }
        visitedDirectories += 1
        guard visitedDirectories <= RemoteTraversalTuning.maxDirectories else {
            throw AppError.commandFailed("Remote traversal stopped after \(RemoteTraversalTuning.maxDirectories) folders. Narrow the folder and try again.")
        }
    }

    func visitEntries(_ count: Int) throws {
        try Task.checkCancellation()
        visitedEntries += count
        guard visitedEntries <= RemoteTraversalTuning.maxEntries else {
            throw AppError.commandFailed("Remote traversal stopped after \(RemoteTraversalTuning.maxEntries) items. Narrow the folder and try again.")
        }
    }

    func recordMatch() throws {
        matchedResults += 1
        guard matchedResults <= RemoteTraversalTuning.maxSearchResults else {
            throw AppError.commandFailed("Search stopped after \(RemoteTraversalTuning.maxSearchResults) results. Narrow the query and try again.")
        }
    }

    func shouldPublishProgress() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= 0.2 else { return false }
        lastProgressUpdate = now
        return true
    }
}

actor ThumbnailGenerationGate {
    static let shared = ThumbnailGenerationGate(limit: 4)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            if availablePermits > 0 {
                availablePermits -= 1
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}
