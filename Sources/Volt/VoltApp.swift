import AppKit
import CVoltSSH
import CryptoKit
import Darwin
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import VoltCore

private func decodeCError(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private enum WorkspaceFileOpener {
    static func open(_ fileURL: URL, with appURL: URL?, onError: @escaping @Sendable @MainActor (String) -> Void) {
        if let appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    let message = error.localizedDescription
                    Task { @MainActor in
                        onError(message)
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }
}

enum ProtocolKind: String, Codable, CaseIterable, Identifiable {
    case sftp = "SFTP"

    var id: String { rawValue }
}

enum RemotePermissionPreset: String, Codable, CaseIterable, Identifiable {
    case web = "Web"
    case privateFiles = "Private"
    case team = "Team"

    var id: String { rawValue }
    var fileMode: UInt32 {
        switch self {
        case .web: 0o644
        case .privateFiles: 0o600
        case .team: 0o660
        }
    }
    var folderMode: UInt32 {
        switch self {
        case .web: 0o755
        case .privateFiles: 0o700
        case .team: 0o770
        }
    }
}

enum ConnectionSafetyProfile: String, Codable, CaseIterable, Identifiable {
    case standard = "standard"
    case important = "important"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .important: "Important Server"
        }
    }
}

struct SavedConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "My Server"
    var host: String = ""
    var port: Int = 22
    var username: String = NSUserName()
    var protocolKind: ProtocolKind = .sftp
    var remotePath: String = "/"
    var privateKeyPath: String = ""
    var privateKeyBookmark: Data?
    var permissionPreset: RemotePermissionPreset?
    var safetyProfile: ConnectionSafetyProfile = .standard
    var allowRootLoginOnImportantServer = false

    var effectivePermissionPreset: RemotePermissionPreset {
        permissionPreset ?? .web
    }

    var requiresImportantServerGuards: Bool {
        safetyProfile == .important
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case protocolKind
        case remotePath
        case privateKeyPath
        case privateKeyBookmark
        case permissionPreset
        case safetyProfile
        case allowRootLoginOnImportantServer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "My Server"
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? NSUserName()
        protocolKind = try container.decodeIfPresent(ProtocolKind.self, forKey: .protocolKind) ?? .sftp
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? "/"
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        privateKeyBookmark = try container.decodeIfPresent(Data.self, forKey: .privateKeyBookmark)
        permissionPreset = try container.decodeIfPresent(RemotePermissionPreset.self, forKey: .permissionPreset)
        safetyProfile = try container.decodeIfPresent(ConnectionSafetyProfile.self, forKey: .safetyProfile) ?? .standard
        allowRootLoginOnImportantServer = try container.decodeIfPresent(Bool.self, forKey: .allowRootLoginOnImportantServer) ?? false
    }
}

struct HostKeyProbe: Sendable {
    var key: Data
    var keyType: Int32
    var trustStatus: Int32
}

struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64?
    var modified: Date?
    var kind: String = "File"
    var owner: String?
    var group: String?
    var permissions: UInt32?
    var isHidden: Bool = false

    var permissionText: String {
        guard let permissions else { return "--" }
        return String(format: "%03o", permissions & 0o777)
    }

    var isRegularFile: Bool {
        guard let permissions else { return !isDirectory }
        return (permissions & 0o170000) == 0o100000
    }
}

private func loadLocalDirectoryItems(atPath path: String, includeOwnerGroupPermissions: Bool) throws -> [FileItem] {
    let url = URL(fileURLWithPath: path)
    let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .isHiddenKey
    ]
    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [])
        .map { fileURL in
            let values = try fileURL.resourceValues(forKeys: keys)
            let attributes = includeOwnerGroupPermissions
                ? try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                : nil
            let isDirectory = values.isDirectory == true
            return FileItem(
                name: fileURL.lastPathComponent,
                path: fileURL.path,
                isDirectory: isDirectory,
                size: isDirectory ? nil : values.fileSize.map(Int64.init),
                modified: values.contentModificationDate,
                kind: isDirectory ? "Folder" : (values.contentType?.localizedDescription ?? "File"),
                owner: attributes?[.ownerAccountName] as? String,
                group: attributes?[.groupOwnerAccountName] as? String,
                permissions: (attributes?[.posixPermissions] as? NSNumber)?.uint32Value,
                isHidden: values.isHidden == true || fileURL.lastPathComponent.hasPrefix(".")
            )
        }
        .sorted(by: defaultItemSort)
}

private func defaultItemSort(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
}

/// Kết quả của một lần liệt kê thư mục remote: danh sách entry hợp lệ và số entry bị bỏ vì không an
/// toàn (tên chứa byte nguy hiểm ở tầng C, hoặc không phải UTF-8 hợp lệ ở tầng Swift).
struct RemoteListingResult {
    let items: [FileItem]
    let skippedUnsafeCount: Int
}

struct RemoteDirectoryCacheEntry {
    var items: [FileItem]
    var loadedAt: Date
}

struct FolderDownloadSummary {
    var downloadedFiles = 0
    var skippedItems = 0
}

struct FolderDownloadFile: Sendable {
    var id: String
    var remotePath: String
    var localPath: String
    var name: String
    var size: UInt64
}

struct BatchDownloadResult: Sendable {
    var index: Int
    var didDownload: Bool
    var errorMessage: String?
}

struct FolderDownloadPlan: Sendable {
    var files: [FolderDownloadFile] = []
    var directories: [String] = []
    var skippedItems = 0

    var totalBytes: UInt64 {
        files.reduce(UInt64(0)) { $0 + $1.size }
    }
}

actor FolderDownloadProgress {
    private let totalBytes: UInt64
    private var transferredByFile: [String: UInt64] = [:]

    init(totalBytes: UInt64) {
        self.totalBytes = totalBytes
    }

    func update(fileID: String, transferred: UInt64) -> (transferred: UInt64, total: UInt64) {
        transferredByFile[fileID] = transferred
        let totalTransferred = transferredByFile.values.reduce(UInt64(0), +)
        return (min(totalTransferred, totalBytes), totalBytes)
    }
}

struct FolderUploadSummary {
    var uploadedFiles = 0
    var skippedItems = 0
}

private enum TransferTuning {
    static let maxConcurrentTransfers = 4
    static let maxConcurrentFolderDownloads = 4
    static let parallelDownloadThreshold: UInt64 = 16 * 1024 * 1024
    static let maxParallelFileDownloadSessions = 4
}

enum FileBrowserViewMode: String, Codable, CaseIterable, Identifiable {
    case icons
    case list
    case columns
    case thumbnails

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        case .thumbnails: "photo.on.rectangle.angled"
        }
    }
}

enum FileBrowserColumn: String, Codable, CaseIterable, Identifiable {
    case size = "Size"
    case date = "Date"
    case kind = "Kind"
    case owner = "Owner"
    case group = "Group"
    case permissions = "Permissions"

    var id: String { rawValue }
    var width: CGFloat {
        switch self {
        case .size: 110
        case .date: 155
        case .kind: 135
        case .owner, .group: 105
        case .permissions: 115
        }
    }
}

enum FileBrowserSortField: String, Codable {
    case name, size, date, kind, owner, group, permissions
}

struct FileBrowserPreferences: Codable, Equatable {
    var viewMode: FileBrowserViewMode = .list
    var visibleColumns: [FileBrowserColumn] = [.size, .date]
    var nameColumnWidth: CGFloat = 360
    var columnWidths: [FileBrowserColumn: CGFloat] = [:]
    var showHiddenFiles = false
    var foldersFirst = true
    var showRowColors = true
    var useRelativeDates = false
    var showFileCount = false
    var textSize: Double = 13
    var sortField: FileBrowserSortField = .name
    var sortAscending = true

    static func load(key: String) -> FileBrowserPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum TransferDirection: String {
    case upload = "Upload"
    case download = "Download"
    case edit = "Edit"
}

enum TransferState: String {
    case queued = "Queued"
    case running = "Running"
    case done = "Done"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

enum TransferPanelTab: String {
    case transfers = "Transfers"
    case remoteEdits = "Remote Edits"
    case terminal = "Terminal"
}

enum TerminalStatus: String, Equatable {
    case idle = "Idle"
    case connecting = "Connecting"
    case running = "Running"
    case exited = "Exited"
    case failed = "Failed"
}

struct TransferJob: Identifiable {
    let id = UUID()
    var direction: TransferDirection
    var source: String
    var destination: String
    var state: TransferState = .queued
    var message: String = ""
    var transferredBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var startedAt: Date?
    var progressStartedAt: Date?
    var updatedAt: Date?
}

actor TransferLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct RemoteEditSession: Identifiable, Equatable {
    let id = UUID()
    var remotePath: String
    var localPath: String
    var fileName: String
    var openedAt: Date = Date()
}

struct BrowserTab: Identifiable, Equatable {
    let id = UUID()
    var title: String = "New Tab"
    var connectionID: UUID?
    var connectionDraft = SavedConnection()
    var localPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    var remotePath: String = "/"
    var localItems: [FileItem] = []
    var remoteItems: [FileItem] = []
    var selectedLocalIDs: Set<FileItem.ID> = []
    var selectedRemoteIDs: Set<FileItem.ID> = []
    var remoteEditSessions: [RemoteEditSession] = []
    var terminalOutput = ""
    var terminalStatus: TerminalStatus = .idle
    var isConnected = false
    var showsConnectionEditor = false
    var showsInspector = false
}

enum AppAppearance: String {
    case light
    case dark

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearanceName: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    mutating func toggle() {
        self = self == .light ? .dark : .light
    }
}

enum AppError: LocalizedError {
    case missingConnection
    case commandFailed(String)
    case unsupportedPasswordAuth
    case hostKeyRejected

    var errorDescription: String? {
        switch self {
        case .missingConnection:
            "Choose a connection first."
        case .commandFailed(let text):
            text.isEmpty ? "The command failed." : text
        case .unsupportedPasswordAuth:
            "This SSH shell action requires SSH key or ssh-agent authentication. SFTP password operations are supported."
        case .hostKeyRejected:
            "Host key verification failed. The connection was rejected."
        }
    }
}

@MainActor
// Password is entered at connection time via a prompt dialog (no Keychain storage).

struct CommandResult {
    var stdout: String
    var stderr: String
    var status: Int32
}

final class CommandRunner: @unchecked Sendable {
    func run(_ executable: String, arguments: [String], stdin: String? = nil, environment: [String: String] = [:]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}

final class SSHTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    private var childPID: pid_t?
    private var masterHandle: FileHandle?
    private var securityScopedKeyURL: URL?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return childPID != nil
    }

    func start(
        connection: SavedConnection,
        knownHostsPath: String,
        hostKeyAlgorithm: String?,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        lock.lock()
        let alreadyRunning = childPID != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let executable = "/usr/bin/ssh"
        let arguments = try sshArguments(connection: connection, knownHostsPath: knownHostsPath, hostKeyAlgorithm: hostKeyAlgorithm)
        let argv = Self.makeArgv(executable: executable, arguments: arguments)
        guard let executablePointer = argv.executablePointer else {
            Self.freeArgv(argv)
            throw AppError.commandFailed("Could not prepare SSH terminal.")
        }

        var master: Int32 = -1
        var windowSize = winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &windowSize)
        if pid == 0 {
            execv(executablePointer, argv.argumentPointers)
            _exit(127)
        }
        Self.freeArgv(argv)

        guard pid > 0 else {
            throw AppError.commandFailed("Could not open SSH terminal.")
        }

        let masterFile = FileHandle(fileDescriptor: master, closeOnDealloc: true)

        masterFile.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = Self.sanitizedOutput(from: data)
            guard !text.isEmpty else { return }
            onOutput(text)
        }

        lock.lock()
        self.childPID = pid
        self.masterHandle = masterFile
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 {
                if errno != EINTR { break }
            }

            let exitCode = Self.exitCode(fromWaitStatus: status)

            guard let self else { return }
            let shouldNotify = self.finishChild(pid: pid)
            if shouldNotify {
                onExit(exitCode)
            }
        }
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        lock.lock()
        let handle = masterHandle
        lock.unlock()
        try? handle?.write(contentsOf: data)
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        let fileDescriptor = masterHandle?.fileDescriptor
        lock.unlock()
        guard let fileDescriptor else { return }
        var windowSize = winsize(
            ws_row: UInt16(max(8, min(rows, 200))),
            ws_col: UInt16(max(20, min(columns, 400))),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fileDescriptor, TIOCSWINSZ, &windowSize)
    }

    func terminate() {
        lock.lock()
        let childPID = childPID
        let masterHandle = masterHandle
        self.childPID = nil
        self.masterHandle = nil
        lock.unlock()

        masterHandle?.readabilityHandler = nil
        if let childPID {
            kill(childPID, SIGTERM)
        }
        try? masterHandle?.close()
        stopAccessingKey()
    }

    private func finishChild(pid: pid_t) -> Bool {
        lock.lock()
        let shouldNotify = childPID == pid
        let masterHandle = shouldNotify ? masterHandle : nil
        if shouldNotify {
            childPID = nil
            self.masterHandle = nil
        }
        lock.unlock()

        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
        if shouldNotify {
            stopAccessingKey()
        }
        return shouldNotify
    }

    private func sshArguments(connection: SavedConnection, knownHostsPath: String, hostKeyAlgorithm: String?) throws -> [String] {
        var args = [
            "-F", "/dev/null",
            "-o", "BatchMode=no",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ClearAllForwardings=yes",
            "-p", "\(connection.port)"
        ]
        if let hostKeyAlgorithm {
            args.append(contentsOf: ["-o", "HostKeyAlgorithms=\(hostKeyAlgorithm)"])
        }
        let keyPath = try privateKeyPath(for: connection)
        if !keyPath.isEmpty {
            args.append(contentsOf: ["-i", keyPath])
        }
        args.append("--")
        args.append("\(connection.username)@\(connection.host)")
        return args
    }

    private func privateKeyPath(for connection: SavedConnection) throws -> String {
        var bookmarkIsStale = false
        if let bookmark = connection.privateKeyBookmark,
           let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
           ) {
            if url.startAccessingSecurityScopedResource() {
                securityScopedKeyURL = url
            }
            return url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return connection.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopAccessingKey() {
        securityScopedKeyURL?.stopAccessingSecurityScopedResource()
        securityScopedKeyURL = nil
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let statusMask = status & 0o177
        if statusMask == 0 {
            return (status >> 8) & 0xFF
        }
        if statusMask != 0o177 {
            return 128 + statusMask
        }
        return status
    }

    private typealias Argv = (
        executablePointer: UnsafeMutablePointer<CChar>?,
        argumentPointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    )

    private static func makeArgv(executable: String, arguments: [String]) -> Argv {
        let values = [executable] + arguments
        let argumentPointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() {
            argumentPointers[index] = strdup(value)
        }
        argumentPointers[values.count] = nil
        return (argumentPointers[0], argumentPointers)
    }

    private static func freeArgv(_ argv: Argv) {
        var index = 0
        while let pointer = argv.argumentPointers[index] {
            free(pointer)
            index += 1
        }
        argv.argumentPointers.deallocate()
    }

    private static func sanitizedOutput(from data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return stripControlSequences(from: text)
    }

    private static func stripControlSequences(from text: String) -> String {
        var output = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "]" {
                    while let osc = iterator.next() {
                        if osc == "\u{7}" { break }
                        if osc == "\u{1B}" {
                            _ = iterator.next()
                            break
                        }
                    }
                } else if next == "[" {
                    while let csi = iterator.next() {
                        if (0x40...0x7E).contains(Int(csi.value)) { break }
                    }
                }
                continue
            }
            if scalar == "\u{8}" || scalar == "\u{9}" || scalar == "\u{A}" || scalar == "\u{D}" || scalar.value >= 0x20 {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    deinit {
        terminate()
    }
}

final class SensitiveCredential: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = [0]

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bytes.count <= 1
    }

    func replace(with value: String) {
        lock.lock()
        defer { lock.unlock() }
        zeroizeLocked()
        bytes.removeAll(keepingCapacity: true)
        bytes.reserveCapacity(value.utf8.count + 1)
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
    }

    func clone() -> SensitiveCredential {
        let copy = SensitiveCredential()
        lock.lock()
        copy.bytes = bytes
        lock.unlock()
        return copy
    }

    func fingerprint() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(SHA256.hash(data: Data(bytes)))
    }

    func clear() {
        lock.lock()
        zeroizeLocked()
        bytes = [0]
        lock.unlock()
    }

    func withCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        guard bytes.count > 1 else { return try body(nil) }
        return try bytes.withUnsafeBufferPointer { buffer in
            try body(UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
    }

    private func zeroizeLocked() {
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let address = rawBuffer.baseAddress else { return }
            volt_secure_zero(address, rawBuffer.count)
        }
    }

    deinit {
        clear()
    }
}

enum DownloadPublishPolicy: Sendable {
    case replace
    case createNew
}

enum UploadPublishPolicy: Sendable {
    case replace
    case createNew
}

private enum UploadConflictBatchPolicy {
    case replace
    case keepBoth
    case skip
}

private enum UploadConflictChoice: Equatable {
    case replace
    case keepBoth
    case skip
    case cancel
}

private enum UploadConflictResolution {
    case upload(path: String, policy: UploadPublishPolicy)
    case skip
}

private enum RemoteRefreshMode {
    case foreground
    case background
}

final class SecureStorage {
    private static let legacyKey = "connections"

    static func save(_ connections: [SavedConnection]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        do {
            let url = try AppPaths.supportDirectory().appendingPathComponent("connections.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return
        }
    }

    static func load() -> [SavedConnection] {
        guard let url = try? AppPaths.supportDirectory().appendingPathComponent("connections.json"),
              let data = try? Data(contentsOf: url),
              let connections = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return []
        }
        return connections
    }

    static func migrateFromUserDefaults() {
        guard let destination = try? AppPaths.supportDirectory().appendingPathComponent("connections.json"),
              !FileManager.default.fileExists(atPath: destination.path),
              let data = UserDefaults.standard.data(forKey: legacyKey),
              let connections = try? JSONDecoder().decode([SavedConnection].self, from: data) else { return }
        save(connections)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}

final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastProgressUpdate: TimeInterval = 0
    private weak var parent: TransferControl?
    private let progressHandler: @Sendable (UInt64, UInt64) -> Void

    init(parent: TransferControl? = nil, progressHandler: @escaping @Sendable (UInt64, UInt64) -> Void) {
        self.parent = parent
        self.progressHandler = progressHandler
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func report(transferred: UInt64, total: UInt64) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        let shouldReport = now - lastProgressUpdate >= 0.1 || (total > 0 && transferred >= total)
        if shouldReport {
            lastProgressUpdate = now
        }
        let shouldCancel = cancelled || parent?.isCancelled == true
        lock.unlock()
        if shouldReport {
            progressHandler(transferred, total)
        }
        return shouldCancel
    }
}

private func transferProgressCallback(
    _ transferred: UInt64,
    _ total: UInt64,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 0 }
    let control = Unmanaged<TransferControl>.fromOpaque(context).takeUnretainedValue()
    return control.report(transferred: transferred, total: total) ? 1 : 0
}

final class BatchTransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private weak var parent: TransferControl?
    private var lastProgressUpdate: [Int: TimeInterval] = [:]
    private let progressHandler: @Sendable (Int, UInt64, UInt64) -> Void

    init(parent: TransferControl, progressHandler: @escaping @Sendable (Int, UInt64, UInt64) -> Void) {
        self.parent = parent
        self.progressHandler = progressHandler
    }

    func report(index: Int, transferred: UInt64, total: UInt64) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        let previous = lastProgressUpdate[index] ?? 0
        let shouldReport = now - previous >= 0.1 || (total > 0 && transferred >= total)
        if shouldReport {
            lastProgressUpdate[index] = now
        }
        let shouldCancel = parent?.isCancelled == true
        lock.unlock()
        if shouldReport {
            progressHandler(index, transferred, total)
        }
        return shouldCancel
    }
}

private func transferBatchProgressCallback(
    _ index: Int32,
    _ transferred: UInt64,
    _ total: UInt64,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 0 }
    let control = Unmanaged<BatchTransferControl>.fromOpaque(context).takeUnretainedValue()
    return control.report(index: Int(index), transferred: transferred, total: total) ? 1 : 0
}

enum AppPaths {
    static var defaultLocalDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func migrateFromSandboxContainerIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sandboxDirectory = home
            .appendingPathComponent("Library/Containers/local.volt.app/Data/Library/Application Support/Volt", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sandboxDirectory.path),
              let destination = try? supportDirectory() else { return }

        for name in ["connections.json", "known_hosts"] {
            let source = sandboxDirectory.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.copyItem(at: source, to: target)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Volt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    static func knownHostsURL() throws -> URL {
        let url = try supportDirectory().appendingPathComponent("known_hosts", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func editDirectory() throws -> URL {
        let directory = try supportDirectory().appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    static func cleanupEditFiles(olderThan age: TimeInterval = 24 * 60 * 60) {
        guard let directory = try? editDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if age == 0 || (modified ?? .distantPast) < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

private struct SFTPConnectionPoolKey: Hashable, Sendable {
    var connectionID: UUID
    var host: String
    var port: Int
    var username: String
    var privateKeyPath: String
    var passwordFingerprint: Data
}

private final class PooledSFTPSession: @unchecked Sendable {
    private var pointer: OpaquePointer?

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    var handle: OpaquePointer? {
        pointer
    }

    func close() {
        if let pointer {
            volt_session_close(pointer)
            self.pointer = nil
        }
    }

    deinit {
        close()
    }
}

private actor SFTPConnectionPool {
    private var sessions: [SFTPConnectionPoolKey: PooledSFTPSession] = [:]

    func call(
        key: SFTPConnectionPoolKey,
        openSession: @Sendable (UnsafeMutablePointer<CChar>, Int) throws -> PooledSFTPSession,
        operation: @Sendable (OpaquePointer, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) async throws -> String? {
        var error = [CChar](repeating: 0, count: 4096)
        let errorLength = error.count

        let session: PooledSFTPSession
        if let existingSession = sessions[key], existingSession.handle != nil {
            session = existingSession
        } else {
            session = try error.withUnsafeMutableBufferPointer { errorBuffer in
                try openSession(errorBuffer.baseAddress!, errorLength)
            }
            sessions[key] = session
        }

        guard let handle = session.handle else {
            sessions.removeValue(forKey: key)
            throw AppError.commandFailed("SFTP session is not open.")
        }

        let status = error.withUnsafeMutableBufferPointer { errorBuffer in
            operation(handle, errorBuffer.baseAddress!, errorLength)
        }
        let message = error.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        guard status >= 0 else {
            sessions.removeValue(forKey: key)
            session.close()
            throw AppError.commandFailed(message)
        }
        return status == VOLT_SFTP_PERMISSION_WARNING ? message : nil
    }

    func closeSessions(for connectionID: UUID) {
        let keys = sessions.keys.filter { $0.connectionID == connectionID }
        for key in keys {
            sessions.removeValue(forKey: key)?.close()
        }
    }

    func closeAll() {
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
    }
}

private final class SFTPListOutput: @unchecked Sendable {
    var items: UnsafeMutablePointer<VoltSFTPItem>?
    var count: Int32 = 0
    var skippedUnsafe: Int32 = 0
}

final class SFTPClient: @unchecked Sendable {
    private let pool = SFTPConnectionPool()

    func probeHostKey(connection: SavedConnection) async throws -> HostKeyProbe {
        try await Task.detached {
            var keyPointer: UnsafeMutablePointer<UInt8>?
            var keyLength = 0
            var keyType: Int32 = 0
            var trustStatus: Int32 = 0
            var error = [CChar](repeating: 0, count: 4096)
            let knownHostsPath = try AppPaths.knownHostsURL().path
            let status = connection.host.withCString { host in
                knownHostsPath.withCString { knownHosts in
                    error.withUnsafeMutableBufferPointer { errorBuffer in
                        volt_ssh_probe_host_key(
                            host,
                            Int32(connection.port),
                            knownHosts,
                            &keyPointer,
                            &keyLength,
                            &keyType,
                            &trustStatus,
                            errorBuffer.baseAddress!,
                            errorBuffer.count
                        )
                    }
                }
            }
            guard status == 0, let keyPointer else {
                throw AppError.commandFailed(decodeCError(error))
            }
            defer { volt_ssh_free_buffer(keyPointer) }
            return HostKeyProbe(
                key: Data(bytes: keyPointer, count: keyLength),
                keyType: keyType,
                trustStatus: trustStatus
            )
        }.value
    }

    func commitHostKey(connection: SavedConnection, probe: HostKeyProbe) async throws {
        try await Task.detached {
            var error = [CChar](repeating: 0, count: 4096)
            let knownHostsPath = try AppPaths.knownHostsURL().path
            let status = probe.key.withUnsafeBytes { keyBuffer in
                connection.host.withCString { host in
                    knownHostsPath.withCString { knownHosts in
                        error.withUnsafeMutableBufferPointer { errorBuffer in
                            volt_ssh_commit_host_key(
                                host,
                                Int32(connection.port),
                                knownHosts,
                                keyBuffer.bindMemory(to: UInt8.self).baseAddress!,
                                keyBuffer.count,
                                probe.keyType,
                                errorBuffer.baseAddress!,
                                errorBuffer.count
                            )
                        }
                    }
                }
            }
            guard status == 0 else {
                throw AppError.commandFailed(decodeCError(error))
            }
        }.value
    }

    func list(connection: SavedConnection, credential: SensitiveCredential, path: String) async throws -> RemoteListingResult {
        try await Task.detached {
            let output = SFTPListOutput()
            _ = try await self.callOnPooledSession(connection: connection, credential: credential) { handle, error, errorLength in
                path.withCString { remotePath in
                    volt_sftp_list_on(handle, remotePath, &output.items, &output.count, &output.skippedUnsafe, error, errorLength)
                }
            }
            defer {
                if let items = output.items {
                    volt_sftp_free_items(items)
                }
            }
            guard let items = output.items else {
                return RemoteListingResult(items: [], skippedUnsafeCount: Int(output.skippedUnsafe))
            }
            var parsed: [FileItem] = []
            var swiftSkipped = 0
            for index in 0..<Int(output.count) {
                // Một guard chung cho cả name và path: chỉ đếm MỘT lần mỗi entry, và loại bỏ triệt để
                // bytes không phải UTF-8 hợp lệ (String(cString:) sẽ thay thế lossy bằng U+FFFD, khiến
                // path re-encode không còn trỏ đúng entry gốc).
                guard let name = String(validatingCString: volt_sftp_item_name(items, Int32(index))),
                      let itemPath = String(validatingCString: volt_sftp_item_path(items, Int32(index)))
                else {
                    swiftSkipped += 1
                    continue
                }
                let rawSize = volt_sftp_item_size(items, Int32(index))
                let rawModified = volt_sftp_item_modified(items, Int32(index))
                let isDirectory = volt_sftp_item_is_directory(items, Int32(index)) != 0
                let permissions = volt_sftp_item_permissions(items, Int32(index))
                parsed.append(FileItem(
                    name: name,
                    path: itemPath,
                    isDirectory: isDirectory,
                    size: !isDirectory && rawSize >= 0 ? rawSize : nil,
                    modified: rawModified > 0 ? Date(timeIntervalSince1970: TimeInterval(rawModified)) : nil,
                    kind: isDirectory ? "Folder" : (UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "File"),
                    owner: String(volt_sftp_item_uid(items, Int32(index))),
                    group: String(volt_sftp_item_gid(items, Int32(index))),
                    permissions: permissions == 0 ? nil : permissions,
                    isHidden: name.hasPrefix(".")
                ))
            }
            parsed.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return RemoteListingResult(items: parsed, skippedUnsafeCount: Int(output.skippedUnsafe) + swiftSkipped)
        }.value
    }

    func upload(connection: SavedConnection, credential: SensitiveCredential, localPath: String, remotePath: String, policy: UploadPublishPolicy, control: TransferControl) async throws -> String? {
        try await Task.detached {
            let context = Unmanaged.passRetained(control).toOpaque()
            defer { Unmanaged<TransferControl>.fromOpaque(context).release() }
            return try self.call(connection: connection, credential: credential) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_upload(host, port, username, password, keyPath, knownHostsPath, localPath, remotePath, connection.effectivePermissionPreset.fileMode, policy == .replace ? 1 : 0, transferProgressCallback, context, error, errorLength)
            }
        }.value
    }

    func download(connection: SavedConnection, credential: SensitiveCredential, remotePath: String, localPath: String, policy: DownloadPublishPolicy, control: TransferControl) async throws {
        try await Task.detached {
            let context = Unmanaged.passRetained(control).toOpaque()
            defer { Unmanaged<TransferControl>.fromOpaque(context).release() }
            _ = try self.call(connection: connection, credential: credential) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_download_parallel(
                    host,
                    port,
                    username,
                    password,
                    keyPath,
                    knownHostsPath,
                    remotePath,
                    localPath,
                    policy == .replace ? 1 : 0,
                    Int32(TransferTuning.maxParallelFileDownloadSessions),
                    TransferTuning.parallelDownloadThreshold,
                    transferProgressCallback,
                    context,
                    error,
                    errorLength
                )
            }
        }.value
    }

    func downloadBatch(
        connection: SavedConnection,
        credential: SensitiveCredential,
        files: [FolderDownloadFile],
        parentControl: TransferControl,
        progress: @escaping @Sendable (Int, UInt64, UInt64) -> Void
    ) async throws -> [BatchDownloadResult] {
        guard !files.isEmpty else { return [] }
        return try await Task.detached {
            var remotePointers: [UnsafeMutablePointer<CChar>] = []
            var localPointers: [UnsafeMutablePointer<CChar>] = []
            defer {
                for pointer in remotePointers { free(pointer) }
                for pointer in localPointers { free(pointer) }
            }

            remotePointers.reserveCapacity(files.count)
            localPointers.reserveCapacity(files.count)
            for file in files {
                guard let remotePointer = strdup(file.remotePath) else {
                    throw AppError.commandFailed("Out of memory.")
                }
                guard let localPointer = strdup(file.localPath) else {
                    free(remotePointer)
                    throw AppError.commandFailed("Out of memory.")
                }
                remotePointers.append(remotePointer)
                localPointers.append(localPointer)
            }

            let requests = files.indices.map { index in
                VoltSFTPDownloadRequest(
                    remote_path: UnsafePointer(remotePointers[index]),
                    local_path: UnsafePointer(localPointers[index]),
                    overwrite: 0
                )
            }
            var results = (0..<files.count).map { _ in VoltSFTPDownloadResult() }
            let batchControl = BatchTransferControl(parent: parentControl, progressHandler: progress)
            let context = Unmanaged.passRetained(batchControl).toOpaque()
            defer { Unmanaged<BatchTransferControl>.fromOpaque(context).release() }

            _ = try self.call(connection: connection, credential: credential) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                requests.withUnsafeBufferPointer { requestBuffer in
                    results.withUnsafeMutableBufferPointer { resultBuffer in
                        volt_sftp_download_batch(
                            host,
                            port,
                            username,
                            password,
                            keyPath,
                            knownHostsPath,
                            requestBuffer.baseAddress!,
                            resultBuffer.baseAddress!,
                            Int32(files.count),
                            transferBatchProgressCallback,
                            context,
                            error,
                            errorLength
                        )
                    }
                }
            }

            return files.indices.map { index in
                let status = volt_sftp_download_result_status(results, Int32(index))
                let messagePointer = volt_sftp_download_result_error(results, Int32(index))
                let message = messagePointer.map { String(cString: $0) } ?? "Download failed."
                return BatchDownloadResult(
                    index: index,
                    didDownload: status == 0,
                    errorMessage: status == 0 ? nil : message
                )
            }
        }.value
    }

    func makeDirectory(connection: SavedConnection, credential: SensitiveCredential, path: String) async throws -> String? {
        try await Task.detached {
            try await self.callOnPooledSession(connection: connection, credential: credential) { handle, error, errorLength in
                path.withCString { remotePath in
                    volt_sftp_mkdir_on(handle, remotePath, connection.effectivePermissionPreset.folderMode, error, errorLength)
                }
            }
        }.value
    }

    func createFile(connection: SavedConnection, credential: SensitiveCredential, remotePath: String) async throws -> String? {
        try await Task.detached {
            try await self.callOnPooledSession(connection: connection, credential: credential) { handle, error, errorLength in
                remotePath.withCString { remotePathPointer in
                    volt_sftp_create_empty_file_on(handle, remotePathPointer, connection.effectivePermissionPreset.fileMode, error, errorLength)
                }
            }
        }.value
    }

    func rename(connection: SavedConnection, credential: SensitiveCredential, from: String, to: String) async throws {
        try await Task.detached {
            _ = try await self.callOnPooledSession(connection: connection, credential: credential) { handle, error, errorLength in
                from.withCString { fromPath in
                    to.withCString { toPath in
                        volt_sftp_rename_on(handle, fromPath, toPath, error, errorLength)
                    }
                }
            }
        }.value
    }

    func remove(connection: SavedConnection, credential: SensitiveCredential, path: String, isDirectory: Bool) async throws {
        try await Task.detached {
            _ = try await self.callOnPooledSession(connection: connection, credential: credential) { handle, error, errorLength in
                path.withCString { remotePath in
                    volt_sftp_remove_on(handle, remotePath, isDirectory ? 1 : 0, error, errorLength)
                }
            }
        }.value
    }

    func closePooledSessions(for connectionID: UUID) async {
        await pool.closeSessions(for: connectionID)
    }

    func closeAllPooledSessions() async {
        await pool.closeAll()
    }

    static func controlSocketDir() throws -> String {
        let controlDir = try AppPaths.supportDirectory().appendingPathComponent("ControlSockets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: controlDir.path) {
            try FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDir.path)
        }
        return controlDir.path
    }

    private func call(
        connection: SavedConnection,
        credential: SensitiveCredential,
        _ body: (UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws -> String? {
        var error = [CChar](repeating: 0, count: 4096)
        let errorLength = error.count
        var bookmarkIsStale = false
        let bookmarkedKeyURL = connection.privateKeyBookmark.flatMap {
            try? URL(
                resolvingBookmarkData: $0,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        }
        let isAccessingKey = bookmarkedKeyURL?.startAccessingSecurityScopedResource() == true
        defer {
            if isAccessingKey { bookmarkedKeyURL?.stopAccessingSecurityScopedResource() }
        }
        let keyPath = (bookmarkedKeyURL?.path ?? connection.privateKeyPath).trimmingCharacters(in: .whitespacesAndNewlines)
        let knownHostsPath = try AppPaths.knownHostsURL().path
        let status = credential.withCString { passwordPointer in
            connection.host.withCString { host in
                connection.username.withCString { username in
                    knownHostsPath.withCString { knownHostsPointer in
                        error.withUnsafeMutableBufferPointer { errorBuffer in
                            let errorPointer = errorBuffer.baseAddress!
                            if keyPath.isEmpty {
                                return body(host, Int32(connection.port), username, passwordPointer, nil, knownHostsPointer, errorPointer, errorLength)
                            }
                            return keyPath.withCString { keyPointer in
                                body(host, Int32(connection.port), username, passwordPointer, keyPointer, knownHostsPointer, errorPointer, errorLength)
                            }
                        }
                    }
                }
            }
        }
        let message = error.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        guard status >= 0 else {
            throw AppError.commandFailed(error.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            })
        }
        return status == VOLT_SFTP_PERMISSION_WARNING ? message : nil
    }

    private func callOnPooledSession(
        connection: SavedConnection,
        credential: SensitiveCredential,
        _ body: @escaping @Sendable (OpaquePointer, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) async throws -> String? {
        var bookmarkIsStale = false
        let bookmarkedKeyURL = connection.privateKeyBookmark.flatMap {
            try? URL(
                resolvingBookmarkData: $0,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        }
        let isAccessingKey = bookmarkedKeyURL?.startAccessingSecurityScopedResource() == true
        defer {
            if isAccessingKey { bookmarkedKeyURL?.stopAccessingSecurityScopedResource() }
        }
        let keyPath = (bookmarkedKeyURL?.path ?? connection.privateKeyPath).trimmingCharacters(in: .whitespacesAndNewlines)
        let knownHostsPath = try AppPaths.knownHostsURL().path
        let poolKey = SFTPConnectionPoolKey(
            connectionID: connection.id,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            privateKeyPath: keyPath,
            passwordFingerprint: credential.fingerprint()
        )

        return try await pool.call(
            key: poolKey,
            openSession: { errorPointer, errorLength in
                var handle: OpaquePointer?
                let status = credential.withCString { passwordPointer in
                    connection.host.withCString { host in
                        connection.username.withCString { username in
                            knownHostsPath.withCString { knownHostsPointer in
                                if keyPath.isEmpty {
                                    return volt_session_open(host, Int32(connection.port), username, passwordPointer, nil, knownHostsPointer, &handle, errorPointer, errorLength)
                                }
                                return keyPath.withCString { keyPointer in
                                    volt_session_open(host, Int32(connection.port), username, passwordPointer, keyPointer, knownHostsPointer, &handle, errorPointer, errorLength)
                                }
                            }
                        }
                    }
                }
                guard status == 0, let handle else {
                    throw AppError.commandFailed(String(cString: errorPointer))
                }
                return PooledSFTPSession(handle)
            },
            operation: body
        )
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [SavedConnection] = []
    @Published var tabs: [BrowserTab] = [BrowserTab()]
    @Published var selectedTabID: BrowserTab.ID?
    @Published var selectedConnectionID: UUID?
    @Published var connectionDraft = SavedConnection()

    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = "/"
    @Published var localItems: [FileItem] = []
    @Published var remoteItems: [FileItem] = []
    @Published var selectedLocalIDs: Set<FileItem.ID> = []
    @Published var selectedRemoteIDs: Set<FileItem.ID> = []
    @Published var localBrowserPreferences = FileBrowserPreferences.load(key: "Volt.LocalBrowserPreferences") {
        didSet {
            let oldNeedsMetadata = Self.needsLocalOwnerGroupPermissions(for: oldValue)
            let newNeedsMetadata = Self.needsLocalOwnerGroupPermissions(for: localBrowserPreferences)
            localBrowserPreferences.save(key: "Volt.LocalBrowserPreferences")
            if oldNeedsMetadata != newNeedsMetadata {
                refreshLocal()
            }
        }
    }
    @Published var remoteBrowserPreferences = FileBrowserPreferences.load(key: "Volt.RemoteBrowserPreferences") {
        didSet { remoteBrowserPreferences.save(key: "Volt.RemoteBrowserPreferences") }
    }
    @Published var transfers: [TransferJob] = []
    @Published var remoteEditSessions: [RemoteEditSession] = []
    @Published var terminalOutput = ""
    @Published var terminalStatus: TerminalStatus = .idle
    @Published var status = "Ready"
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var showsConnectionEditor = false
    @Published var showsInspector = false
    @Published var showsTransfers = false
    @Published var transferPanelTab: TransferPanelTab = .transfers
    @Published var recentsCleared = false
    @Published var showsPasswordPrompt = false
    @Published var showsHostKeyPrompt = false
    @Published var pendingHostKeyFingerprint = ""
    @Published var pendingHostKeyHost = ""
    private var hostKeyConfirmationContinuation: CheckedContinuation<Bool, Never>?
    private var tabCredentials: [BrowserTab.ID: SensitiveCredential] = [:]
    private var terminalSessions: [BrowserTab.ID: SSHTerminalSession] = [:]
    private var verifiedHostProbes: [String: HostKeyProbe] = [:]
    private var remoteDirectoryCache: [String: RemoteDirectoryCacheEntry] = [:]

    private let sftp = SFTPClient()
    private let transferLimiter = TransferLimiter(limit: TransferTuning.maxConcurrentTransfers)
    private var transferControls: [UUID: TransferControl] = [:]
    private var lastTransferProgressUpdateByID: [UUID: Date] = [:]
    private var uploadConflictBatchPolicy: UploadConflictBatchPolicy?
    private var reservedUploadPaths: Set<String> = []
    private var activeOperationCount = 0
    private var isRestoringTab = false
    private var isSuppressingSidebarSelection = false
    private var isSelectingConnection = false
    private let transferProgressMinimumInterval: TimeInterval = 0.08

    var hasCompletedTransfers: Bool {
        transfers.contains { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    init() {
        selectedTabID = tabs.first?.id
        refreshLocal()
        syncCurrentTab()
        loadStartupStorage()
    }

    var selectedConnection: SavedConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    var selectedLocal: FileItem? {
        localItems.first { selectedLocalIDs.contains($0.id) }
    }

    var selectedRemote: FileItem? {
        remoteItems.first { selectedRemoteIDs.contains($0.id) }
    }

    var selectedLocalItems: [FileItem] {
        localItems.filter { selectedLocalIDs.contains($0.id) }
    }

    var selectedRemoteItems: [FileItem] {
        remoteItems.filter { selectedRemoteIDs.contains($0.id) }
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var connectedConnectionIDs: Set<UUID> {
        Set(tabs.compactMap { tab in
            tab.isConnected ? tab.connectionID : nil
        })
    }

    func isConnectionConnected(_ id: UUID) -> Bool {
        connectedConnectionIDs.contains(id)
    }

    func newTab() {
        syncCurrentTab()
        let clonedCredential = credentialForCurrentTab().clone()
        var tab = BrowserTab()
        tab.localPath = localPath
        tab.localItems = localItems
        tab.title = "New Tab"
        tabs.append(tab)
        tabCredentials[tab.id] = clonedCredential
        selectTab(tab.id)
    }

    func calculateSize(for item: FileItem, isLocal: Bool) async {
        if isLocal {
            let runner = CommandRunner()
            let executable = "/usr/bin/du"
            let args = ["-sk", item.path]
            if let result = try? runner.run(executable, arguments: args, stdin: "", environment: [:]),
               result.status == 0,
               let sizeStr = result.stdout.split(separator: "\t").first,
               let sizeKB = Int64(sizeStr) {
                let sizeBytes = sizeKB * 1024
                await MainActor.run {
                    if let index = self.localItems.firstIndex(where: { $0.id == item.id }) {
                        self.localItems[index].size = sizeBytes
                        self.syncCurrentTab()
                    }
                }
            }
        } else {
            guard let connection = selectedConnection else { return }
            let credential = credentialForCurrentTab().clone()

            do {
                let sizeBytes = try await remoteRecursiveSize(
                    connection: connection,
                    credential: credential,
                    item: item
                )
                await MainActor.run {
                    if let index = self.remoteItems.firstIndex(where: { $0.id == item.id }) {
                        self.remoteItems[index].size = sizeBytes
                        self.syncCurrentTab()
                    }
                }
            } catch {
                // Ignore failure
            }
        }
    }

    private func remoteRecursiveSize(
        connection: SavedConnection,
        credential: SensitiveCredential,
        item: FileItem
    ) async throws -> Int64 {
        if !item.isDirectory {
            return item.size ?? 0
        }
        return try await remoteRecursiveSize(connection: connection, credential: credential, path: item.path)
    }

    private func remoteRecursiveSize(
        connection: SavedConnection,
        credential: SensitiveCredential,
        path: String
    ) async throws -> Int64 {
        let result = try await sftp.list(connection: connection, credential: credential, path: path)
        var total: Int64 = 0
        for child in result.items {
            if child.isDirectory {
                total += try await remoteRecursiveSize(connection: connection, credential: credential, path: child.path)
            } else if child.isRegularFile {
                total += child.size ?? 0
            }
        }
        return total
    }

    func closeCurrentTab() {
        if let id = selectedTabID {
            closeTab(id)
        }
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard tabs.count > 1 else { return }
        if let tab = tabs.first(where: { $0.id == id }) {
            guard confirmDiscardEditSessions(tab.remoteEditSessions, action: "close this tab") else { return }
            cleanupEditSessions(tab.remoteEditSessions)
        }
        stopTerminal(for: id)
        tabCredentials.removeValue(forKey: id)?.clear()
        let index = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectTab(tabs[nextIndex].id)
        }
    }

    func duplicateTab(_ id: BrowserTab.ID) {
        syncCurrentTab()
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // Ban sao khong mang theo remoteEditSessions (tro toi file tam khong the dung chung).
        let copy = BrowserTab(
            title: tab.title,
            connectionID: tab.connectionID,
            connectionDraft: tab.connectionDraft,
            localPath: tab.localPath,
            remotePath: tab.remotePath,
            localItems: tab.localItems,
            remoteItems: tab.remoteItems,
            selectedLocalIDs: tab.selectedLocalIDs,
            selectedRemoteIDs: tab.selectedRemoteIDs,
            remoteEditSessions: [],
            terminalOutput: "",
            terminalStatus: .idle,
            isConnected: tab.isConnected,
            showsConnectionEditor: tab.showsConnectionEditor,
            showsInspector: tab.showsInspector
        )
        tabs.append(copy)
        tabCredentials[copy.id] = tabCredentials[id]?.clone() ?? SensitiveCredential()
        selectTab(copy.id)
    }

    func closeOtherTabs(keeping id: BrowserTab.ID) {
        syncCurrentTab()
        guard tabs.contains(where: { $0.id == id }) else { return }
        let others = tabs.filter { $0.id != id }
        guard !others.isEmpty else { return }
        guard confirmDiscardEditSessions(others.flatMap(\.remoteEditSessions), action: "close other tabs") else { return }
        if selectedTabID != id { selectTab(id) }
        for tab in others {
            cleanupEditSessions(tab.remoteEditSessions)
            stopTerminal(for: tab.id)
            tabCredentials.removeValue(forKey: tab.id)?.clear()
        }
        tabs.removeAll { $0.id != id }
    }

    func selectTab(_ id: BrowserTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        syncCurrentTab()
        selectedTabID = id
        restoreCurrentTab()
    }

    func showConnectionEditor() {
        showsConnectionEditor = true
        syncCurrentTab()
    }

    func hideConnectionEditor() {
        showsConnectionEditor = false
        syncCurrentTab()
    }

    func select(_ connection: SavedConnection) {
        guard !isSelectingConnection else { return }
        if let validationError = validate(connection) {
            status = validationError
            return
        }
        selectOrCreateTab(for: connection)
        if selectedConnectionID == connection.id, isConnected {
            showsConnectionEditor = false
            syncCurrentTab()
            return
        }
        if selectedConnectionID != connection.id {
            guard confirmDiscardEditSessions(remoteEditSessions, action: "switch connections") else { return }
            cleanupEditSessions(remoteEditSessions)
            if let selectedTabID { stopTerminal(for: selectedTabID) }
            remoteEditSessions = []
        }
        isSelectingConnection = true
        defer { isSelectingConnection = false }

        selectedConnectionID = connection.id
        connectionDraft = connection
        credentialForCurrentTab().clear()
        remotePath = connection.remotePath
        isConnected = false
        showsConnectionEditor = false
        syncCurrentTab()
        if shouldPromptForPassword(connection) {
            showsPasswordPrompt = true
        } else {
            refreshRemote()
        }
    }

    func editConnection(_ connection: SavedConnection) {
        selectOrCreateTab(for: connection)
        if selectedConnectionID != connection.id {
            guard confirmDiscardEditSessions(remoteEditSessions, action: "edit another connection") else { return }
            cleanupEditSessions(remoteEditSessions)
            if let selectedTabID { stopTerminal(for: selectedTabID) }
            remoteEditSessions = []
        }
        isSuppressingSidebarSelection = true
        selectedConnectionID = connection.id
        connectionDraft = connection
        credentialForCurrentTab().clear()
        remotePath = connection.remotePath
        showsConnectionEditor = true
        syncCurrentTab()
        Task { @MainActor in
            self.isSuppressingSidebarSelection = false
        }
    }

    func sidebarSelectionChanged(_ id: UUID?) {
        guard !isSuppressingSidebarSelection else { return }
        guard let id, let connection = connections.first(where: { $0.id == id }) else { return }
        guard selectedTab?.connectionID != id || !isConnected else { return }
        select(connection)
    }

    func saveDraft() {
        if let validationError = validate(connectionDraft) {
            status = validationError
            return
        }
        let previousConnection = connections.first { $0.id == connectionDraft.id }
        if let index = connections.firstIndex(where: { $0.id == connectionDraft.id }) {
            connections[index] = connectionDraft
        } else {
            connections.append(connectionDraft)
        }
        if let previousConnection,
           hostKeyScopeChanged(from: previousConnection, to: connectionDraft) {
            verifiedHostProbes.removeValue(forKey: hostKeyVerificationKey(for: previousConnection))
            verifiedHostProbes.removeValue(forKey: hostKeyVerificationKey(for: connectionDraft))
            Task { await sftp.closePooledSessions(for: connectionDraft.id) }
        }
        isSuppressingSidebarSelection = true
        selectedConnectionID = connectionDraft.id
        Task { @MainActor in
            self.isSuppressingSidebarSelection = false
        }
        // Password is not persisted; user enters it at connect time.
        saveConnections()
        status = "Connection saved"
        syncCurrentTab()
    }

    func connectDraft(password: String) {
        if let validationError = validate(connectionDraft) {
            status = validationError
            return
        }
        if shouldWarnAboutImportantServerPassword(connectionDraft, password: password),
           !confirmImportantServerPasswordUse(connection: connectionDraft) {
            status = "Connection cancelled"
            return
        }
        remotePath = connectionDraft.remotePath.isEmpty ? "/" : connectionDraft.remotePath
        capturePasswordInput(password)
        saveDraft()
        showsConnectionEditor = false
        syncCurrentTab()
        refreshRemote()
    }

    func newConnection() {
        guard confirmDiscardEditSessions(remoteEditSessions, action: "create a new connection") else { return }
        cleanupEditSessions(remoteEditSessions)
        if let selectedTabID { stopTerminal(for: selectedTabID) }
        let previousConnectionID = selectedConnectionID
        connectionDraft = SavedConnection()
        credentialForCurrentTab().clear()
        selectedConnectionID = nil
        isConnected = false
        showsConnectionEditor = true
        if let previousConnectionID {
            Task { await sftp.closePooledSessions(for: previousConnectionID) }
        }
        showsPasswordPrompt = false
        remoteItems = []
        remoteEditSessions = []
        selectedRemoteIDs.removeAll()
        remotePath = "/"
        syncCurrentTab()
    }

    func deleteSelectedConnection() {
        guard let id = selectedConnectionID else { return }
        removeConnection(id: id)
    }

    func disconnectConnection(id: UUID? = nil) {
        syncCurrentTab()
        guard let targetConnectionID = id ?? selectedConnectionID else { return }
        let targetTabIDs = tabs
            .filter { $0.connectionID == targetConnectionID }
            .map(\.id)
        guard !targetTabIDs.isEmpty else { return }

        let sessions = tabs
            .filter { targetTabIDs.contains($0.id) }
            .flatMap(\.remoteEditSessions)
        guard confirmDiscardEditSessions(sessions, action: "disconnect") else { return }

        for tabID in targetTabIDs {
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                cleanupEditSessions(tabs[index].remoteEditSessions)
                stopTerminal(for: tabID)
                resetConnectionState(forTabAt: index)
            }
            tabCredentials.removeValue(forKey: tabID)?.clear()
        }

        if let selectedTabID, targetTabIDs.contains(selectedTabID) {
            restoreCurrentTab()
        }
        Task { await sftp.closePooledSessions(for: targetConnectionID) }
        showsPasswordPrompt = false
        status = "Disconnected"
    }

    func connectWithPassword(_ password: String) {
        if shouldWarnAboutImportantServerPassword(connectionDraft, password: password),
           !confirmImportantServerPasswordUse(connection: connectionDraft) {
            credentialForCurrentTab().clear()
            showsPasswordPrompt = false
            syncCurrentTab()
            status = "Connection cancelled"
            return
        }
        capturePasswordInput(password)
        showsPasswordPrompt = false
        syncCurrentTab()
        refreshRemote()
    }

    func cancelPasswordPrompt() {
        showsPasswordPrompt = false
        credentialForCurrentTab().clear()
        syncCurrentTab()
    }

    func clearRecents() {
        recentsCleared = true
        status = "Recents cleared"
    }

    func openLocalPath(_ path: String) {
        localPath = path
        selectedLocalIDs.removeAll()
        noteRecentActivity()
        refreshLocal()
    }

    func removeConnection(id: UUID) {
        if selectedConnectionID == id {
            guard confirmDiscardEditSessions(remoteEditSessions, action: "remove this connection") else { return }
            cleanupEditSessions(remoteEditSessions)
            remoteEditSessions = []
        }
        connections.removeAll { $0.id == id }
        verifiedHostProbes = verifiedHostProbes.filter { key, _ in
            !key.hasPrefix("\(id.uuidString):")
        }
        Task { await sftp.closePooledSessions(for: id) }
        disconnectConnection(id: id)
        saveConnections()
        status = "Connection removed"
    }

    func refreshLocal() {
        let path = localPath
        let includeOwnerGroupPermissions = Self.needsLocalOwnerGroupPermissions(for: localBrowserPreferences)
        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try loadLocalDirectoryItems(
                        atPath: path,
                        includeOwnerGroupPermissions: includeOwnerGroupPermissions
                    )
                }.value
                guard self.localPath == path else { return }
                self.localItems = items
                self.status = "Local folder loaded"
                self.syncCurrentTab()
            } catch {
                guard self.localPath == path else { return }
                self.status = error.localizedDescription
            }
        }
    }

    func submitLocalPath() {
        let expandedPath = (localPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            status = "Local path is not a folder: \(localPath)"
            return
        }
        localPath = url.path
        selectedLocalIDs.removeAll()
        noteRecentActivity()
        refreshLocal()
    }

    func refreshRemote() {
        refreshRemote(finalStatus: "Remote folder loaded", mode: .foreground)
    }

    func submitRemotePath() {
        let trimmedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        remotePath = trimmedPath.isEmpty ? "/" : "/" + trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        selectedRemoteIDs.removeAll()
        noteRecentActivity()
        loadCurrentRemotePathUsingCache()
    }

    private func refreshRemote(finalStatus: String, mode: RemoteRefreshMode = .foreground) {
        guard let connection = selectedConnection else { status = "Choose a connection"; return }
        if let validationError = validate(connection) {
            status = validationError
            return
        }
        let path = remotePath
        let credential = credentialForCurrentTab().clone()
        let operationTabID = selectedTabID
        let operation: @Sendable () async throws -> Void = {
            let result: RemoteListingResult
            do {
                try await self.verifyHostKey(for: connection)
                result = try await self.sftp.list(connection: connection, credential: credential, path: path)
            } catch {
                if self.isAuthenticationFailure(error) {
                    await MainActor.run {
                        if let operationTabID {
                            self.tabCredentials.removeValue(forKey: operationTabID)?.clear()
                        }
                    }
                }
                throw error
            }
            await MainActor.run {
                guard let operationTabID,
                      let tabIndex = self.tabs.firstIndex(where: { $0.id == operationTabID }),
                      self.tabs[tabIndex].connectionID == connection.id,
                      self.tabs[tabIndex].remotePath == path
                else { return }

                self.storeRemoteListing(result.items, connectionID: connection.id, path: path)
                let statusText = result.skippedUnsafeCount > 0
                    ? "\(result.skippedUnsafeCount) unsafe remote entries were hidden."
                    : finalStatus

                if self.selectedTabID == operationTabID {
                    self.remoteItems = result.items
                    self.isConnected = true
                    self.showsConnectionEditor = false
                    self.status = statusText
                    self.syncCurrentTab()
                } else {
                    self.tabs[tabIndex].remoteItems = result.items
                    self.tabs[tabIndex].isConnected = true
                    self.tabs[tabIndex].showsConnectionEditor = false
                    self.tabs[tabIndex].title = connection.name
                }
            }
        }

        switch mode {
        case .foreground:
            runBusy("Loading remote folder", operation: operation)
        case .background:
            Task {
                do {
                    try await operation()
                } catch {
                    await MainActor.run {
                        self.status = error.localizedDescription
                    }
                }
            }
        }
    }

    private func loadCurrentRemotePathUsingCache() {
        if let connection = selectedConnection,
           let cachedItems = cachedRemoteItems(connectionID: connection.id, path: remotePath) {
            remoteItems = cachedItems
            status = "Remote folder loaded"
            syncCurrentTab()
            refreshRemote(finalStatus: "Remote folder updated", mode: .background)
            return
        }

        remoteItems = []
        syncCurrentTab()
        refreshRemote(finalStatus: "Remote folder loaded", mode: .foreground)
    }

    func openLocal(_ item: FileItem) {
        guard item.isDirectory else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            return
        }
        localPath = item.path
        selectedLocalIDs.removeAll()
        noteRecentActivity()
        refreshLocal()
        syncCurrentTab()
    }

    func openRemote(_ item: FileItem) {
        guard item.isDirectory else { return }
        remotePath = item.path
        selectedRemoteIDs.removeAll()
        noteRecentActivity()
        loadCurrentRemotePathUsingCache()
    }

    func localUp() {
        let parent = URL(fileURLWithPath: localPath).deletingLastPathComponent().path
        localPath = parent.isEmpty ? "/" : parent
        noteRecentActivity()
        refreshLocal()
        syncCurrentTab()
    }

    func remoteUp() {
        guard remotePath != "/" else { return }
        let parent = URL(fileURLWithPath: remotePath).deletingLastPathComponent().path
        remotePath = parent.isEmpty ? "/" : parent
        noteRecentActivity()
        loadCurrentRemotePathUsingCache()
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
            noteRecentActivity()
            refreshLocal()
            syncCurrentTab()
        }
    }

    func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connectionDraft.privateKeyPath = url.path
        connectionDraft.privateKeyBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        syncCurrentTab()
    }

    func uploadSelected() {
        guard selectedConnection != nil else { return }
        let items = selectedLocalItems
        guard !items.isEmpty else { return }
        uploadConflictBatchPolicy = nil
        reservedUploadPaths.removeAll()
        for item in items {
            let destination = joinRemote(remotePath, item.name)
            upload(item: item, remotePath: destination, refreshWhenDone: item.id == items.last?.id)
        }
    }

    func uploadFromPicker() {
        guard selectedConnection != nil else { status = "Choose a connection"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            uploadConflictBatchPolicy = nil
            reservedUploadPaths.removeAll()
            for url in panel.urls {
                let item = localFileItem(for: url)
                upload(item: item, remotePath: joinRemote(remotePath, url.lastPathComponent), refreshWhenDone: url == panel.urls.last)
            }
        }
    }

    func uploadEditedRemoteFile(_ session: RemoteEditSession) {
        guard let connection = selectedConnection else { return }
        guard confirmImportantServerAction(
            connection: connection,
            action: "replace the edited remote file",
            remotePath: session.remotePath,
            confirmation: "REPLACE"
        ) else { return }
        let credential = credentialForCurrentTab().clone()
        let transferID = enqueue(direction: .upload, source: session.localPath, destination: session.remotePath)
        guard let control = transferControls[transferID] else { return }
        runBusy("Uploading edited file", transferID: transferID) {
            let warning = try await self.transferLimiter.withPermit {
                guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                await MainActor.run { self.markTransfer(transferID, .running, "") }
                return try await self.sftp.upload(
                    connection: connection,
                    credential: credential,
                    localPath: session.localPath,
                    remotePath: session.remotePath,
                    policy: .replace,
                    control: control
                )
            }
            await MainActor.run {
                self.markTransfer(transferID, .done, warning ?? "Uploaded edited file")
                self.remoteEditSessions.removeAll { $0.id == session.id }
                self.cleanupEditSessions([session])
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: session.remotePath)
                self.syncCurrentTab()
                self.refreshRemote()
            }
        }
    }

    func discardRemoteEditSession(_ session: RemoteEditSession) {
        let alert = NSAlert()
        alert.messageText = "Discard changes to \"\(session.fileName)\"?"
        alert.informativeText = "The local temporary copy will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remoteEditSessions.removeAll { $0.id == session.id }
        cleanupEditSessions([session])
        syncCurrentTab()
    }

    func clearCompletedTransfers() {
        let completedIDs = Set(transfers.filter { $0.state == .done || $0.state == .failed || $0.state == .cancelled }.map(\.id))
        guard !completedIDs.isEmpty else { return }
        transfers.removeAll { completedIDs.contains($0.id) }
        for id in completedIDs {
            transferControls.removeValue(forKey: id)
        }
        status = "Completed transfers cleared"
    }

    func clearRemoteEdits() {
        guard !remoteEditSessions.isEmpty else { return }
        guard confirmDiscardEditSessions(remoteEditSessions, action: "clear remote edits") else { return }
        cleanupEditSessions(remoteEditSessions)
        remoteEditSessions = []
        if transferPanelTab == .remoteEdits {
            transferPanelTab = .transfers
        }
        status = "Remote edits cleared"
        syncCurrentTab()
    }

    private func upload(item: FileItem, remotePath: String, refreshWhenDone: Bool) {
        if item.isDirectory {
            uploadFolder(item: item, remotePath: remotePath, refreshWhenDone: refreshWhenDone)
        } else {
            upload(localPath: item.path, remotePath: remotePath, refreshWhenDone: refreshWhenDone)
        }
    }

    private func upload(localPath: String, remotePath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        let credential = credentialForCurrentTab().clone()
        let transferID = enqueue(direction: .upload, source: localPath, destination: remotePath)
        guard let control = transferControls[transferID] else { return }
        runBusy("Uploading", transferID: transferID) {
            let resolution = try await self.resolveUploadConflict(
                connection: connection,
                credential: credential,
                remotePath: remotePath
            )
            guard case let .upload(destination, policy) = resolution else {
                await MainActor.run {
                    self.markTransfer(transferID, .cancelled, "Skipped")
                    if refreshWhenDone {
                        self.refreshRemote()
                    }
                }
                return
            }
            let warning = try await self.transferLimiter.withPermit {
                guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                await MainActor.run {
                    self.updateTransferDestination(transferID, destination)
                    self.markTransfer(transferID, .running, "")
                }
                return try await self.sftp.upload(connection: connection, credential: credential, localPath: localPath, remotePath: destination, policy: policy, control: control)
            }
            await MainActor.run {
                self.markTransfer(transferID, .done, warning ?? "Uploaded")
                if let warning { self.status = warning }
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: destination)
                if refreshWhenDone {
                    self.refreshRemote()
                }
            }
        }
    }

    private func uploadFolder(item: FileItem, remotePath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        let credential = credentialForCurrentTab().clone()
        let transferID = enqueue(direction: .upload, source: item.path, destination: remotePath)
        guard let control = transferControls[transferID] else { return }
        runBusy("Uploading folder", transferID: transferID) {
            let summary = try await self.transferLimiter.withPermit {
                guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                await MainActor.run { self.markTransfer(transferID, .running, "Preparing folder") }
                return try await self.uploadLocalFolder(
                    connection: connection,
                    credential: credential,
                    localURL: URL(fileURLWithPath: item.path, isDirectory: true),
                    remotePath: remotePath,
                    control: control,
                    transferID: transferID
                )
            }
            await MainActor.run {
                let fileText = "\(summary.uploadedFiles) file\(summary.uploadedFiles == 1 ? "" : "s")"
                let skippedText = summary.skippedItems > 0 ? ", skipped \(summary.skippedItems)" : ""
                self.markTransfer(transferID, .done, "Uploaded \(fileText)\(skippedText)")
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: remotePath, wasDirectory: true)
                if refreshWhenDone {
                    self.refreshRemote()
                }
            }
        }
    }

    private func uploadLocalFolder(
        connection: SavedConnection,
        credential: SensitiveCredential,
        localURL: URL,
        remotePath: String,
        control: TransferControl,
        transferID: UUID
    ) async throws -> FolderUploadSummary {
        guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
        guard let uploadRemotePath = try await resolveUploadFolderConflict(
            connection: connection,
            credential: credential,
            remotePath: remotePath
        ) else {
            return FolderUploadSummary(uploadedFiles: 0, skippedItems: 1)
        }
        await MainActor.run {
            self.markTransfer(transferID, .running, "Creating \(localURL.lastPathComponent)")
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var summary = FolderUploadSummary()
        for childURL in children {
            guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
            let values = try childURL.resourceValues(forKeys: keys)
            let childRemotePath = joinRemote(uploadRemotePath, childURL.lastPathComponent)

            if values.isDirectory == true {
                let childSummary = try await uploadLocalFolder(
                    connection: connection,
                    credential: credential,
                    localURL: childURL,
                    remotePath: childRemotePath,
                    control: control,
                    transferID: transferID
                )
                summary.uploadedFiles += childSummary.uploadedFiles
                summary.skippedItems += childSummary.skippedItems
            } else if values.isRegularFile == true {
                await MainActor.run {
                    self.markTransfer(transferID, .running, "Uploading \(childURL.lastPathComponent)")
                }
                let resolution = try await resolveUploadConflict(
                    connection: connection,
                    credential: credential,
                    remotePath: childRemotePath
                )
                guard case let .upload(destination, policy) = resolution else {
                    summary.skippedItems += 1
                    continue
                }
                _ = try await sftp.upload(
                    connection: connection,
                    credential: credential,
                    localPath: childURL.path,
                    remotePath: destination,
                    policy: policy,
                    control: control
                )
                summary.uploadedFiles += 1
            } else {
                summary.skippedItems += 1
            }
        }
        return summary
    }

    private func localFileItem(for url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey, .isHiddenKey])
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isDirectory = values?.isDirectory == true
        return FileItem(
            name: url.lastPathComponent,
            path: url.path,
            isDirectory: isDirectory,
            size: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            kind: isDirectory ? "Folder" : (values?.contentType?.localizedDescription ?? "File"),
            owner: attributes?[.ownerAccountName] as? String,
            group: attributes?[.groupOwnerAccountName] as? String,
            permissions: (attributes?[.posixPermissions] as? NSNumber)?.uint32Value,
            isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix(".")
        )
    }

    func downloadSelected() {
        guard selectedConnection != nil else { return }
        let items = selectedRemoteItems
        guard !items.isEmpty else { return }
        for item in items {
            guard let destination = safeLocalDestination(base: URL(fileURLWithPath: localPath), name: item.name) else {
                status = "Refused unsafe remote filename."
                continue
            }
            download(item: item, localPath: destination.path, refreshWhenDone: item.id == items.last?.id)
        }
    }

    func downloadSelectedToFolder() {
        let items = selectedRemoteItems
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folder = panel.url {
            for item in items {
                guard let destination = safeLocalDestination(base: folder, name: item.name) else {
                    status = "Refused unsafe remote filename."
                    continue
                }
                download(item: item, localPath: destination.path, refreshWhenDone: false)
            }
        }
    }

    private func download(item: FileItem, localPath: String, refreshWhenDone: Bool) {
        if item.isDirectory {
            downloadFolder(item: item, localPath: localPath, refreshWhenDone: refreshWhenDone)
        } else {
            download(remotePath: item.path, localPath: localPath, refreshWhenDone: refreshWhenDone)
        }
    }

    private func downloadFolder(item: FileItem, localPath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        guard let destination = resolveDirectoryDownloadConflict(at: localPath) else {
            status = "Download cancelled"
            return
        }
        let credential = credentialForCurrentTab().clone()
        let transferID = enqueue(direction: .download, source: item.path, destination: destination)
        guard let control = transferControls[transferID] else { return }
        runBusy("Downloading folder", transferID: transferID) {
            guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
            await MainActor.run { self.markTransfer(transferID, .running, "Preparing folder") }
            let plan = try await self.planRemoteFolderDownload(
                connection: connection,
                credential: credential,
                remotePath: item.path,
                localURL: URL(fileURLWithPath: destination, isDirectory: true),
                control: control,
                transferID: transferID
            )
            let summary = try await self.downloadPlannedFolderFiles(
                connection: connection,
                credential: credential,
                plan: plan,
                parentControl: control,
                transferID: transferID
            )
            await MainActor.run {
                let fileText = "\(summary.downloadedFiles) file\(summary.downloadedFiles == 1 ? "" : "s")"
                let skippedText = summary.skippedItems > 0 ? ", skipped \(summary.skippedItems)" : ""
                self.markTransfer(transferID, .done, "Downloaded \(fileText)\(skippedText)")
                if refreshWhenDone {
                    self.refreshLocal()
                }
            }
        }
    }

    private func download(remotePath: String, localPath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        guard let resolution = resolveDownloadConflict(at: localPath) else {
            status = "Download cancelled"
            return
        }
        let credential = credentialForCurrentTab().clone()
        let destination = resolution.path
        let transferID = enqueue(direction: .download, source: remotePath, destination: destination)
        guard let control = transferControls[transferID] else { return }
        runBusy("Downloading", transferID: transferID) {
            try await self.transferLimiter.withPermit {
                guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                await MainActor.run { self.markTransfer(transferID, .running, "") }
                try await self.sftp.download(connection: connection, credential: credential, remotePath: remotePath, localPath: destination, policy: resolution.policy, control: control)
            }
            await MainActor.run {
                self.markTransfer(transferID, .done, "Downloaded")
                if refreshWhenDone {
                    self.refreshLocal()
                }
            }
        }
    }

    private func planRemoteFolderDownload(
        connection: SavedConnection,
        credential: SensitiveCredential,
        remotePath: String,
        localURL: URL,
        control: TransferControl,
        transferID: UUID
    ) async throws -> FolderDownloadPlan {
        guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
        await MainActor.run {
            self.markTransfer(transferID, .running, "Listing \(URL(fileURLWithPath: remotePath).lastPathComponent)")
        }

        var plan = FolderDownloadPlan()
        plan.directories.append(localURL.path)
        let result = try await sftp.list(connection: connection, credential: credential, path: remotePath)
        for child in result.items {
            guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
            guard let childURL = safeLocalDestination(base: localURL, name: child.name) else {
                throw AppError.commandFailed("Refused unsafe remote filename: \(child.name)")
            }

            if child.isDirectory {
                let childPlan = try await planRemoteFolderDownload(
                    connection: connection,
                    credential: credential,
                    remotePath: child.path,
                    localURL: childURL,
                    control: control,
                    transferID: transferID
                )
                plan.files.append(contentsOf: childPlan.files)
                plan.directories.append(contentsOf: childPlan.directories)
                plan.skippedItems += childPlan.skippedItems
            } else {
                guard child.isRegularFile else {
                    plan.skippedItems += 1
                    await MainActor.run {
                        self.markTransfer(transferID, .running, "Skipped unsupported item \(child.name)")
                    }
                    continue
                }
                let fileDestination = availableDownloadPathIfNeeded(for: childURL.path)
                plan.files.append(FolderDownloadFile(
                    id: child.path,
                    remotePath: child.path,
                    localPath: fileDestination,
                    name: child.name,
                    size: UInt64(max(0, child.size ?? 0))
                ))
            }
        }
        return plan
    }

    private func downloadPlannedFolderFiles(
        connection: SavedConnection,
        credential: SensitiveCredential,
        plan: FolderDownloadPlan,
        parentControl: TransferControl,
        transferID: UUID
    ) async throws -> FolderDownloadSummary {
        for directory in plan.directories {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let progress = FolderDownloadProgress(totalBytes: plan.totalBytes)
        await MainActor.run {
            self.updateTransferProgress(transferID, transferred: 0, total: plan.totalBytes)
        }

        let folderLimiter = TransferLimiter(limit: TransferTuning.maxConcurrentFolderDownloads)
        var summary = FolderDownloadSummary(downloadedFiles: 0, skippedItems: plan.skippedItems)
        let largeFiles = plan.files.filter { $0.size >= TransferTuning.parallelDownloadThreshold }
        let smallFiles = plan.files.filter { $0.size < TransferTuning.parallelDownloadThreshold }

        for file in largeFiles {
            let didDownload = try await self.transferLimiter.withPermit {
                guard !parentControl.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                let childControl = TransferControl(parent: parentControl) { transferred, _ in
                    Task {
                        let aggregate = await progress.update(fileID: file.id, transferred: transferred)
                        await MainActor.run {
                            self.updateTransferProgress(transferID, transferred: aggregate.transferred, total: aggregate.total)
                        }
                    }
                }
                await MainActor.run {
                    self.markTransfer(transferID, .running, "Downloading \(file.name)")
                }
                do {
                    try await self.sftp.download(
                        connection: connection,
                        credential: credential,
                        remotePath: file.remotePath,
                        localPath: file.localPath,
                        policy: .createNew,
                        control: childControl
                    )
                    let aggregate = await progress.update(fileID: file.id, transferred: file.size)
                    await MainActor.run {
                        self.updateTransferProgress(transferID, transferred: aggregate.transferred, total: aggregate.total)
                    }
                    return true
                } catch {
                    guard !parentControl.isCancelled else { throw error }
                    await MainActor.run {
                        self.markTransfer(transferID, .running, "Skipped \(file.name): \(error.localizedDescription)")
                    }
                    return false
                }
            }
            if didDownload {
                summary.downloadedFiles += 1
            } else {
                summary.skippedItems += 1
            }
        }

        let workerCount = min(TransferTuning.maxConcurrentFolderDownloads, max(1, smallFiles.count))
        var batches = Array(repeating: [FolderDownloadFile](), count: workerCount)
        for (index, file) in smallFiles.enumerated() {
            batches[index % workerCount].append(file)
        }

        try await withThrowingTaskGroup(of: ([FolderDownloadFile], [BatchDownloadResult]).self) { group in
            for batchFiles in batches where !batchFiles.isEmpty {
                group.addTask {
                    try await folderLimiter.withPermit {
                        try await self.transferLimiter.withPermit {
                            guard !parentControl.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                            await MainActor.run {
                                let firstName = batchFiles.first?.name ?? "batch"
                                self.markTransfer(transferID, .running, "Downloading \(firstName)")
                            }
                            do {
                                let results = try await self.sftp.downloadBatch(
                                    connection: connection,
                                    credential: credential,
                                    files: batchFiles,
                                    parentControl: parentControl
                                ) { index, transferred, _ in
                                    guard batchFiles.indices.contains(index) else { return }
                                    let file = batchFiles[index]
                                    Task {
                                        let aggregate = await progress.update(fileID: file.id, transferred: transferred)
                                        await MainActor.run {
                                            self.updateTransferProgress(transferID, transferred: aggregate.transferred, total: aggregate.total)
                                        }
                                    }
                                }
                                return (batchFiles, results)
                            } catch {
                                guard !parentControl.isCancelled else { throw error }
                                let results = batchFiles.indices.map { index in
                                    BatchDownloadResult(
                                        index: index,
                                        didDownload: false,
                                        errorMessage: error.localizedDescription
                                    )
                                }
                                return (batchFiles, results)
                            }
                        }
                    }
                }
            }

            for try await (batchFiles, results) in group {
                for result in results {
                    guard batchFiles.indices.contains(result.index) else { continue }
                    let file = batchFiles[result.index]
                    if result.didDownload {
                        summary.downloadedFiles += 1
                        let aggregate = await progress.update(fileID: file.id, transferred: file.size)
                        await MainActor.run {
                            self.updateTransferProgress(transferID, transferred: aggregate.transferred, total: aggregate.total)
                        }
                    } else {
                        summary.skippedItems += 1
                        let message = result.errorMessage ?? "Download failed."
                        await MainActor.run {
                            self.markTransfer(transferID, .running, "Skipped \(file.name): \(message)")
                        }
                    }
                }
            }
        }

        return summary
    }

    private func resolveUploadConflict(
        connection: SavedConnection,
        credential: SensitiveCredential,
        remotePath: String
    ) async throws -> UploadConflictResolution {
        let remotePathIsReserved = reservedUploadPaths.contains(remotePath)
        let remotePathExists: Bool
        if remotePathIsReserved {
            remotePathExists = true
        } else {
            remotePathExists = try await remoteEntry(at: remotePath, connection: connection, credential: credential) != nil
        }
        guard remotePathExists else {
            reservedUploadPaths.insert(remotePath)
            return .upload(path: remotePath, policy: .createNew)
        }

        if let uploadConflictBatchPolicy, !connection.requiresImportantServerGuards {
            return try await uploadResolution(for: uploadConflictBatchPolicy, remotePath: remotePath, connection: connection, credential: credential)
        }

        let promptResult = promptUploadConflict(remotePath: remotePath, connection: connection)
        if let batchPolicy = promptResult.applyToAllPolicy {
            uploadConflictBatchPolicy = batchPolicy
        }

        switch promptResult.choice {
        case .replace:
            return .upload(path: remotePath, policy: .replace)
        case .keepBoth:
            let destination = try await availableRemoteUploadPath(for: remotePath, connection: connection, credential: credential)
            reservedUploadPaths.insert(destination)
            return .upload(path: destination, policy: .createNew)
        case .skip:
            return .skip
        case .cancel:
            throw AppError.commandFailed("Upload cancelled.")
        }
    }

    private func resolveUploadFolderConflict(
        connection: SavedConnection,
        credential: SensitiveCredential,
        remotePath: String
    ) async throws -> String? {
        let existingEntry: FileItem?
        if reservedUploadPaths.contains(remotePath) {
            existingEntry = FileItem(name: URL(fileURLWithPath: remotePath).lastPathComponent, path: remotePath, isDirectory: true)
        } else {
            existingEntry = try await remoteEntry(at: remotePath, connection: connection, credential: credential)
        }

        guard let existingEntry else {
            _ = try await sftp.makeDirectory(connection: connection, credential: credential, path: remotePath)
            reservedUploadPaths.insert(remotePath)
            return remotePath
        }

        if let uploadConflictBatchPolicy, !connection.requiresImportantServerGuards {
            return try await folderUploadResolution(
                for: uploadConflictBatchPolicy,
                existingEntry: existingEntry,
                remotePath: remotePath,
                connection: connection,
                credential: credential
            )
        }

        guard existingEntry.isDirectory else {
            let promptResult = promptFolderUploadBlockedByFile(remotePath: remotePath, connection: connection)
            if let batchPolicy = promptResult.applyToAllPolicy {
                uploadConflictBatchPolicy = batchPolicy
            }
            switch promptResult.choice {
            case .keepBoth:
                let destination = try await availableRemoteUploadPath(for: remotePath, connection: connection, credential: credential)
                _ = try await sftp.makeDirectory(connection: connection, credential: credential, path: destination)
                reservedUploadPaths.insert(destination)
                return destination
            case .skip:
                return nil
            case .cancel:
                throw AppError.commandFailed("Upload cancelled.")
            case .replace:
                throw AppError.commandFailed("A file named \"\(existingEntry.name)\" already exists on the server.")
            }
        }

        let promptResult = promptUploadConflict(
            remotePath: remotePath,
            connection: connection,
            primaryActionTitle: "Merge"
        )
        if let batchPolicy = promptResult.applyToAllPolicy {
            uploadConflictBatchPolicy = batchPolicy
        }

        switch promptResult.choice {
        case .replace:
            guard existingEntry.isDirectory else {
                throw AppError.commandFailed("A file named \"\(existingEntry.name)\" already exists on the server.")
            }
            return remotePath
        case .keepBoth:
            let destination = try await availableRemoteUploadPath(for: remotePath, connection: connection, credential: credential)
            _ = try await sftp.makeDirectory(connection: connection, credential: credential, path: destination)
            reservedUploadPaths.insert(destination)
            return destination
        case .skip:
            return nil
        case .cancel:
            throw AppError.commandFailed("Upload cancelled.")
        }
    }

    private func folderUploadResolution(
        for policy: UploadConflictBatchPolicy,
        existingEntry: FileItem,
        remotePath: String,
        connection: SavedConnection,
        credential: SensitiveCredential
    ) async throws -> String? {
        switch policy {
        case .replace:
            guard existingEntry.isDirectory else {
                throw AppError.commandFailed("A file named \"\(existingEntry.name)\" already exists on the server.")
            }
            return remotePath
        case .keepBoth:
            let destination = try await availableRemoteUploadPath(for: remotePath, connection: connection, credential: credential)
            _ = try await sftp.makeDirectory(connection: connection, credential: credential, path: destination)
            reservedUploadPaths.insert(destination)
            return destination
        case .skip:
            return nil
        }
    }

    private func uploadResolution(
        for policy: UploadConflictBatchPolicy,
        remotePath: String,
        connection: SavedConnection,
        credential: SensitiveCredential
    ) async throws -> UploadConflictResolution {
        switch policy {
        case .replace:
            return .upload(path: remotePath, policy: .replace)
        case .keepBoth:
            let destination = try await availableRemoteUploadPath(for: remotePath, connection: connection, credential: credential)
            reservedUploadPaths.insert(destination)
            return .upload(path: destination, policy: .createNew)
        case .skip:
            return .skip
        }
    }

    private func promptUploadConflict(
        remotePath: String,
        connection: SavedConnection,
        primaryActionTitle: String = "Replace"
    ) -> (choice: UploadConflictChoice, applyToAllPolicy: UploadConflictBatchPolicy?) {
        let name = URL(fileURLWithPath: remotePath).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "An item named \"\(name)\" already exists on the server."
        alert.informativeText = connection.requiresImportantServerGuards
            ? "Important Server: \(remoteActionContext(connection: connection, remotePath: remotePath))\nChoose what Volt should do before uploading."
            : "Choose what Volt should do before uploading."
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryActionTitle)
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        let checkboxTitle = connection.requiresImportantServerGuards
            ? "Apply to all upload conflicts (disabled for Important Server)"
            : "Apply to all upload conflicts"
        let checkbox = NSButton(checkboxWithTitle: checkboxTitle, target: nil, action: nil)
        checkbox.state = .off
        checkbox.isEnabled = !connection.requiresImportantServerGuards
        alert.accessoryView = checkbox

        var choice: UploadConflictChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            choice = .replace
        case .alertSecondButtonReturn:
            choice = .keepBoth
        case .alertThirdButtonReturn:
            choice = .skip
        default:
            choice = .cancel
        }

        if choice == .replace,
           !confirmImportantServerAction(
                connection: connection,
                action: primaryActionTitle.lowercased() == "merge" ? "merge into the existing remote folder" : "replace the remote item",
                remotePath: remotePath,
                confirmation: primaryActionTitle.uppercased()
           ) {
            choice = .cancel
        }

        let applyToAllPolicy: UploadConflictBatchPolicy?
        if checkbox.state == .on {
            switch choice {
            case .replace:
                applyToAllPolicy = .replace
            case .keepBoth:
                applyToAllPolicy = .keepBoth
            case .skip:
                applyToAllPolicy = .skip
            case .cancel:
                applyToAllPolicy = nil
            }
        } else {
            applyToAllPolicy = nil
        }

        return (choice, applyToAllPolicy)
    }

    private func promptFolderUploadBlockedByFile(remotePath: String, connection: SavedConnection) -> (choice: UploadConflictChoice, applyToAllPolicy: UploadConflictBatchPolicy?) {
        let name = URL(fileURLWithPath: remotePath).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "A file named \"\(name)\" already exists on the server."
        alert.informativeText = connection.requiresImportantServerGuards
            ? "Important Server: \(remoteActionContext(connection: connection, remotePath: remotePath))\nA folder cannot be merged into that file. Choose a new folder name or skip it."
            : "A folder cannot be merged into that file. Choose a new folder name or skip it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        let checkboxTitle = connection.requiresImportantServerGuards
            ? "Apply to all upload conflicts (disabled for Important Server)"
            : "Apply to all upload conflicts"
        let checkbox = NSButton(checkboxWithTitle: checkboxTitle, target: nil, action: nil)
        checkbox.state = .off
        checkbox.isEnabled = !connection.requiresImportantServerGuards
        alert.accessoryView = checkbox

        let choice: UploadConflictChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            choice = .keepBoth
        case .alertSecondButtonReturn:
            choice = .skip
        default:
            choice = .cancel
        }

        let applyToAllPolicy: UploadConflictBatchPolicy?
        if checkbox.state == .on {
            switch choice {
            case .keepBoth:
                applyToAllPolicy = .keepBoth
            case .skip:
                applyToAllPolicy = .skip
            default:
                applyToAllPolicy = nil
            }
        } else {
            applyToAllPolicy = nil
        }

        return (choice, applyToAllPolicy)
    }

    private func remoteEntry(
        at path: String,
        connection: SavedConnection,
        credential: SensitiveCredential
    ) async throws -> FileItem? {
        guard let parent = remoteParentPath(path) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent

        if selectedConnectionID == connection.id && parent == remotePath {
            return remoteItems.first { $0.name == name }
        }

        if let cachedItems = cachedRemoteItems(connectionID: connection.id, path: parent) {
            return cachedItems.first { $0.name == name }
        }

        let result = try await sftp.list(connection: connection, credential: credential, path: parent)
        storeRemoteListing(result.items, connectionID: connection.id, path: parent)
        return result.items.first { $0.name == name }
    }

    private func availableRemoteUploadPath(
        for path: String,
        connection: SavedConnection,
        credential: SensitiveCredential
    ) async throws -> String {
        guard let parent = remoteParentPath(path) else { return path }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let fileExtension = (name as NSString).pathExtension
        let baseName = fileExtension.isEmpty ? name : (name as NSString).deletingPathExtension

        var index = 2
        while true {
            let candidateName = fileExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(fileExtension)"
            let candidate = joinRemote(parent, candidateName)
            if !reservedUploadPaths.contains(candidate),
               try await remoteEntry(at: candidate, connection: connection, credential: credential) == nil {
                return candidate
            }
            index += 1
        }
    }

    private func resolveDownloadConflict(at path: String) -> (path: String, policy: DownloadPublishPolicy)? {
        guard FileManager.default.fileExists(atPath: path) else { return (path, .createNew) }
        let alert = NSAlert()
        alert.messageText = "A file named \"\(URL(fileURLWithPath: path).lastPathComponent)\" already exists."
        alert.informativeText = "Choose whether to replace it or keep both files."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return (path, .replace)
        case .alertSecondButtonReturn:
            return (availableDownloadPath(for: path), .createNew)
        default:
            return nil
        }
    }

    private func resolveDirectoryDownloadConflict(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return path }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        let alert = NSAlert()
        alert.messageText = "A \(isDirectory.boolValue ? "folder" : "file") named \"\(URL(fileURLWithPath: path).lastPathComponent)\" already exists."
        alert.informativeText = isDirectory.boolValue
            ? "Choose whether to merge into the existing folder or keep both folders."
            : "A folder cannot replace this file. Choose a new folder name or cancel."
        if isDirectory.boolValue {
            alert.addButton(withTitle: "Merge")
        }
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn where isDirectory.boolValue:
            return path
        case isDirectory.boolValue ? .alertSecondButtonReturn : .alertFirstButtonReturn:
            return availableDownloadPath(for: path)
        default:
            return nil
        }
    }

    private func availableDownloadPathIfNeeded(for path: String) -> String {
        FileManager.default.fileExists(atPath: path) ? availableDownloadPath(for: path) : path
    }

    private func availableDownloadPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let fileExtension = url.pathExtension
        let baseName = fileExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidateName = fileExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName).path
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
            index += 1
        }
    }

    func makeLocalFolder() {
        let name = prompt("New Local Folder", defaultValue: "Untitled Folder", actionTitle: "Create")
        guard !name.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: localPath).appendingPathComponent(name).path, withIntermediateDirectories: false)
            refreshLocal()
        } catch {
            status = error.localizedDescription
        }
    }

    func makeLocalFile() {
        let name = prompt("New Local File", defaultValue: "untitled.txt", actionTitle: "Create")
        guard !name.isEmpty else { return }
        do {
            let url = URL(fileURLWithPath: localPath).appendingPathComponent(name)
            try Data().write(to: url)
            refreshLocal()
            NSWorkspace.shared.open(url)
        } catch {
            status = error.localizedDescription
        }
    }

    func makeRemoteFolder() {
        guard let connection = selectedConnection else { return }
        let name = prompt("New Remote Folder", defaultValue: "Untitled Folder", actionTitle: "Create")
        guard !name.isEmpty else { return }
        let path = joinRemote(remotePath, name)
        let credential = credentialForCurrentTab().clone()
        runBusy("Creating folder") {
            let warning = try await self.sftp.makeDirectory(connection: connection, credential: credential, path: path)
            await MainActor.run {
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: path, wasDirectory: true)
                self.refreshRemote(finalStatus: warning ?? "Remote folder loaded")
            }
        }
    }

    func makeRemoteFile() {
        guard let connection = selectedConnection else { return }
        let name = prompt("New Remote File", defaultValue: "untitled.txt", actionTitle: "Create")
        guard !name.isEmpty else { return }
        let path = joinRemote(remotePath, name)
        let credential = credentialForCurrentTab().clone()
        runBusy("Creating file") {
            let warning = try await self.sftp.createFile(connection: connection, credential: credential, remotePath: path)
            await MainActor.run {
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: path)
                self.refreshRemote(finalStatus: warning ?? "Remote folder loaded")
            }
        }
    }

    // MARK: - Local Context Menu Actions

    func getInfoLocalSelected() {
        guard selectedLocal != nil else { return }
        showsInspector = true
        syncCurrentTab()
    }

    func openInNewTabLocal() {
        guard let item = selectedLocal, item.isDirectory else { return }
        var newTab = currentSessionTab(title: item.name)
        newTab.localPath = item.path
        newTab.localItems = []
        newTab.selectedLocalIDs.removeAll()
        tabs.append(newTab)
        tabCredentials[newTab.id] = credentialForCurrentTab().clone()
        selectTab(newTab.id)
    }

    func duplicateLocalSelected() {
        guard let item = selectedLocal else { return }
        let newPath = item.path + " copy"
        do {
            try FileManager.default.copyItem(atPath: item.path, toPath: newPath)
            refreshLocal()
        } catch {
            status = error.localizedDescription
        }
    }

    func moveLocalSelected() {
        guard let item = selectedLocal else { return }
        let newName = prompt("Move Local Item To:", defaultValue: item.name, actionTitle: "Move")
        guard !newName.isEmpty, newName != item.name else { return }
        
        let newPath = URL(fileURLWithPath: localPath).appendingPathComponent(newName).path
        do {
            try FileManager.default.moveItem(atPath: item.path, toPath: newPath)
            selectedLocalIDs.removeAll()
            refreshLocal()
        } catch {
            status = error.localizedDescription
        }
    }

    func getInfoRemoteSelected() {
        guard selectedRemote != nil else { return }
        showsInspector = true
        syncCurrentTab()
    }

    func openInNewTabRemote() {
        guard let item = selectedRemote, item.isDirectory else { return }
        var newTab = currentSessionTab(title: item.name)
        newTab.remotePath = item.path
        let cachedItems = selectedConnection.flatMap {
            cachedRemoteItems(connectionID: $0.id, path: item.path)
        }
        newTab.remoteItems = cachedItems ?? []
        newTab.selectedRemoteIDs.removeAll()
        tabs.append(newTab)
        tabCredentials[newTab.id] = credentialForCurrentTab().clone()
        selectTab(newTab.id)
        if cachedItems != nil {
            refreshRemote(finalStatus: "Remote folder updated", mode: .background)
        } else {
            refreshRemote(finalStatus: "Remote folder loaded", mode: .foreground)
        }
    }

    func duplicateRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        let newName = item.name + " copy"
        let newPath = joinRemote(remotePath, newName)
        let credential = credentialForCurrentTab().clone()
        runBusy("Duplicating remote item") {
            // Using cp -r over SSH
            let runner = CommandRunner()
            let executable = "/usr/bin/ssh"
            guard credential.isEmpty else { throw AppError.unsupportedPasswordAuth }
            let controlDir = try SFTPClient.controlSocketDir()
            let knownHostsPath = try AppPaths.knownHostsURL().path
            var args = [
                "-oBatchMode=yes",
                "-oStrictHostKeyChecking=yes",
                "-oUserKnownHostsFile=\(knownHostsPath)",
                "-oGlobalKnownHostsFile=/dev/null",
                "-oControlMaster=auto",
                "-oControlPath=\(controlDir)/volt_%h_%p_%r",
                "-oControlPersist=5m",
                "-p", "\(connection.port)"
            ]
            if !connection.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(contentsOf: ["-i", connection.privateKeyPath])
            }
            args.append("--")
            args.append("\(connection.username)@\(connection.host)")
            
            let quotedSrc = "'" + item.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let quotedDst = "'" + newPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            args.append("cp -r \(quotedSrc) \(quotedDst)")

            _ = try runner.run(executable, arguments: args, stdin: "")
            
            await MainActor.run {
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: newPath, wasDirectory: item.isDirectory)
                self.refreshRemote()
            }
        }
    }

    func moveRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        let newName = prompt("Move Remote Item To:", defaultValue: item.name, actionTitle: "Move")
        guard !newName.isEmpty, newName != item.name else { return }
        
        let newPath = joinRemote(remotePath, newName)
        guard confirmImportantServerAction(
            connection: connection,
            action: "move the remote item",
            remotePath: "\(item.path) -> \(newPath)",
            confirmation: "MOVE"
        ) else { return }
        let credential = credentialForCurrentTab().clone()
        runBusy("Moving remote item") {
            try await self.sftp.rename(connection: connection, credential: credential, from: item.path, to: newPath)
            await MainActor.run {
                self.selectedRemoteIDs.removeAll()
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: item.path, wasDirectory: item.isDirectory)
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: newPath, wasDirectory: item.isDirectory)
                self.refreshRemote()
            }
        }
    }

    func deleteLocalSelected() {
        guard let item = selectedLocal else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(item.name)\"?"
        alert.informativeText = "This item will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(atPath: item.path)
            selectedLocalIDs.removeAll()
            refreshLocal()
        } catch {
            status = error.localizedDescription
        }
    }

    func deleteRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        if connection.requiresImportantServerGuards {
            guard confirmImportantServerAction(
                connection: connection,
                action: "permanently delete the remote item",
                remotePath: item.path,
                confirmation: "DELETE"
            ) else { return }
        } else {
            let alert = NSAlert()
            alert.messageText = "Delete \"\(item.name)\"?"
            alert.informativeText = "This remote item will be permanently deleted."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let credential = credentialForCurrentTab().clone()
        runBusy("Deleting remote item") {
            try await self.sftp.remove(connection: connection, credential: credential, path: item.path, isDirectory: item.isDirectory)
            await MainActor.run {
                self.selectedRemoteIDs.removeAll()
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: item.path, wasDirectory: item.isDirectory)
                self.refreshRemote()
            }
        }
    }

    func copyLocalPath() {
        guard let item = selectedLocal else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
        status = "Copied local path"
    }

    func copyRemotePath() {
        guard let item = selectedRemote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
        status = "Copied remote path"
    }

    func renameLocalSelected() {
        guard let item = selectedLocal else { return }
        let newName = prompt("Rename Local Item", defaultValue: item.name, actionTitle: "Rename")
        guard !newName.isEmpty, newName != item.name else { return }
        do {
            let destination = URL(fileURLWithPath: item.path).deletingLastPathComponent().appendingPathComponent(newName)
            try FileManager.default.moveItem(atPath: item.path, toPath: destination.path)
            selectedLocalIDs.removeAll()
            refreshLocal()
        } catch {
            status = error.localizedDescription
        }
    }

    func renameRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        let newName = prompt("Rename Remote Item", defaultValue: item.name, actionTitle: "Rename")
        guard !newName.isEmpty, newName != item.name else { return }
        let destination = remoteParentPath(item.path).map { joinRemote($0, newName) } ?? joinRemote(remotePath, newName)
        guard confirmImportantServerAction(
            connection: connection,
            action: "rename the remote item",
            remotePath: "\(item.path) -> \(destination)",
            confirmation: "RENAME"
        ) else { return }
        let credential = credentialForCurrentTab().clone()
        runBusy("Renaming remote item") {
            try await self.sftp.rename(connection: connection, credential: credential, from: item.path, to: destination)
            await MainActor.run {
                self.selectedRemoteIDs.removeAll()
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: item.path, wasDirectory: item.isDirectory)
                self.invalidateRemoteCacheForChangedItem(connectionID: connection.id, path: destination, wasDirectory: item.isDirectory)
                self.refreshRemote()
            }
        }
    }

    func editLocalSelected() {
        guard let item = selectedLocal, !item.isDirectory else { return }
        openFile(URL(fileURLWithPath: item.path), with: nil)
    }

    func openLocalSelectedWithApp() {
        guard let item = selectedLocal, !item.isDirectory else { return }
        let fileURL = URL(fileURLWithPath: item.path)
        guard let appURL = chooseApplication(for: fileURL) else { return }
        openFile(fileURL, with: appURL)
    }

    func editRemoteSelected() {
        editRemoteSelected(withApp: nil)
    }

    func openRemoteSelectedWithApp() {
        guard let item = selectedRemote, !item.isDirectory else { return }
        let previewURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(item.name)
        guard let appURL = chooseApplication(for: previewURL) else { return }
        editRemoteSelected(withApp: appURL)
    }

    private func editRemoteSelected(withApp appURL: URL?) {
        guard let item = selectedRemote, !item.isDirectory else { return }
        let directory: URL
        do {
            directory = try AppPaths.editDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            status = error.localizedDescription
            return
        }
        guard let localURL = safeLocalDestination(base: directory, name: item.name) else {
            try? FileManager.default.removeItem(at: directory)
            status = "Refused unsafe remote filename."
            return
        }
        let transferID = enqueue(direction: .edit, source: item.path, destination: localURL.path)
        downloadForEdit(remoteItem: item, localURL: localURL, appURL: appURL, transferID: transferID)
    }

    private func downloadForEdit(remoteItem: FileItem, localURL: URL, appURL: URL?, transferID: UUID) {
        guard let connection = selectedConnection else {
            try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
            return
        }
        let credential = credentialForCurrentTab().clone()
        guard let control = transferControls[transferID] else {
            try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
            return
        }
        runBusy("Downloading file for edit", transferID: transferID) {
            do {
                try await self.transferLimiter.withPermit {
                    guard !control.isCancelled else { throw AppError.commandFailed("Transfer cancelled.") }
                    await MainActor.run { self.markTransfer(transferID, .running, "") }
                    try await self.sftp.download(connection: connection, credential: credential, remotePath: remoteItem.path, localPath: localURL.path, policy: .createNew, control: control)
                }
            } catch {
                try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
                throw error
            }
            await MainActor.run {
                self.remoteEditSessions.insert(RemoteEditSession(remotePath: remoteItem.path, localPath: localURL.path, fileName: remoteItem.name), at: 0)
                self.markTransfer(transferID, .done, "Opened for edit")
                self.showsTransfers = true
                self.transferPanelTab = .remoteEdits
                self.status = "Editing \(remoteItem.name). Save in editor, then click Upload Edited."
                self.openFile(localURL, with: appURL)
            }
        }
    }

    private func openFile(_ fileURL: URL, with appURL: URL?) {
        WorkspaceFileOpener.open(fileURL, with: appURL) { [weak self] message in
            self?.status = message
        }
    }

    private func cleanupEditSessions(_ sessions: [RemoteEditSession]) {
        for session in sessions {
            let fileURL = URL(fileURLWithPath: session.localPath)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    private func confirmDiscardEditSessions(_ sessions: [RemoteEditSession], action: String) -> Bool {
        guard !sessions.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = sessions.count == 1 ? "Discard the open remote edit?" : "Discard \(sessions.count) open remote edits?"
        alert.informativeText = "To \(action), Volt must delete the local temporary copies. Upload any changes you want to keep first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard & Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func chooseApplication(for fileURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open With"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle, .unixExecutable]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runBusy(_ label: String, transferID: UUID? = nil, operation: @escaping @Sendable () async throws -> Void) {
        activeOperationCount += 1
        isBusy = true
        status = label
        Task {
            do {
                try await operation()
            } catch {
                if let transferID {
                    let wasCancelled = transferControls[transferID]?.isCancelled == true
                    markTransfer(
                        transferID,
                        wasCancelled ? .cancelled : .failed,
                        wasCancelled ? "Cancelled" : error.localizedDescription
                    )
                }
                status = error.localizedDescription
            }
            activeOperationCount = max(0, activeOperationCount - 1)
            isBusy = activeOperationCount > 0
        }
    }

    @discardableResult
    private func enqueue(direction: TransferDirection, source: String, destination: String) -> UUID {
        let job = TransferJob(direction: direction, source: source, destination: destination, state: .queued)
        let control = TransferControl { [weak self] transferred, total in
            Task { @MainActor [weak self] in
                self?.updateTransferProgress(job.id, transferred: transferred, total: total)
            }
        }
        transferControls[job.id] = control
        transfers.insert(job, at: 0)
        showsTransfers = true
        noteRecentActivity()
        return job.id
    }

    private func markTransfer(_ id: UUID, _ state: TransferState, _ message: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        transfers[index].message = message
        if state == .running && transfers[index].startedAt == nil {
            transfers[index].startedAt = Date()
        }
        if state == .done || state == .failed || state == .cancelled {
            transfers[index].updatedAt = Date()
        }
        if state == .done || state == .failed || state == .cancelled {
            transferControls.removeValue(forKey: id)
            lastTransferProgressUpdateByID.removeValue(forKey: id)
        }
    }

    private func updateTransferProgress(_ id: UUID, transferred: UInt64, total: UInt64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        let previousTransferred = transfers[index].transferredBytes
        let previousTotal = transfers[index].totalBytes
        guard previousTransferred != transferred || previousTotal != total else { return }

        let now = Date()
        let totalChanged = previousTotal != total
        let isComplete = total > 0 && transferred >= total
        if !totalChanged && !isComplete,
           let lastUpdate = lastTransferProgressUpdateByID[id],
           now.timeIntervalSince(lastUpdate) < transferProgressMinimumInterval {
            return
        }

        transfers[index].transferredBytes = transferred
        transfers[index].totalBytes = total
        transfers[index].updatedAt = now
        lastTransferProgressUpdateByID[id] = now
        if transferred > 0 && transfers[index].startedAt == nil {
            transfers[index].startedAt = now
        }
        if transferred > 0 && transfers[index].progressStartedAt == nil {
            transfers[index].progressStartedAt = now
        }
    }

    private func updateTransferDestination(_ id: UUID, _ destination: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].destination = destination
        transfers[index].updatedAt = Date()
    }

    func cancelTransfer(_ id: UUID) {
        guard let control = transferControls[id],
              let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].state == .queued || transfers[index].state == .running else { return }
        control.cancel()
        transfers[index].message = "Cancelling…"
    }

    func showTerminal() {
        showsTransfers = true
        transferPanelTab = .terminal
    }

    func startTerminal() {
        guard let selectedTabID else { return }
        guard let connection = selectedConnection else {
            status = "Choose a connection"
            return
        }
        if terminalSessions[selectedTabID]?.isRunning == true {
            showTerminal()
            return
        }
        terminalStatus = .connecting
        appendTerminalOutput("Connecting to \(connection.username)@\(connection.host):\(connection.port)...\n")
        syncCurrentTab()
        showTerminal()

        let tabID = selectedTabID
        Task {
            do {
                let probe = try await verifiedHostKeyProbe(for: connection)
                let knownHostsPath = try terminalKnownHostsPath(for: connection, probe: probe)
                await MainActor.run {
                    self.appendTerminalOutput("Using terminal known_hosts: \(knownHostsPath)\n", tabID: tabID)
                }
                let session = SSHTerminalSession()
                try session.start(
                    connection: connection,
                    knownHostsPath: knownHostsPath,
                    hostKeyAlgorithm: openSSHHostKeyAlgorithm(for: probe.keyType),
                    onOutput: { [weak self] text in
                        Task { @MainActor [weak self] in
                            self?.appendTerminalOutput(text, tabID: tabID)
                        }
                    },
                    onExit: { [weak self] code in
                        Task { @MainActor [weak self] in
                            self?.terminalDidExit(tabID: tabID, code: code)
                        }
                    }
                )
                await MainActor.run {
                    self.terminalSessions[tabID] = session
                    self.setTerminalStatus(.running, tabID: tabID)
                }
            } catch {
                await MainActor.run {
                    self.appendTerminalOutput("Terminal failed: \(error.localizedDescription)\n", tabID: tabID)
                    self.setTerminalStatus(.failed, tabID: tabID)
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func stopCurrentTerminal() {
        guard let selectedTabID else { return }
        stopTerminal(for: selectedTabID)
    }

    func clearTerminal() {
        terminalOutput = ""
        syncCurrentTab()
    }

    func sendTerminalInput(_ input: String) {
        guard let selectedTabID else { return }
        terminalSessions[selectedTabID]?.write(input)
    }

    func resizeTerminal(columns: Int, rows: Int) {
        guard let selectedTabID else { return }
        terminalSessions[selectedTabID]?.resize(columns: columns, rows: rows)
    }

    private func appendTerminalOutput(_ text: String, tabID: BrowserTab.ID? = nil) {
        let targetTabID = tabID ?? selectedTabID
        guard let targetTabID else { return }
        let limit = 80_000
        if targetTabID == selectedTabID {
            terminalOutput.append(text)
            if terminalOutput.count > limit {
                terminalOutput.removeFirst(terminalOutput.count - limit)
            }
            syncCurrentTab()
        } else if let index = tabs.firstIndex(where: { $0.id == targetTabID }) {
            tabs[index].terminalOutput.append(text)
            if tabs[index].terminalOutput.count > limit {
                tabs[index].terminalOutput.removeFirst(tabs[index].terminalOutput.count - limit)
            }
        }
    }

    private func setTerminalStatus(_ value: TerminalStatus, tabID: BrowserTab.ID? = nil) {
        let targetTabID = tabID ?? selectedTabID
        guard let targetTabID else { return }
        if targetTabID == selectedTabID {
            terminalStatus = value
            syncCurrentTab()
        } else if let index = tabs.firstIndex(where: { $0.id == targetTabID }) {
            tabs[index].terminalStatus = value
        }
    }

    private func terminalDidExit(tabID: BrowserTab.ID, code: Int32) {
        terminalSessions.removeValue(forKey: tabID)
        appendTerminalOutput("\nSSH session exited with status \(code).\n", tabID: tabID)
        setTerminalStatus(.exited, tabID: tabID)
    }

    private func stopTerminal(for tabID: BrowserTab.ID) {
        terminalSessions.removeValue(forKey: tabID)?.terminate()
        setTerminalStatus(.idle, tabID: tabID)
    }

    func prepareForTermination() {
        for control in transferControls.values { control.cancel() }
        for session in terminalSessions.values { session.terminate() }
        terminalSessions.removeAll()
        Task { await sftp.closeAllPooledSessions() }
        for credential in tabCredentials.values { credential.clear() }
        tabCredentials.removeAll()
        cleanupEditSessions(tabs.flatMap(\.remoteEditSessions) + remoteEditSessions)
        AppPaths.cleanupEditFiles(olderThan: 0)
    }

    private func prompt(_ title: String, defaultValue: String, actionTitle: String) -> String {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func confirmImportantServerAction(
        connection: SavedConnection,
        action: String,
        remotePath: String,
        confirmation: String
    ) -> Bool {
        guard connection.requiresImportantServerGuards else { return true }

        let alert = NSAlert()
        alert.messageText = "Confirm Important Server action"
        alert.informativeText = """
        You are about to \(action).

        \(remoteActionContext(connection: connection, remotePath: remotePath))

        Type \(confirmation) to continue.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = confirmation
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn,
              input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == confirmation
        else {
            status = "Important Server action cancelled"
            return false
        }
        return true
    }

    private func confirmImportantServerPasswordUse(connection: SavedConnection) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use password authentication for Important Server?"
        alert.informativeText = """
        \(remoteActionContext(connection: connection, remotePath: connection.remotePath))

        SSH key or ssh-agent authentication is recommended for long-lived server access. Password SFTP is allowed, but keep this connection limited and verify the host key fingerprint out of band.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func remoteActionContext(connection: SavedConnection, remotePath: String) -> String {
        "Server: \(connection.username)@\(connection.host):\(connection.port)\nRemote path: \(remotePath)"
    }

    private func remoteParentPath(_ path: String) -> String? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func loadConnections() {
        connections = SecureStorage.load()
    }

    private func loadStartupStorage() {
        Task {
            let loadedConnections = await Task.detached(priority: .utility) {
                AppPaths.migrateFromSandboxContainerIfNeeded()
                SecureStorage.migrateFromUserDefaults()
                AppPaths.cleanupEditFiles(olderThan: 0)
                return SecureStorage.load()
            }.value
            connections = loadedConnections
        }
    }

    private func saveConnections() {
        SecureStorage.save(connections)
    }

    private func noteRecentActivity() {
        if recentsCleared {
            recentsCleared = false
        }
    }

    private static func needsLocalOwnerGroupPermissions(for preferences: FileBrowserPreferences) -> Bool {
        preferences.visibleColumns.contains { column in
            column == .owner || column == .group || column == .permissions
        } || preferences.sortField == .owner
            || preferences.sortField == .group
            || preferences.sortField == .permissions
    }

    private func hostKeyVerificationKey(for connection: SavedConnection) -> String {
        let host = connection.host
        let port = connection.port
        let lookupHost = port == 22 ? host : "[\(host)]:\(port)"
        return "\(connection.id.uuidString):\(lookupHost)"
    }

    private func hostKeyScopeChanged(from oldConnection: SavedConnection, to newConnection: SavedConnection) -> Bool {
        oldConnection.host != newConnection.host || oldConnection.port != newConnection.port
    }

    private func shouldPromptForPassword(_ connection: SavedConnection) -> Bool {
        connection.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func validate(_ connection: SavedConnection) -> String? {
        let host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty || host.hasPrefix("-") || host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) {
            return "Enter a valid SSH host."
        }
        if username.isEmpty || username.hasPrefix("-") || username.contains("@") || username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) {
            return "Enter a valid SSH username."
        }
        if !(1...65_535).contains(connection.port) {
            return "SSH port must be between 1 and 65535."
        }
        if connection.requiresImportantServerGuards,
           username == "root",
           !connection.allowRootLoginOnImportantServer {
            return "Important Server blocks root login unless the explicit root override is enabled."
        }
        return nil
    }

    private func shouldWarnAboutImportantServerPassword(_ connection: SavedConnection, password: String) -> Bool {
        connection.requiresImportantServerGuards
            && connection.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .newlines).isEmpty
    }

    private func credentialForCurrentTab() -> SensitiveCredential {
        guard let selectedTabID else { return SensitiveCredential() }
        if let credential = tabCredentials[selectedTabID] { return credential }
        let credential = SensitiveCredential()
        tabCredentials[selectedTabID] = credential
        return credential
    }

    private func capturePasswordInput(_ password: String) {
        let sanitized = password.trimmingCharacters(in: .newlines)
        credentialForCurrentTab().replace(with: sanitized)
    }

    private func tabIDForConnection(_ id: UUID) -> BrowserTab.ID? {
        tabs.first { $0.connectionID == id && $0.isConnected }?.id
            ?? tabs.first { $0.connectionID == id }?.id
    }

    private func selectOrCreateTab(for connection: SavedConnection) {
        syncCurrentTab()

        if let tabID = tabIDForConnection(connection.id) {
            if selectedTabID != tabID {
                selectTab(tabID)
            }
            return
        }

        guard let selectedConnectionID,
              selectedConnectionID != connection.id,
              isConnected
        else {
            return
        }

        var tab = BrowserTab()
        tab.title = connection.name
        tab.localPath = localPath
        tab.localItems = localItems
        tabs.append(tab)
        tabCredentials[tab.id] = SensitiveCredential()
        selectTab(tab.id)
    }

    private func resetConnectionState(forTabAt index: Int) {
        tabs[index].connectionID = nil
        tabs[index].connectionDraft = SavedConnection()
        tabs[index].remotePath = "/"
        tabs[index].remoteItems = []
        tabs[index].selectedRemoteIDs = []
        tabs[index].remoteEditSessions = []
        tabs[index].terminalOutput = ""
        tabs[index].terminalStatus = .idle
        tabs[index].isConnected = false
        tabs[index].showsConnectionEditor = false
        tabs[index].title = tabTitle(forLocalPath: tabs[index].localPath)
    }

    private func tabTitle(forLocalPath path: String) -> String {
        let title = URL(fileURLWithPath: path).lastPathComponent
        return title.isEmpty ? "Local" : title
    }

    nonisolated private func isAuthenticationFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("authentication failed") || message.contains("password authentication") || message.contains("private key authentication")
    }

    private func currentSessionTab(title: String) -> BrowserTab {
        BrowserTab(
            title: title,
            connectionID: selectedConnectionID,
            connectionDraft: connectionDraft,
            localPath: localPath,
            remotePath: remotePath,
            localItems: localItems,
            remoteItems: remoteItems,
            selectedLocalIDs: selectedLocalIDs,
            selectedRemoteIDs: selectedRemoteIDs,
            remoteEditSessions: remoteEditSessions,
            terminalOutput: "",
            terminalStatus: .idle,
            isConnected: isConnected,
            showsConnectionEditor: showsConnectionEditor,
            showsInspector: showsInspector
        )
    }

    private func remoteCacheKey(connectionID: UUID, path: String) -> String {
        "\(connectionID.uuidString):\(path)"
    }

    private func cachedRemoteItems(connectionID: UUID, path: String) -> [FileItem]? {
        remoteDirectoryCache[remoteCacheKey(connectionID: connectionID, path: path)]?.items
    }

    private func storeRemoteListing(_ items: [FileItem], connectionID: UUID, path: String) {
        remoteDirectoryCache[remoteCacheKey(connectionID: connectionID, path: path)] = RemoteDirectoryCacheEntry(items: items, loadedAt: Date())
        pruneRemoteDirectoryCache(maxEntries: 200)
    }

    private func invalidateRemoteCache(connectionID: UUID, path: String) {
        remoteDirectoryCache.removeValue(forKey: remoteCacheKey(connectionID: connectionID, path: path))
    }

    private func invalidateRemoteCacheForChangedItem(connectionID: UUID, path: String, wasDirectory: Bool = false) {
        if let parent = remoteParentPath(path) {
            invalidateRemoteCache(connectionID: connectionID, path: parent)
        }
        if wasDirectory {
            invalidateRemoteCache(connectionID: connectionID, path: path)
        }
    }

    private func pruneRemoteDirectoryCache(maxEntries: Int) {
        guard remoteDirectoryCache.count > maxEntries else { return }
        let overflow = remoteDirectoryCache.count - maxEntries
        let staleKeys = remoteDirectoryCache
            .sorted { $0.value.loadedAt < $1.value.loadedAt }
            .prefix(overflow)
            .map(\.key)
        for key in staleKeys {
            remoteDirectoryCache.removeValue(forKey: key)
        }
    }

    private func syncCurrentTab() {
        guard !isRestoringTab, let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs[index].connectionID = selectedConnectionID
        tabs[index].connectionDraft = connectionDraft
        tabs[index].localPath = localPath
        tabs[index].remotePath = remotePath
        tabs[index].localItems = localItems
        tabs[index].remoteItems = remoteItems
        tabs[index].selectedLocalIDs = selectedLocalIDs
        tabs[index].selectedRemoteIDs = selectedRemoteIDs
        tabs[index].remoteEditSessions = remoteEditSessions
        tabs[index].terminalOutput = terminalOutput
        tabs[index].terminalStatus = terminalStatus
        tabs[index].isConnected = isConnected
        tabs[index].showsConnectionEditor = showsConnectionEditor
        tabs[index].showsInspector = showsInspector
        if let connection = selectedConnection {
            tabs[index].title = connection.name
        } else {
            tabs[index].title = tabTitle(forLocalPath: localPath)
        }
    }

    private func restoreCurrentTab() {
        guard let tab = selectedTab else { return }
        isRestoringTab = true
        isSuppressingSidebarSelection = true
        selectedConnectionID = tab.connectionID
        connectionDraft = tab.connectionDraft
        localPath = tab.localPath
        remotePath = tab.remotePath
        localItems = tab.localItems
        remoteItems = tab.remoteItems
        selectedLocalIDs = tab.selectedLocalIDs
        selectedRemoteIDs = tab.selectedRemoteIDs
        remoteEditSessions = tab.remoteEditSessions
        terminalOutput = tab.terminalOutput
        terminalStatus = tab.terminalStatus
        isConnected = tab.isConnected
        showsConnectionEditor = tab.showsConnectionEditor
        showsInspector = tab.showsInspector
        showsPasswordPrompt = false
        isRestoringTab = false
        Task { @MainActor in
            self.isSuppressingSidebarSelection = false
        }

        if localItems.isEmpty {
            refreshLocal()
        }
    }

    private func joinRemote(_ base: String, _ child: String) -> String {
        if base == "/" { return "/" + child }
        return "/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + child
    }

    // MARK: - Host Key Verification

    private func verifyHostKey(for connection: SavedConnection) async throws {
        _ = try await verifiedHostKeyProbe(for: connection)
    }

    private func verifiedHostKeyProbe(for connection: SavedConnection) async throws -> HostKeyProbe {
        let host = connection.host
        let port = connection.port
        let lookupHost = port == 22 ? host : "[\(host)]:\(port)"
        let verificationKey = hostKeyVerificationKey(for: connection)

        if let cachedProbe = verifiedHostProbes[verificationKey] {
            return cachedProbe
        }

        let probe = try await sftp.probeHostKey(connection: connection)
        if probe.trustStatus == VOLT_HOSTKEY_MATCH {
            verifiedHostProbes[verificationKey] = probe
            return probe
        }
        if probe.trustStatus == VOLT_HOSTKEY_MISMATCH {
            throw AppError.commandFailed("Host key for \(lookupHost) changed. The connection was rejected.")
        }

        let digest = SHA256.hash(data: probe.key)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")

        let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pendingHostKeyFingerprint = fingerprint
            self.pendingHostKeyHost = lookupHost
            self.hostKeyConfirmationContinuation = continuation
            self.showsHostKeyPrompt = true
        }

        guard confirmed else {
            throw AppError.hostKeyRejected
        }
        try await sftp.commitHostKey(connection: connection, probe: probe)
        verifiedHostProbes[verificationKey] = probe
        return probe
    }

    private func openSSHHostKeyAlgorithm(for keyType: Int32) -> String? {
        guard let algorithm = volt_ssh_openssh_host_key_algorithm(keyType) else { return nil }
        return String(cString: algorithm)
    }

    private func terminalKnownHostsPath(for connection: SavedConnection, probe: HostKeyProbe) throws -> String {
        guard let keyTypePointer = volt_ssh_openssh_known_host_key_type(probe.keyType) else {
            throw AppError.commandFailed("Unsupported SSH host key type.")
        }
        let keyType = String(cString: keyTypePointer)
        let hostField = connection.port == 22 ? connection.host : "[\(connection.host)]:\(connection.port)"
        let line = "\(hostField) \(keyType) \(probe.key.base64EncodedString())\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoltTerminalKnownHosts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("\(connection.id.uuidString)-\(connection.port).known_hosts", isDirectory: false)
        try Data(line.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    func confirmHostKey() {
        showsHostKeyPrompt = false
        hostKeyConfirmationContinuation?.resume(returning: true)
        hostKeyConfirmationContinuation = nil
    }

    func rejectHostKey() {
        showsHostKeyPrompt = false
        hostKeyConfirmationContinuation?.resume(returning: false)
        hostKeyConfirmationContinuation = nil
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showsSidebar = true
    @State private var searchText = ""
    @AppStorage("Volt.AppAppearance") private var appAppearanceRawValue = AppAppearance.light.rawValue

    private var appAppearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appAppearanceRawValue) ?? .light },
            set: { appAppearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = AppLayoutContext.make(
                width: proxy.size.width,
                inspectorOpen: model.showsInspector,
                remoteConnected: model.isConnected,
                queueExpanded: model.showsTransfers,
                sidebarVisible: showsSidebar
            )

            MainLayoutView(
                model: model,
                layout: layout,
                showsSidebar: $showsSidebar,
                searchText: $searchText,
                appAppearance: appAppearance
            )
        }
        .background(VoltTheme.appBackground)
        .preferredColorScheme(appAppearance.wrappedValue.colorScheme)
        // Cho noi dung tran len vung titlebar de topBar va traffic lights chung mot hang
        // (khong bi day xuong thanh 2 dong).
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator(appAppearance: appAppearance.wrappedValue))
        .sheet(isPresented: $model.showsConnectionEditor) {
            ConnectionEditor(model: model)
                .padding(4)
                .frame(width: 820)
                .presentationSizing(.fitted)
        }
        .sheet(isPresented: $model.showsPasswordPrompt) {
            PasswordPromptView(model: model)
        }
        .sheet(isPresented: $model.showsHostKeyPrompt) {
            HostKeyVerificationView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.prepareForTermination()
        }
        .frame(minWidth: 760, minHeight: 640)
    }
}

private struct MainLayoutView: View {
    @ObservedObject var model: AppModel
    var layout: AppLayoutContext
    @Binding var showsSidebar: Bool
    @Binding var searchText: String
    @Binding var appAppearance: AppAppearance
    @State private var activeBrowserPane: ActiveBrowserPane = .local

    var body: some View {
        HStack(spacing: 0) {
            if layout.sidebarMode != .hidden {
                VStack(spacing: 0) {
                    SidebarBrandHeader(layout: layout)
                        .frame(height: 48)
                    SidebarView(model: model, layout: layout)
                }
                .frame(width: layout.sidebarWidth)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(VoltTheme.hairline)
                        .frame(width: 1)
                }
            }

            VStack(spacing: 0) {
                VoltTopToolbar(
                    model: model,
                    layout: layout,
                    showsSidebar: $showsSidebar,
                    searchText: $searchText,
                    appAppearance: $appAppearance
                )

                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        mainContent

                        if layout.inspectorMode == .docked {
                            Divider()
                            InspectorView(model: model)
                                .frame(width: layout.inspectorWidth)
                        }
                    }

                    if layout.inspectorMode == .overlay {
                        InspectorOverlay(model: model, width: layout.inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    #if DEBUG
                    LayoutDebugBadge(layout: layout)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VoltTheme.appBackground)
        .overlay(alignment: .topLeading) {
            TrafficLightControls()
                .padding(.leading, VoltWindowChrome.trafficLightLeadingPadding)
                .frame(height: VoltWindowChrome.toolbarHeight, alignment: .center)
        }
        .sheet(isPresented: inspectorSheetBinding) {
            InspectorView(model: model)
                .frame(width: layout.inspectorWidth, height: 560)
        }
        .animation(.easeInOut(duration: 0.16), value: layout.inspectorMode)
        .animation(.easeInOut(duration: 0.16), value: layout.sidebarMode)
        .onChange(of: layout.browserMode) { _, mode in
            if mode == .singlePane, activeBrowserPane == .remote, !model.isConnected {
                activeBrowserPane = .local
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if model.tabs.count > 1 {
                SessionTabBar(model: model)
                    .frame(height: 34)
                    .background(VoltTheme.toolbarBackground)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(VoltTheme.hairline)
                            .frame(height: 1)
                    }
            }
            BrowserSplitView(
                model: model,
                layout: layout,
                activePane: $activeBrowserPane,
                searchText: searchText
            )
            TransferQueueView(model: model, layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspectorSheetBinding: Binding<Bool> {
        Binding(
            get: { model.showsInspector && layout.inspectorMode == .sheet },
            set: { isPresented in
                if !isPresented {
                    model.showsInspector = false
                }
            }
        )
    }
}

private struct TrafficLightControls: View {
    var body: some View {
        HStack(spacing: 10) {
            trafficButton(color: Color(red: 1.0, green: 0.35, blue: 0.31), action: {
                NSApp.keyWindow?.performClose(nil)
            })
            trafficButton(color: Color(red: 1.0, green: 0.73, blue: 0.20), action: {
                NSApp.keyWindow?.miniaturize(nil)
            })
            trafficButton(color: Color(red: 0.21, green: 0.80, blue: 0.31), action: {
                NSApp.keyWindow?.zoom(nil)
            })
        }
    }

    private func trafficButton(color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

private struct InspectorOverlay: View {
    @ObservedObject var model: AppModel
    var width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.showsInspector = false
            } label: {
                Color.black.opacity(0.001)
            }
            .buttonStyle(.plain)

            InspectorView(model: model)
                .frame(width: width)
                .background(VoltTheme.appBackground)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(VoltTheme.hairline)
                        .frame(width: 1)
                }
        }
    }
}

#if DEBUG
private struct LayoutDebugBadge: View {
    var layout: AppLayoutContext

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("mode: \(String(describing: layout.mode))")
            Text("dualPane: \(layout.isDualPane ? "true" : "false")")
            Text("inspector: \(String(describing: layout.inspectorMode))")
            Text("sidebar: \(String(describing: layout.sidebarMode))")
            Text("width: \(Int(layout.width))")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif

private struct WindowConfigurator: NSViewRepresentable {
    var appAppearance: AppAppearance
    private let topBarHeight: CGFloat = 48
    private let trafficLightLeftPadding: CGFloat = 20
    private let trafficLightSpacing: CGFloat = 26

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: appAppearance.nsAppearanceName)
        setNativeTrafficLights(hidden: true, in: window)
        DispatchQueue.main.async {
            positionTrafficLights(in: window)
        }
    }

    private func setNativeTrafficLights(hidden: Bool, in window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func positionTrafficLights(in window: NSWindow) {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        guard let closeButton = buttons.first, let superview = closeButton.superview else { return }

        let y: CGFloat
        if superview.bounds.height > topBarHeight {
            y = superview.bounds.height - topBarHeight + (topBarHeight - closeButton.frame.height) / 2
        } else {
            y = (superview.bounds.height - closeButton.frame.height) / 2
        }

        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(
                x: trafficLightLeftPadding + CGFloat(index) * trafficLightSpacing,
                y: y.rounded(.down)
            ))
        }
    }
}

struct SessionTabBar: View {
    @ObservedObject var model: AppModel
    private let tabWidth: CGFloat = 190
    private let barHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        let isActive = tab.id == model.selectedTabID
                        if index > 0 {
                            Rectangle()
                                .fill(VoltTheme.hairline)
                                .frame(width: 1, height: barHeight)
                        }
                        Button {
                            model.selectTab(tab.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.isConnected ? "bolt.horizontal.fill" : "folder")
                                    .foregroundStyle(tab.isConnected ? Color.accentColor : VoltTheme.mutedText)
                                Text(tab.title)
                                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if model.tabs.count > 1 {
                                    TabCloseButton {
                                        model.closeTab(tab.id)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(width: tabWidth)
                            .frame(height: barHeight)
                            .background(isActive ? VoltTheme.selectedFill : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("New Tab") { model.newTab() }
                            Button("Close Tab") { model.closeTab(tab.id) }
                                .disabled(model.tabs.count <= 1)
                            Button("Close Other Tabs") { model.closeOtherTabs(keeping: tab.id) }
                                .disabled(model.tabs.count <= 1)
                            Divider()
                            Button("Duplicate Tab") { model.duplicateTab(tab.id) }
                        }
                        .id(tab.id)
                        .onAppear {
                            // Tab vua tao chi cuon khi that su tran khoi vung nhin. onAppear chay SAU
                            // layout nen contentSize da du -> scrollTo dat dung, khong bi hut.
                            if tab.id == model.selectedTabID {
                                proxy.scrollTo(tab.id, anchor: .trailing)
                            }
                        }
                    }
                }
                .frame(height: barHeight)
            }
            .frame(height: barHeight)
            // Chon mot tab dang khuat -> cuon tab do vao tam nhin.
            .onChange(of: model.selectedTabID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .trailing)
                }
            }
            }
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(width: 1, height: barHeight)
            Button(action: model.newTab) {
                Image(systemName: "plus")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("New tab")
        }
        .frame(height: barHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Nut dong tab: hien nen bo tron khi ro chuot vao de user biet dang tro dung nut close.
private struct TabCloseButton: View {
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.caption)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.primary.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture(perform: action)
    }
}

struct HostKeyVerificationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Unknown Host Key")
                .font(.headline)

            Text("The host \(model.pendingHostKeyHost) presented an unrecognized key fingerprint.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            GroupBox {
                ScrollView {
                    Text(model.pendingHostKeyFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 60)
            }
            .frame(width: 380)

            Text("Verify this fingerprint matches the server's key before accepting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Reject") {
                    model.rejectHostKey()
                }
                .keyboardShortcut(.cancelAction)

                Button("Accept & Connect") {
                    model.confirmHostKey()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

@MainActor
final class SecurePasswordFieldController: ObservableObject {
    fileprivate weak var textField: NSSecureTextField?
    fileprivate var onSubmit: ((String) -> Void)?

    func submit() {
        guard let textField else {
            onSubmit?("")
            return
        }
        let password = textField.stringValue
        textField.stringValue = ""
        onSubmit?(password)
    }

    func clear() {
        textField?.stringValue = ""
    }
}

private struct SecurePasswordField: NSViewRepresentable {
    @ObservedObject var controller: SecurePasswordFieldController
    var placeholder: String
    var onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let textField = NSSecureTextField(frame: .zero)
        textField.placeholderString = placeholder
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        controller.textField = textField
        controller.onSubmit = onSubmit
        return textField
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        nsView.placeholderString = placeholder
        nsView.target = context.coordinator
        nsView.action = #selector(Coordinator.submit)
        controller.textField = nsView
        controller.onSubmit = onSubmit
    }

    static func dismantleNSView(_ nsView: NSSecureTextField, coordinator: Coordinator) {
        nsView.stringValue = ""
        if coordinator.controller.textField === nsView {
            coordinator.controller.textField = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate let controller: SecurePasswordFieldController

        init(controller: SecurePasswordFieldController) {
            self.controller = controller
        }

        @objc func submit() {
            controller.submit()
        }
    }
}

struct ConnectionEditor: View {
    @ObservedObject var model: AppModel
    @StateObject private var passwordController = SecurePasswordFieldController()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                TextField("Name", text: $model.connectionDraft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 90, idealWidth: 190)
                TextField("Host", text: $model.connectionDraft.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 90, idealWidth: 190)
                TextField("User", text: $model.connectionDraft.username)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 90, idealWidth: 190)
                TextField("Port", value: $model.connectionDraft.port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Picker("Protocol", selection: $model.connectionDraft.protocolKind) {
                    ForEach(ProtocolKind.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 100, idealWidth: 160, maxWidth: 180)
                Button(action: passwordController.submit) { Label("Connect", systemImage: "bolt.horizontal") }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .disabled(model.connectionDraft.host.isEmpty)
                Button {
                    passwordController.clear()
                    model.saveDraft()
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                Button {
                    passwordController.clear()
                    model.hideConnectionEditor()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }

            HStack(spacing: 12) {
                SecurePasswordField(
                    controller: passwordController,
                    placeholder: "Password or key passphrase (not saved)"
                ) { password in
                    model.connectDraft(password: password)
                }
                    .frame(minWidth: 150, maxWidth: .infinity)
                HStack(spacing: 6) {
                    TextField("Private key", text: $model.connectionDraft.privateKeyPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button(action: model.choosePrivateKey) {
                        Image(systemName: "key.horizontal")
                    }
                    .help("Choose SSH private key")
                }
                .frame(minWidth: 200, maxWidth: .infinity)
                TextField("Remote start path", text: $model.connectionDraft.remotePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 260, maxWidth: 320)
            }

            HStack(spacing: 12) {
                Text("Remote permissions")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 120, alignment: .leading)
                Picker(
                    "Remote permissions",
                    selection: Binding(
                        get: { model.connectionDraft.effectivePermissionPreset },
                        set: { model.connectionDraft.permissionPreset = $0 }
                    )
                ) {
                    ForEach(RemotePermissionPreset.allCases) { preset in
                        Text("\(preset.rawValue)  \(String(format: "%03o", preset.fileMode))/\(String(format: "%03o", preset.folderMode))")
                            .tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Text("Safety")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 120, alignment: .leading)
                Picker("Safety", selection: $model.connectionDraft.safetyProfile) {
                    ForEach(ConnectionSafetyProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                if model.connectionDraft.requiresImportantServerGuards {
                    Toggle("Allow root login", isOn: $model.connectionDraft.allowRootLoginOnImportantServer)
                        .toggleStyle(.checkbox)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .onDisappear {
            passwordController.clear()
        }
    }
}

struct PasswordPromptView: View {
    @ObservedObject var model: AppModel
    @StateObject private var passwordController = SecurePasswordFieldController()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to \(model.connectionDraft.name)")
                .font(.headline)
            Text("Enter the server password. Volt keeps it only in this tab's memory and never saves it to Keychain or UserDefaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.connectionDraft.requiresImportantServerGuards,
               model.connectionDraft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Important Server: SSH key or ssh-agent authentication is recommended.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecurePasswordField(controller: passwordController, placeholder: "Password") { password in
                model.connectWithPassword(password)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    passwordController.clear()
                    model.cancelPasswordPrompt()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    passwordController.submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear {
            passwordController.clear()
        }
    }
}

struct ConnectionSummaryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isConnected ? "checkmark.circle.fill" : "bolt.horizontal")
                .foregroundStyle(model.isConnected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedConnection?.name ?? "Connected")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: model.showConnectionEditor) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button(action: model.refreshRemote) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                model.disconnectConnection()
            } label: {
                Label("Disconnect", systemImage: "power")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        guard let connection = model.selectedConnection else { return "No connection" }
        return "\(connection.username)@\(connection.host):\(connection.port)  \(model.remotePath)"
    }
}

struct BrowserSplitView: View {
    @ObservedObject var model: AppModel
    var layout: AppLayoutContext
    @Binding var activePane: ActiveBrowserPane
    var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            if layout.browserMode == .singlePane {
                browserPaneSwitcher
            }

            HStack(spacing: 0) {
                if layout.browserMode == .dualPane {
                    localPane
                        .frame(maxWidth: .infinity)
                    Divider()
                    if model.isConnected {
                        remotePane
                            .frame(maxWidth: .infinity)
                    } else {
                        disconnectedRemotePane
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    activeSinglePane
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VoltTheme.paneBackground)
    }

    private var browserPaneSwitcher: some View {
        HStack(spacing: 10) {
            Picker("Pane", selection: $activePane) {
                ForEach(ActiveBrowserPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            if !model.isConnected {
                Text("Remote is not connected")
                    .font(.caption)
                    .foregroundStyle(VoltTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer()

            if activePane == .remote && !model.isConnected {
                Button {
                    model.showConnectionEditor()
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(VoltTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(height: 1)
        }
    }

    @ViewBuilder private var activeSinglePane: some View {
        switch activePane {
        case .local:
            localPane
        case .remote:
            if model.isConnected {
                remotePane
            } else {
                disconnectedRemotePane
            }
        }
    }

    private var localActionsMenu: some View {
        Menu {
            Button("Upload Selected", action: model.uploadSelected)
                .disabled(model.selectedLocalItems.isEmpty || model.selectedConnection == nil)
            Divider()
            Button("Choose Folder...", action: model.chooseLocalFolder)
            Divider()
            Button("New Folder", action: model.makeLocalFolder)
            Button("New File", action: model.makeLocalFile)
            Divider()
            Button("Get Info", action: model.getInfoLocalSelected)
                .disabled(model.selectedLocal == nil)
            Button("Copy Path", action: model.copyLocalPath)
                .disabled(model.selectedLocal == nil)
            Divider()
            Button("Edit File", action: model.editLocalSelected)
                .disabled(model.selectedLocalItems.count != 1 || model.selectedLocal?.isDirectory != false)
            Button("Open With...", action: model.openLocalSelectedWithApp)
                .disabled(model.selectedLocalItems.count != 1 || model.selectedLocal?.isDirectory != false)
            Divider()
            Button("Rename", action: model.renameLocalSelected)
                .disabled(model.selectedLocalItems.count != 1)
            Button("Duplicate", action: model.duplicateLocalSelected)
                .disabled(model.selectedLocalItems.count != 1)
            Button("Move...", action: model.moveLocalSelected)
                .disabled(model.selectedLocalItems.count != 1)
            Button("Delete", action: model.deleteLocalSelected)
                .disabled(model.selectedLocalItems.isEmpty)
        } label: {
            PaneToolbarMenuLabel(systemImage: "ellipsis.circle")
        }
        .help("More local actions")
    }

    private var remoteActionsMenu: some View {
        Menu {
            Button("Upload Files or Folders...", action: model.uploadFromPicker)
                .disabled(model.selectedConnection == nil)
            Button("Open SSH Terminal", action: model.showTerminal)
                .disabled(model.selectedConnection == nil)
            Divider()
            Button("Download Selected", action: model.downloadSelected)
                .disabled(model.selectedRemoteItems.isEmpty)
            Button("Download To...", action: model.downloadSelectedToFolder)
                .disabled(model.selectedRemoteItems.isEmpty)
            Divider()
            Button("New Folder", action: model.makeRemoteFolder)
                .disabled(model.selectedConnection == nil)
            Button("New File", action: model.makeRemoteFile)
                .disabled(model.selectedConnection == nil)
            Divider()
            Button("Get Info", action: model.getInfoRemoteSelected)
                .disabled(model.selectedRemote == nil)
            Button("Copy Path", action: model.copyRemotePath)
                .disabled(model.selectedRemote == nil)
            Divider()
            Button("Edit Remote File", action: model.editRemoteSelected)
                .disabled(model.selectedRemoteItems.count != 1 || model.selectedRemote?.isDirectory != false)
            Button("Open With...", action: model.openRemoteSelectedWithApp)
                .disabled(model.selectedRemoteItems.count != 1 || model.selectedRemote?.isDirectory != false)
            Divider()
            Button("Rename", action: model.renameRemoteSelected)
                .disabled(model.selectedRemoteItems.count != 1)
            Button("Duplicate", action: model.duplicateRemoteSelected)
                .disabled(model.selectedRemoteItems.count != 1)
            Button("Move...", action: model.moveRemoteSelected)
                .disabled(model.selectedRemoteItems.count != 1)
            Button("Delete", action: model.deleteRemoteSelected)
                .disabled(model.selectedRemoteItems.isEmpty)
        } label: {
            PaneToolbarMenuLabel(systemImage: "ellipsis.circle")
        }
        .help("More remote actions")
    }

    private var disconnectedRemotePane: some View {
        VStack(spacing: 0) {
            disconnectedRemoteHeader
            Divider()

            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Text("Choose or add a server")
                    .font(.headline)
                Text("Remote files will appear here after connecting.")
                    .font(.subheadline)
                    .foregroundStyle(VoltTheme.mutedText)
                Button {
                    model.showConnectionEditor()
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 300)
        .background(VoltTheme.paneBackground)
    }

    private var disconnectedRemoteHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text("/")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("remote")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(VoltTheme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(VoltTheme.hairline)
            )

            Spacer()
            Text("Not connected")
                .font(.caption)
                .foregroundStyle(VoltTheme.mutedText)
            Button {
                model.showConnectionEditor()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var localPane: some View {
            FilePane(
                title: "Local",
                path: $model.localPath,
                submitPath: model.submitLocalPath,
                items: model.localItems,
                selection: $model.selectedLocalIDs,
                preferences: $model.localBrowserPreferences,
                isRemote: false,
                searchText: searchText,
                toolbar: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            PaneToolbarIconButton(systemImage: "arrow.up", help: "Parent folder", action: model.localUp)
                            PaneToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh", action: model.refreshLocal)
                            PaneToolbarIconButton(systemImage: "square.and.arrow.up", help: "Upload selected", action: model.uploadSelected)
                                .disabled(model.selectedLocalItems.isEmpty || model.selectedConnection == nil)
                            localActionsMenu
                        }
                        HStack(spacing: 4) {
                            PaneToolbarIconButton(systemImage: "arrow.up", help: "Parent folder", action: model.localUp)
                            PaneToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh", action: model.refreshLocal)
                            localActionsMenu
                        }
                    }
                },
                open: model.openLocal,
                contextMenu: { item in
                    let name = item.name
                    let isContextSelection = model.selectedLocalIDs.contains(item.id) && model.selectedLocalIDs.count > 1
                    Button(isContextSelection ? "Upload Selected (\(model.selectedLocalIDs.count))" : "Upload \"\(name)\"") {
                        if !model.selectedLocalIDs.contains(item.id) {
                            model.selectedLocalIDs = [item.id]
                        }
                        model.uploadSelected()
                    }
                    .disabled(model.selectedConnection == nil)
                    Button("Get Info") {
                        model.selectedLocalIDs = [item.id]
                        model.getInfoLocalSelected()
                    }
                    Divider()
                    Button("Open") {
                        model.selectedLocalIDs = [item.id]
                        model.editLocalSelected()
                    }
                    .disabled(item.isDirectory)
                    Button("Open With...") {
                        model.selectedLocalIDs = [item.id]
                        model.openLocalSelectedWithApp()
                    }
                    .disabled(item.isDirectory)
                    Button("Copy Path") {
                        model.selectedLocalIDs = [item.id]
                        model.copyLocalPath()
                    }
                    Divider()
                    Button("Delete...") {
                        model.selectedLocalIDs = [item.id]
                        model.deleteLocalSelected()
                    }
                    Button("Move...") {
                        model.selectedLocalIDs = [item.id]
                        model.moveLocalSelected()
                    }
                    Button("Duplicate") {
                        model.selectedLocalIDs = [item.id]
                        model.duplicateLocalSelected()
                    }
                    Button("Rename") {
                        model.selectedLocalIDs = [item.id]
                        model.renameLocalSelected()
                    }
                    Divider()
                    Button("New Folder") { model.makeLocalFolder() }
                    Button("New File") { model.makeLocalFile() }
                    Button("Refresh") { model.refreshLocal() }
                    if item.isDirectory {
                        Divider()
                        Button("Open in New Tab") {
                            model.selectedLocalIDs = [item.id]
                            model.openInNewTabLocal()
                        }
                    }
                },
                backgroundContextMenu: {
                    Button("New Folder", action: model.makeLocalFolder)
                    Button("New File", action: model.makeLocalFile)
                    Button("Refresh", action: model.refreshLocal)
                }
            )
    }

    private var remotePane: some View {
            FilePane(
                title: "Remote",
                path: $model.remotePath,
                submitPath: model.submitRemotePath,
                items: model.remoteItems,
                selection: $model.selectedRemoteIDs,
                preferences: $model.remoteBrowserPreferences,
                isRemote: true,
                searchText: searchText,
                toolbar: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            PaneToolbarIconButton(systemImage: "arrow.up", help: "Parent folder", action: model.remoteUp)
                            PaneToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh", action: model.refreshRemote)
                            PaneToolbarIconButton(systemImage: "square.and.arrow.down", help: "Download selected", action: model.downloadSelected)
                                .disabled(model.selectedRemoteItems.isEmpty)
                            remoteActionsMenu
                        }
                        HStack(spacing: 4) {
                            PaneToolbarIconButton(systemImage: "arrow.up", help: "Parent folder", action: model.remoteUp)
                            PaneToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh", action: model.refreshRemote)
                            remoteActionsMenu
                        }
                    }
                },
                open: model.openRemote,
                contextMenu: { item in
                    let name = item.name
                    let isContextSelection = model.selectedRemoteIDs.contains(item.id) && model.selectedRemoteIDs.count > 1
                    Button(isContextSelection ? "Download Selected (\(model.selectedRemoteIDs.count))" : "Download \"\(name)\"") {
                        if !model.selectedRemoteIDs.contains(item.id) {
                            model.selectedRemoteIDs = [item.id]
                        }
                        model.downloadSelected()
                    }
                    Button(isContextSelection ? "Download Selected To..." : "Download To...") {
                        if !model.selectedRemoteIDs.contains(item.id) {
                            model.selectedRemoteIDs = [item.id]
                        }
                        model.downloadSelectedToFolder()
                    }
                    Button("Get Info") {
                        model.selectedRemoteIDs = [item.id]
                        model.getInfoRemoteSelected()
                    }
                    Divider()
                    Button("Open") {
                        model.selectedRemoteIDs = [item.id]
                        model.editRemoteSelected()
                    }
                    .disabled(item.isDirectory)
                    Button("Open With...") {
                        model.selectedRemoteIDs = [item.id]
                        model.openRemoteSelectedWithApp()
                    }
                    .disabled(item.isDirectory)
                    Button("Copy Path") {
                        model.selectedRemoteIDs = [item.id]
                        model.copyRemotePath()
                    }
                    Divider()
                    Button("Delete...") {
                        model.selectedRemoteIDs = [item.id]
                        model.deleteRemoteSelected()
                    }
                    Button("Move...") {
                        model.selectedRemoteIDs = [item.id]
                        model.moveRemoteSelected()
                    }
                    Button("Duplicate") {
                        model.selectedRemoteIDs = [item.id]
                        model.duplicateRemoteSelected()
                    }
                    Button("Rename") {
                        model.selectedRemoteIDs = [item.id]
                        model.renameRemoteSelected()
                    }
                    Divider()
                    Button("New Folder") { model.makeRemoteFolder() }
                        .disabled(model.selectedConnection == nil)
                    Button("New File") { model.makeRemoteFile() }
                        .disabled(model.selectedConnection == nil)
                    Button("Refresh") { model.refreshRemote() }
                    if item.isDirectory {
                        Divider()
                        Button("Open in New Tab") {
                            model.selectedRemoteIDs = [item.id]
                            model.openInNewTabRemote()
                        }
                    }
                },
                backgroundContextMenu: {
                    Button("New Folder", action: model.makeRemoteFolder)
                        .disabled(model.selectedConnection == nil)
                    Button("New File", action: model.makeRemoteFile)
                        .disabled(model.selectedConnection == nil)
                    Button("Refresh", action: model.refreshRemote)
                }
            )
    }
}

private struct PaneToolbarIconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PaneToolbarMenuLabel: View {
    var systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 28)
            .contentShape(Rectangle())
    }
}

struct FilePane<ToolbarContent: View, ContextMenuContent: View, BackgroundContextMenuContent: View>: View {
    private enum ListColumn: Equatable {
        case name
        case metadata(FileBrowserColumn)
    }

    private struct ColumnResizeDraft {
        var left: ListColumn
        var right: ListColumn
        var baseLeftWidth: CGFloat
        var baseRightWidth: CGFloat
        var leftWidth: CGFloat
        var rightWidth: CGFloat
    }

    private struct ListLayout {
        var tableWidth: CGFloat
        var contentWidth: CGFloat
        var nameWidth: CGFloat
        var metadataWidths: [FileBrowserColumn: CGFloat]
    }

    var title: String
    @Binding var path: String
    var submitPath: () -> Void
    var items: [FileItem]
    @Binding var selection: Set<FileItem.ID>
    @Binding var preferences: FileBrowserPreferences
    var isRemote: Bool
    var searchText: String
    @ViewBuilder var toolbar: () -> ToolbarContent
    var open: (FileItem) -> Void
    @ViewBuilder var contextMenu: (FileItem) -> ContextMenuContent
    @ViewBuilder var backgroundContextMenu: () -> BackgroundContextMenuContent
    @State private var anchorSelectionID: FileItem.ID?
    @State private var columnResizeDraft: ColumnResizeDraft?
    @State private var visibleItems: [FileItem] = []

    private let listColumnSpacing: CGFloat = 12
    private let listHorizontalInset: CGFloat = 20
    private let listHeaderHeight: CGFloat = 38
    private let listMaximumNameColumnShare: CGFloat = 0.48

    private func recomputeVisibleItems() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = items
            .filter { preferences.showHiddenFiles || !$0.isHidden }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
            .sorted(by: sortsBefore)
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader(displayedItems: visibleItems)

            browserContent(displayedItems: visibleItems)
                .background(Color.clear)
                .contentShape(Rectangle())
                .contextMenu { backgroundContextMenu() }
            if preferences.showFileCount {
                Divider()
                Text("\(visibleItems.count) items").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .frame(minWidth: 300)
        .background(VoltTheme.paneBackground)
        .onAppear(perform: recomputeVisibleItems)
        .onChange(of: items) { _, _ in recomputeVisibleItems() }
        .onChange(of: preferences) { _, _ in recomputeVisibleItems() }
        .onChange(of: searchText) { _, _ in recomputeVisibleItems() }
    }

    private func paneHeader(displayedItems: [FileItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                pathBarContainer
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                    .layoutPriority(-10)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        itemCountLabel(displayedItems: displayedItems)
                        paneToolbarControls
                    }
                    paneToolbarControls
                }
                .layoutPriority(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)

            Divider()
        }
    }

    private var pathBarContainer: some View {
        HStack(spacing: 8) {
            Image(systemName: isRemote ? "network" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                pathBar
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(VoltTheme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(VoltTheme.hairline)
        )
    }

    private func itemCountLabel(displayedItems: [FileItem]) -> some View {
        Text(itemCountText(displayedItems: displayedItems))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var paneToolbarControls: some View {
        HStack(spacing: 4) {
            toolbar()
                .buttonStyle(.borderless)
                .controlSize(.small)
            viewOptions
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            ForEach(pathCrumbs, id: \.path) { crumb in
                Button {
                    path = crumb.path
                    submitPath()
                } label: {
                    Text(crumb.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(crumb.path)

                if crumb.path != pathCrumbs.last?.path {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contextMenu {
            TextField("Path", text: $path)
                .textFieldStyle(.plain)
                .onSubmit(submitPath)
            Button("Go", action: submitPath)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    private var pathCrumbs: [(title: String, path: String)] {
        let normalized = path.isEmpty ? (isRemote ? "/" : FileManager.default.homeDirectoryForCurrentUser.path) : path
        if isRemote {
            let parts = normalized.split(separator: "/").map(String.init)
            var crumbs: [(String, String)] = [("/", "/")]
            var current = ""
            for part in parts {
                current += "/" + part
                crumbs.append((part, current))
            }
            return crumbs
        }

        let url = URL(fileURLWithPath: (normalized as NSString).expandingTildeInPath).standardizedFileURL
        let components = url.pathComponents
        var crumbs: [(String, String)] = []
        var current = ""
        for component in components {
            if component == "/" {
                current = "/"
                crumbs.append(("/", "/"))
            } else {
                current = current == "/" ? "/" + component : current + "/" + component
                let title = component == NSUserName() ? "Home" : component
                crumbs.append((title, current))
            }
        }
        return crumbs.isEmpty ? [("Home", FileManager.default.homeDirectoryForCurrentUser.path)] : crumbs
    }

    private func itemCountText(displayedItems: [FileItem]) -> String {
        let total = displayedItems.count
        let selectedCount = displayedItems.reduce(0) { count, item in
            count + (selection.contains(item.id) ? 1 : 0)
        }
        if selectedCount > 0 {
            return "\(selectedCount) of \(total) selected"
        }
        return "\(total) items"
    }

    @ViewBuilder private func browserContent(displayedItems: [FileItem]) -> some View {
        switch preferences.viewMode {
        case .list:
            GeometryReader { proxy in
                let layout = listLayout(availableWidth: proxy.size.width)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        listHeaderContent(layout: layout)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                                    listRow(item, index: index, layout: layout)
                                }
                            }
                            .frame(width: layout.tableWidth, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(width: layout.tableWidth, height: proxy.size.height, alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        case .icons, .thumbnails:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: preferences.viewMode == .thumbnails ? 140 : 105), spacing: 12)], spacing: 12) {
                    ForEach(displayedItems) { item in iconCell(item) }
                }.padding(12)
            }
        case .columns:
            columnBrowser(displayedItems: displayedItems)
        }
    }

    @ViewBuilder private func listHeaderContent(layout: ListLayout) -> some View {
        let visibleColumns = preferences.visibleColumns
        HStack(spacing: listColumnSpacing) {
            resizableHeader(
                title: "Name",
                field: .name,
                width: layoutWidth(for: .name, layout: layout),
                onResizeDelta: visibleColumns.first.map { firstColumn in
                    { delta in
                        resizeBoundary(left: .name, right: .metadata(firstColumn), delta: delta)
                    }
                },
                onResizeEnd: commitColumnResize
            )
            ForEach(Array(visibleColumns.enumerated()), id: \.element.id) { index, column in
                let nextColumn = visibleColumns.indices.contains(index + 1) ? visibleColumns[index + 1] : nil
                resizableHeader(
                    title: column.rawValue,
                    field: sortField(for: column),
                    width: layoutWidth(for: .metadata(column), layout: layout),
                    onResizeDelta: nextColumn.map { nextColumn in
                        { delta in
                            resizeBoundary(left: .metadata(column), right: .metadata(nextColumn), delta: delta)
                        }
                    },
                    onResizeEnd: commitColumnResize
                )
            }
            Spacer(minLength: 0)
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, listHorizontalInset)
        .padding(.vertical, 8)
        .frame(width: layout.tableWidth, height: listHeaderHeight, alignment: .leading)
        .contentShape(Rectangle()).contextMenu { columnMenu }
    }

    @ViewBuilder private func listRow(_ item: FileItem, index: Int, layout: ListLayout) -> some View {
        let visibleColumns = preferences.visibleColumns
        HStack(spacing: listColumnSpacing) {
            HStack(spacing: 9) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(item.name)
                    .lineLimit(1)
            }
            .frame(width: layoutWidth(for: .name, layout: layout), alignment: .leading)
            ForEach(visibleColumns) { column in
                Text(text(for: column, item: item)).foregroundStyle(isSelected(item) ? Color.primary.opacity(0.9) : Color.secondary)
                    .frame(width: layoutWidth(for: .metadata(column), layout: layout), alignment: .leading).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .font(.system(size: preferences.textSize))
        .padding(.horizontal, listHorizontalInset)
        .padding(.vertical, 7)
        .frame(width: layout.tableWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected(item) ? VoltTheme.selectedFill : (preferences.showRowColors && index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear)))
        .background { RightClickSelectionView { selectForContextMenu(item) } }
        .foregroundStyle(Color.primary).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        .onTapGesture(count: 2) { select(item, modifiers: NSEvent.modifierFlags); open(item) }
        .simultaneousGesture(TapGesture().onEnded { select(item, modifiers: NSEvent.modifierFlags) })
        .contextMenu { contextMenu(item) }
    }

    private func iconCell(_ item: FileItem) -> some View {
        VStack(spacing: 7) {
            if preferences.viewMode == .thumbnails {
                FileThumbnailView(item: item, isRemote: isRemote).frame(width: 96, height: 72)
            } else {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").resizable().scaledToFit()
                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary).frame(width: 48, height: 48)
            }
            Text(item.name).font(.system(size: preferences.textSize)).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 100).padding(8)
        .background(isSelected(item) ? Color.accentColor.opacity(0.35) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        .onTapGesture(count: 2) { select(item, modifiers: NSEvent.modifierFlags); open(item) }
        .simultaneousGesture(TapGesture().onEnded { select(item, modifiers: NSEvent.modifierFlags) })
        .contextMenu { contextMenu(item) }
    }

    private func columnBrowser(displayedItems: [FileItem]) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(displayedItems) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder" : "doc")
                            Text(item.name).lineLimit(1); Spacer()
                            if item.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        }
                        .font(.system(size: preferences.textSize)).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(isSelected(item) ? Color.accentColor : Color.clear).foregroundStyle(isSelected(item) ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { select(item, modifiers: NSEvent.modifierFlags); open(item) }
                        .simultaneousGesture(TapGesture().onEnded { select(item, modifiers: NSEvent.modifierFlags) })
                        .contextMenu { contextMenu(item) }
                    }
                }.padding(6)
            }.frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
            Divider()
            VStack(spacing: 12) {
                if let item = displayedItems.first(where: { selection.contains($0.id) }) {
                    FileThumbnailView(item: item, isRemote: isRemote).frame(width: 128, height: 100)
                    Text(item.name).font(.headline).multilineTextAlignment(.center)
                    Text(item.kind).foregroundStyle(.secondary)
                    if !item.isDirectory { Text(ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)).foregroundStyle(.secondary) }
                } else {
                    Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Select an item").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        }
    }

    private var viewOptions: some View {
        Menu {
            Picker("View", selection: $preferences.viewMode) {
                ForEach(FileBrowserViewMode.allCases) { mode in Label(mode.rawValue.capitalized, systemImage: mode.systemImage).tag(mode) }
            }
            Divider(); columnMenu; Divider()
            Toggle("Show row colors", isOn: $preferences.showRowColors)
            Toggle("Show hidden files", isOn: $preferences.showHiddenFiles)
            Toggle("Folders above files", isOn: $preferences.foldersFirst)
            Toggle("Use relative dates", isOn: $preferences.useRelativeDates)
            Toggle("Show file count", isOn: $preferences.showFileCount)
            Divider()
            Stepper("Text size: \(Int(preferences.textSize))", value: $preferences.textSize, in: 10...20, step: 1)
        } label: {
            PaneToolbarMenuLabel(systemImage: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton).fixedSize().help("View options")
    }

    @ViewBuilder private var columnMenu: some View {
        ForEach(FileBrowserColumn.allCases) { column in
            Toggle(column.rawValue, isOn: columnVisibilityBinding(for: column))
        }
        Divider()
        Button("Reset Column Widths", action: resetColumnWidths)
    }

    private func headerButton(_ title: String, field: FileBrowserSortField) -> some View {
        Button {
            if preferences.sortField == field { preferences.sortAscending.toggle() }
            else { preferences.sortField = field; preferences.sortAscending = true }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if preferences.sortField == field { Image(systemName: preferences.sortAscending ? "chevron.up" : "chevron.down").font(.caption2) }
            }
        }.buttonStyle(.plain)
    }

    private func resizableHeader(
        title: String,
        field: FileBrowserSortField,
        width: CGFloat,
        onResizeDelta: ((CGFloat) -> Void)?,
        onResizeEnd: @escaping () -> Void
    ) -> some View {
        headerButton(title, field: field)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let onResizeDelta {
                    ColumnResizeHandle(onResizeDelta: onResizeDelta, onResizeEnd: onResizeEnd)
                        .offset(x: 8)
                }
            }
    }

    private func columnVisibilityBinding(for column: FileBrowserColumn) -> Binding<Bool> {
        Binding(
            get: { preferences.visibleColumns.contains(column) },
            set: { isVisible in
                if isVisible {
                    if !preferences.visibleColumns.contains(column) { preferences.visibleColumns.append(column) }
                } else {
                    preferences.visibleColumns.removeAll { $0 == column }
                }
            }
        )
    }

    private func sortField(for column: FileBrowserColumn) -> FileBrowserSortField {
        switch column { case .size: .size; case .date: .date; case .kind: .kind; case .owner: .owner; case .group: .group; case .permissions: .permissions }
    }

    private func width(for column: ListColumn) -> CGFloat {
        if let columnResizeDraft {
            if columnResizeDraft.left == column { return columnResizeDraft.leftWidth }
            if columnResizeDraft.right == column { return columnResizeDraft.rightWidth }
        }
        return storedWidth(for: column)
    }

    private func storedWidth(for column: ListColumn) -> CGFloat {
        switch column {
        case .name:
            max(minWidth(for: column), preferences.nameColumnWidth)
        case .metadata(let metadataColumn):
            max(minWidth(for: column), preferences.columnWidths[metadataColumn] ?? metadataColumn.width)
        }
    }

    private func listLayout(availableWidth: CGFloat) -> ListLayout {
        let visibleColumns = preferences.visibleColumns
        let availableContentWidth = max(0, availableWidth - (listHorizontalInset * 2))
        let baseNameWidth = width(for: .name)
        let metadataWidths = Dictionary(
            uniqueKeysWithValues: visibleColumns.map { column in
                (column, width(for: .metadata(column)))
            }
        )
        let metadataWidth = visibleColumns.reduce(CGFloat(0)) { partial, column in
            partial + (metadataWidths[column] ?? width(for: .metadata(column)))
        }
        let spacing = CGFloat(max(0, visibleColumns.count)) * listColumnSpacing
        let preferredNameWidth: CGFloat
        if visibleColumns.isEmpty {
            preferredNameWidth = baseNameWidth
        } else {
            let responsiveMaximumNameWidth = max(
                minWidth(for: .name),
                availableContentWidth * listMaximumNameColumnShare
            )
            preferredNameWidth = min(baseNameWidth, responsiveMaximumNameWidth)
        }
        let preferredContentWidth = preferredNameWidth + metadataWidth + spacing
        let nameOverflow = max(0, preferredContentWidth - availableContentWidth)
        let nameWidth = max(minWidth(for: .name), preferredNameWidth - nameOverflow)
        let compactContentWidth = nameWidth + metadataWidth + spacing
        let extraWidth = max(0, availableContentWidth - compactContentWidth)
        let stretchedMetadataWidths = metadataWidthsForLayout(
            metadataWidths,
            visibleColumns: visibleColumns,
            extraWidth: extraWidth
        )
        let contentWidth = compactContentWidth + extraWidth
        return ListLayout(
            tableWidth: contentWidth + (listHorizontalInset * 2),
            contentWidth: contentWidth,
            nameWidth: visibleColumns.isEmpty ? nameWidth + extraWidth : nameWidth,
            metadataWidths: stretchedMetadataWidths
        )
    }

    private func metadataWidthsForLayout(
        _ metadataWidths: [FileBrowserColumn: CGFloat],
        visibleColumns: [FileBrowserColumn],
        extraWidth: CGFloat
    ) -> [FileBrowserColumn: CGFloat] {
        guard extraWidth > 0, let trailingColumn = visibleColumns.last else { return metadataWidths }
        var stretchedWidths = metadataWidths
        stretchedWidths[trailingColumn, default: width(for: .metadata(trailingColumn))] += extraWidth
        return stretchedWidths
    }

    private func layoutWidth(for column: ListColumn, layout: ListLayout) -> CGFloat {
        switch column {
        case .name:
            layout.nameWidth
        case .metadata(let metadataColumn):
            layout.metadataWidths[metadataColumn] ?? width(for: column)
        }
    }

    private func setWidth(_ width: CGFloat, for column: ListColumn) {
        let clampedWidth = max(minWidth(for: column), width)
        switch column {
        case .name:
            preferences.nameColumnWidth = clampedWidth
        case .metadata(let metadataColumn):
            preferences.columnWidths[metadataColumn] = clampedWidth
        }
    }

    private func minWidth(for column: ListColumn) -> CGFloat {
        switch column {
        case .name: 160
        case .metadata: 72
        }
    }

    private func resizeBoundary(left: ListColumn, right: ListColumn, delta: CGFloat) {
        let draft: ColumnResizeDraft
        if let currentDraft = columnResizeDraft, currentDraft.left == left, currentDraft.right == right {
            draft = currentDraft
        } else {
            let baseLeftWidth = storedWidth(for: left)
            let baseRightWidth = storedWidth(for: right)
            draft = ColumnResizeDraft(
                left: left,
                right: right,
                baseLeftWidth: baseLeftWidth,
                baseRightWidth: baseRightWidth,
                leftWidth: baseLeftWidth,
                rightWidth: baseRightWidth
            )
        }
        let minimumDelta = minWidth(for: left) - draft.baseLeftWidth
        let maximumDelta = draft.baseRightWidth - minWidth(for: right)
        let clampedDelta = min(max(delta, minimumDelta), maximumDelta)
        columnResizeDraft = ColumnResizeDraft(
            left: left,
            right: right,
            baseLeftWidth: draft.baseLeftWidth,
            baseRightWidth: draft.baseRightWidth,
            leftWidth: draft.baseLeftWidth + clampedDelta,
            rightWidth: draft.baseRightWidth - clampedDelta
        )
    }

    private func commitColumnResize() {
        guard let draft = columnResizeDraft else { return }
        setWidth(draft.leftWidth, for: draft.left)
        setWidth(draft.rightWidth, for: draft.right)
        columnResizeDraft = nil
    }

    private func resetColumnWidths() {
        preferences.nameColumnWidth = 360
        preferences.columnWidths = [:]
        columnResizeDraft = nil
    }

    private func isSelected(_ item: FileItem) -> Bool {
        selection.contains(item.id)
    }

    private func selectForContextMenu(_ item: FileItem) {
        if !selection.contains(item.id) {
            selection = [item.id]
            anchorSelectionID = item.id
        }
    }

    private func select(_ item: FileItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchorSelectionID,
           let anchorIndex = visibleItems.firstIndex(where: { $0.id == anchorSelectionID }),
           let itemIndex = visibleItems.firstIndex(where: { $0.id == item.id }) {
            let bounds = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            selection = Set(visibleItems[bounds].map(\.id))
            return
        }

        if modifiers.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
                anchorSelectionID = item.id
            }
            return
        }

        selection = [item.id]
        anchorSelectionID = item.id
    }

    private func sortsBefore(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if preferences.foldersFirst && lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let order: ComparisonResult = switch preferences.sortField {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .size: compare(lhs.size ?? -1, rhs.size ?? -1)
        case .date: compare(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
        case .kind: lhs.kind.localizedStandardCompare(rhs.kind)
        case .owner: (lhs.owner ?? "").localizedStandardCompare(rhs.owner ?? "")
        case .group: (lhs.group ?? "").localizedStandardCompare(rhs.group ?? "")
        case .permissions: compare(lhs.permissions ?? 0, rhs.permissions ?? 0)
        }
        if order == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return preferences.sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult { lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending) }

    private func text(for column: FileBrowserColumn, item: FileItem) -> String {
        switch column {
        case .size: return item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
        case .date:
            guard let date = item.modified else { return "--" }
            return preferences.useRelativeDates ? RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()) : date.formatted(date: .abbreviated, time: .shortened)
        case .kind: return item.kind
        case .owner: return item.owner ?? "--"
        case .group: return item.group ?? "--"
        case .permissions: return item.permissionText
        }
    }
}

@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 512
    }

    func image(forKey key: NSString) -> NSImage? {
        cache.object(forKey: key)
    }

    func insert(_ image: NSImage, forKey key: NSString) {
        cache.setObject(image, forKey: key)
    }

    func key(for item: FileItem) -> NSString {
        let modified = item.modified?.timeIntervalSince1970 ?? 0
        return "\(item.path)|\(modified)" as NSString
    }
}

private struct FileThumbnailView: View {
    var item: FileItem
    var isRemote: Bool
    @State private var image: NSImage?

    private var taskID: String {
        let modified = item.modified?.timeIntervalSince1970 ?? 0
        return "\(isRemote)|\(item.path)|\(modified)"
    }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").resizable().scaledToFit().foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary).padding(16) }
        }
        .task(id: taskID) {
            image = nil
            guard !isRemote, !item.isDirectory else { return }
            let cacheKey = ThumbnailCache.shared.key(for: item)
            if let cachedImage = ThumbnailCache.shared.image(forKey: cacheKey) {
                image = cachedImage
                return
            }
            let thumbnailSize = CGSize(width: 256, height: 192)
            let thumbnailScale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: item.path), size: thumbnailSize, scale: thumbnailScale, representationTypes: .thumbnail)
            let generatedCGImage: CGImage? = await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.cgImage)
                }
            }
            guard !Task.isCancelled, let generatedCGImage else { return }
            let generatedImage = NSImage(
                cgImage: generatedCGImage,
                size: NSSize(
                    width: CGFloat(generatedCGImage.width) / thumbnailScale,
                    height: CGFloat(generatedCGImage.height) / thumbnailScale
                )
            )
            ThumbnailCache.shared.insert(generatedImage, forKey: cacheKey)
            image = generatedImage
        }
    }
}

private struct RightClickSelectionView: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickTrackingView {
        let view = RightClickTrackingView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickTrackingView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

private struct ColumnResizeHandle: View {
    var onResizeDelta: (CGFloat) -> Void
    var onResizeEnd: () -> Void

    var body: some View {
        ZStack {
            ResizeDragHandleView(
                axis: .horizontal,
                cursor: .resizeLeftRight,
                currentValue: 0,
                minValue: -10_000,
                maxValue: 10_000,
                onResize: onResizeDelta,
                onResizeEnd: onResizeEnd
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .frame(width: 12)
        .help("Drag to resize column")
    }
}

private final class RightClickTrackingView: NSView {
    var onRightClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
        super.rightMouseDown(with: event)
    }
}

struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.status)
                .lineLimit(1)
            Spacer()
            Button(action: {
                model.showsTransfers.toggle()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("\(model.transfers.count)")
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Toggle Transfers")
            Text("Volt")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}



struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Inspector")
                    .font(.headline)
                HStack {
                    Spacer()
                    Button(action: {
                        if let text = model.selectedRemote?.path ?? model.selectedLocal?.path {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy Path")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 24) {
                    if let local = model.selectedLocal {
                        InspectorSection(title: "Local Item", item: local, isLocal: true, onCalculateSize: {
                            await model.calculateSize(for: local, isLocal: true)
                        })
                    }
                    
                    if let remote = model.selectedRemote {
                        InspectorSection(title: "Remote Item", item: remote, isLocal: false, onCalculateSize: {
                            await model.calculateSize(for: remote, isLocal: false)
                        })
                    }
                    
                    if model.selectedLocal == nil && model.selectedRemote == nil {
                        Text("No selection")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 260, idealWidth: 280)
    }
}

struct InspectorSection: View {
    var title: String?
    var item: FileItem
    var isLocal: Bool
    var onCalculateSize: () async -> Void
    @State private var isExpanded = true
    @State private var isCalculatingSize = false

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.bottom, 16)
            }
            
            icon(for: item)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 140, height: 140)
                .padding(.bottom, 24)
            
            Divider()
                .padding(.bottom, 12)
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption.weight(.bold))
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.isDirectory ? "Folder" : "File")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    
                    if item.isDirectory {
                        if let size = item.size {
                            Text("\(NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal)) bytes ")
                                .font(.subheadline).bold()
                                .foregroundStyle(.primary)
                            + Text("(\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on disk)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if isCalculatingSize {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Calculating...").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Calculate Size") {
                                isCalculatingSize = true
                                Task {
                                    await onCalculateSize()
                                    isCalculatingSize = false
                                }
                            }
                            .buttonStyle(.link)
                            .font(.subheadline)
                        }
                    } else if let size = item.size {
                        Text("\(NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal)) bytes ")
                            .font(.subheadline).bold()
                            .foregroundStyle(.primary)
                        + Text("(\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on disk)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text((item.path as NSString).deletingLastPathComponent)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                        
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Created").foregroundStyle(.secondary)
                            Text("n/a").foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Modified").foregroundStyle(.secondary)
                            if let modified = item.modified {
                                Text(modified.formatted(date: .abbreviated, time: .shortened))
                            } else {
                                Text("--")
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    private func icon(for item: FileItem) -> Image {
        let nsImage: NSImage
        if item.isDirectory {
            nsImage = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (item.name as NSString).pathExtension
            let contentType = ext.isEmpty ? UTType.data : UTType(filenameExtension: ext) ?? .data
            nsImage = NSWorkspace.shared.icon(for: contentType)
        }
        return Image(nsImage: nsImage)
    }
}

@main
struct VoltApp: App {
    @NSApplicationDelegateAdaptor(VoltAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class VoltAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppPaths.cleanupEditFiles(olderThan: 0)
    }
}
