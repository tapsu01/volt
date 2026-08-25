import Foundation

enum RemoteListingTuning {
    static let maxItemsPerDirectory = 20_000
}

struct TraversalLimits: Sendable, Equatable {
    var maxDepth: Int
    var maxDirectories: Int
    var maxEntries: Int
    var maxSearchResults: Int

    static let standard = TraversalLimits(
        maxDepth: 64,
        maxDirectories: 2_000,
        maxEntries: 100_000,
        maxSearchResults: 500
    )
}

func filteredSortedFileItems(
    items: [FileItem],
    preferences: FileBrowserPreferences,
    searchText: String
) throws -> [FileItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var filtered: [FileItem] = []
    filtered.reserveCapacity(items.count)
    for (index, item) in items.enumerated() {
        if index.isMultiple(of: 256) {
            try Task.checkCancellation()
        }
        guard preferences.showHiddenFiles || !item.isHidden else { continue }
        guard query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.path.localizedCaseInsensitiveContains(query) else { continue }
        filtered.append(item)
    }
    try Task.checkCancellation()
    filtered.sort { lhs, rhs in
        fileItemsSortBefore(lhs, rhs, preferences: preferences)
    }
    try Task.checkCancellation()
    return filtered
}

actor FileItemComputationCoordinator {
    func compute(
        items: [FileItem],
        preferences: FileBrowserPreferences,
        searchText: String
    ) throws -> [FileItem] {
        try filteredSortedFileItems(items: items, preferences: preferences, searchText: searchText)
    }
}

func appendBoundedTerminalOutput(
    _ newText: String,
    to output: inout String,
    retainedCount: Int = 80_000,
    trimThreshold: Int = 100_000
) {
    output.append(newText)
    let safeRetainedCount = max(1, retainedCount)
    let safeTrimThreshold = max(safeRetainedCount, trimThreshold)
    if output.count > safeTrimThreshold {
        output = String(output.suffix(safeRetainedCount))
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
    static let maxDepth = TraversalLimits.standard.maxDepth
    static let maxDirectories = TraversalLimits.standard.maxDirectories
    static let maxEntries = TraversalLimits.standard.maxEntries
    static let maxSearchResults = TraversalLimits.standard.maxSearchResults
}

final class TraversalState: @unchecked Sendable {
    let limits: TraversalLimits
    let scope: String
    private(set) var visitedDirectories = 0
    private(set) var visitedEntries = 0
    private(set) var matchedResults = 0
    private var lastProgressUpdate = Date.distantPast

    init(scope: String, limits: TraversalLimits = .standard) {
        self.scope = scope
        self.limits = limits
    }

    func visitDirectory(depth: Int) throws {
        try Task.checkCancellation()
        guard depth <= limits.maxDepth else {
            throw AppError.commandFailed("\(scope) stopped at depth \(limits.maxDepth). Narrow the folder and try again.")
        }
        visitedDirectories += 1
        guard visitedDirectories <= limits.maxDirectories else {
            throw AppError.commandFailed("\(scope) stopped after \(limits.maxDirectories) folders. Narrow the folder and try again.")
        }
    }

    func visitEntries(_ count: Int) throws {
        try Task.checkCancellation()
        guard count >= 0,
              visitedEntries <= limits.maxEntries,
              count <= limits.maxEntries - visitedEntries else {
            throw AppError.commandFailed("\(scope) stopped after \(limits.maxEntries) items. Narrow the folder and try again.")
        }
        visitedEntries += count
    }

    func recordMatch() throws {
        guard matchedResults < limits.maxSearchResults else {
            throw AppError.commandFailed("Search stopped after \(limits.maxSearchResults) results. Narrow the query and try again.")
        }
        matchedResults += 1
    }

    func shouldPublishProgress() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= 0.2 else { return false }
        lastProgressUpdate = now
        return true
    }
}

typealias RemoteTraversalState = TraversalState

struct RemoteDirectoryCache {
    private(set) var storage: [String: RemoteDirectoryCacheEntry] = [:]
    let maxDirectories: Int
    let maxItems: Int
    let maxEstimatedCost: Int

    init(maxDirectories: Int = 100, maxItems: Int = 50_000, maxEstimatedCost: Int = 64 * 1024 * 1024) {
        self.maxDirectories = max(1, maxDirectories)
        self.maxItems = max(1, maxItems)
        self.maxEstimatedCost = max(1, maxEstimatedCost)
    }

    mutating func listing(for key: String, now: Date = Date()) -> RemoteListingResult? {
        guard var entry = storage[key] else { return nil }
        entry.loadedAt = now
        storage[key] = entry
        return entry.listing
    }

    mutating func store(_ listing: RemoteListingResult, for key: String, now: Date = Date()) {
        storage[key] = RemoteDirectoryCacheEntry(
            listing: listing,
            loadedAt: now,
            estimatedCost: Self.estimatedCost(of: listing.items)
        )
        prune()
    }

    mutating func removeValue(forKey key: String) {
        storage.removeValue(forKey: key)
    }

    mutating func removeAll() {
        storage.removeAll()
    }

    private mutating func prune() {
        var itemCount = storage.values.reduce(0) { $0 + $1.listing.items.count }
        var estimatedCost = storage.values.reduce(0) { $0 + $1.estimatedCost }
        while storage.count > maxDirectories || itemCount > maxItems || estimatedCost > maxEstimatedCost {
            guard let oldest = storage.min(by: { $0.value.loadedAt < $1.value.loadedAt }) else { break }
            itemCount -= oldest.value.listing.items.count
            estimatedCost -= oldest.value.estimatedCost
            storage.removeValue(forKey: oldest.key)
        }
    }

    static func estimatedCost(of items: [FileItem]) -> Int {
        var total = 0
        for item in items {
            var itemCost = 256
            itemCost += item.name.utf8.count
            itemCost += item.path.utf8.count
            itemCost += item.kind.utf8.count
            itemCost += item.owner?.utf8.count ?? 0
            itemCost += item.group?.utf8.count ?? 0
            total += itemCost
        }
        return total
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
