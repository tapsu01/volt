import AppKit
import CVoltSSH
import CryptoKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

private func decodeCError(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
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

    var effectivePermissionPreset: RemotePermissionPreset {
        permissionPreset ?? .web
    }
}

struct HostKeyProbe: Sendable {
    var key: Data
    var keyType: Int32
    var trustStatus: Int32
}

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64?
    var modified: Date?
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
}

struct TransferJob: Identifiable {
    let id = UUID()
    var direction: TransferDirection
    var source: String
    var destination: String
    var state: TransferState = .queued
    var message: String = ""
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
    var selectedLocalID: FileItem.ID?
    var selectedRemoteID: FileItem.ID?
    var remoteEditSessions: [RemoteEditSession] = []
    var isConnected = false
    var showsConnectionEditor = true
    var showsInspector = false
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

final class SFTPClient: @unchecked Sendable {
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

    func list(connection: SavedConnection, password: String, path: String) async throws -> [FileItem] {
        try await Task.detached {
            var items: UnsafeMutablePointer<VoltSFTPItem>?
            var count: Int32 = 0
            _ = try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_list(host, port, username, password, keyPath, knownHostsPath, path, &items, &count, error, errorLength)
            }
            defer {
                if let items {
                    volt_sftp_free_items(items)
                }
            }
            guard let items else { return [] }
            return (0..<Int(count))
                .map { index in
                    let rawSize = volt_sftp_item_size(items, Int32(index))
                    let rawModified = volt_sftp_item_modified(items, Int32(index))
                    return FileItem(
                        name: String(cString: volt_sftp_item_name(items, Int32(index))),
                        path: String(cString: volt_sftp_item_path(items, Int32(index))),
                        isDirectory: volt_sftp_item_is_directory(items, Int32(index)) != 0,
                        size: rawSize >= 0 ? rawSize : nil,
                        modified: rawModified > 0 ? Date(timeIntervalSince1970: TimeInterval(rawModified)) : nil
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
        }.value
    }

    func upload(connection: SavedConnection, password: String, localPath: String, remotePath: String) async throws -> String? {
        try await Task.detached {
            try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_upload(host, port, username, password, keyPath, knownHostsPath, localPath, remotePath, connection.effectivePermissionPreset.fileMode, error, errorLength)
            }
        }.value
    }

    func download(connection: SavedConnection, password: String, remotePath: String, localPath: String) async throws {
        try await Task.detached {
            _ = try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_download(host, port, username, password, keyPath, knownHostsPath, remotePath, localPath, error, errorLength)
            }
        }.value
    }

    func makeDirectory(connection: SavedConnection, password: String, path: String) async throws -> String? {
        try await Task.detached {
            try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_mkdir(host, port, username, password, keyPath, knownHostsPath, path, connection.effectivePermissionPreset.folderMode, error, errorLength)
            }
        }.value
    }

    func createFile(connection: SavedConnection, password: String, remotePath: String) async throws -> String? {
        try await Task.detached {
            try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_create_empty_file(host, port, username, password, keyPath, knownHostsPath, remotePath, connection.effectivePermissionPreset.fileMode, error, errorLength)
            }
        }.value
    }

    func rename(connection: SavedConnection, password: String, from: String, to: String) async throws {
        try await Task.detached {
            _ = try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_rename(host, port, username, password, keyPath, knownHostsPath, from, to, error, errorLength)
            }
        }.value
    }

    func remove(connection: SavedConnection, password: String, path: String, isDirectory: Bool) async throws {
        try await Task.detached {
            _ = try self.call(connection: connection, password: password) { host, port, username, password, keyPath, knownHostsPath, error, errorLength in
                volt_sftp_remove(host, port, username, password, keyPath, knownHostsPath, path, isDirectory ? 1 : 0, error, errorLength)
            }
        }.value
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
        password: String,
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
        let sanitizedPassword = password.trimmingCharacters(in: .newlines)
        let knownHostsPath = try AppPaths.knownHostsURL().path
        let status = connection.host.withCString { host in
            connection.username.withCString { username in
                knownHostsPath.withCString { knownHostsPointer in
                    error.withUnsafeMutableBufferPointer { errorBuffer in
                        let errorPointer = errorBuffer.baseAddress!
                        if keyPath.isEmpty {
                            if sanitizedPassword.isEmpty {
                                return body(host, Int32(connection.port), username, nil, nil, knownHostsPointer, errorPointer, errorLength)
                            }
                            return sanitizedPassword.withCString { passwordPointer in
                                body(host, Int32(connection.port), username, passwordPointer, nil, knownHostsPointer, errorPointer, errorLength)
                            }
                        }
                        return keyPath.withCString { keyPointer in
                            if sanitizedPassword.isEmpty {
                                return body(host, Int32(connection.port), username, nil, keyPointer, knownHostsPointer, errorPointer, errorLength)
                            }
                            return sanitizedPassword.withCString { passwordPointer in
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
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [SavedConnection] = []
    @Published var tabs: [BrowserTab] = [BrowserTab()]
    @Published var selectedTabID: BrowserTab.ID?
    @Published var selectedConnectionID: UUID?
    @Published var connectionDraft = SavedConnection()
    @Published var connectionPassword = ""

    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = "/"
    @Published var localItems: [FileItem] = []
    @Published var remoteItems: [FileItem] = []
    @Published var selectedLocalID: FileItem.ID?
    @Published var selectedRemoteID: FileItem.ID?
    @Published var transfers: [TransferJob] = []
    @Published var remoteEditSessions: [RemoteEditSession] = []
    @Published var status = "Ready"
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var showsConnectionEditor = true
    @Published var showsInspector = false
    @Published var showsTransfers = false
    @Published var showsPasswordPrompt = false
    @Published var showsHostKeyPrompt = false
    @Published var pendingHostKeyFingerprint = ""
    @Published var pendingHostKeyHost = ""
    private var hostKeyConfirmationContinuation: CheckedContinuation<Bool, Never>?
    private var tabPasswords: [BrowserTab.ID: String] = [:]
    private var verifiedHosts: Set<String> = []
    private var remoteDirectoryCache: [String: [FileItem]] = [:]

    private let sftp = SFTPClient()
    private var isRestoringTab = false
    private var isSuppressingSidebarSelection = false
    private var isSelectingConnection = false

    init() {
        selectedTabID = tabs.first?.id
        AppPaths.migrateFromSandboxContainerIfNeeded()
        SecureStorage.migrateFromUserDefaults()
        AppPaths.cleanupEditFiles()
        loadConnections()
        refreshLocal()
        syncCurrentTab()
    }

    var selectedConnection: SavedConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    var selectedLocal: FileItem? {
        localItems.first { $0.id == selectedLocalID }
    }

    var selectedRemote: FileItem? {
        remoteItems.first { $0.id == selectedRemoteID }
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func newTab() {
        syncCurrentTab()
        var tab = BrowserTab()
        tab.localPath = localPath
        tab.localItems = localItems
        tab.title = "New Tab"
        tabs.append(tab)
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
            let password = connectionPassword
            let runner = CommandRunner()
            let executable = "/usr/bin/ssh"
            let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPassword.isEmpty else { return }
            
            do {
                let controlDir = try SFTPClient.controlSocketDir()
                let knownHostsPath = try AppPaths.knownHostsURL().path

                var args = [
                    "-oBatchMode=\(trimmedPassword.isEmpty ? "yes" : "no")",
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
                args.append("\(connection.username)@\(connection.host)")
                
                let quotedPath = "'" + item.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                args.append("du -sk \(quotedPath)")

                let result = try runner.run(executable, arguments: args, stdin: "")
                if result.status == 0,
                   let sizeStr = result.stdout.split(separator: "\t").first,
                   let sizeKB = Int64(sizeStr) {
                    let sizeBytes = sizeKB * 1024
                    await MainActor.run {
                        if let index = self.remoteItems.firstIndex(where: { $0.id == item.id }) {
                            self.remoteItems[index].size = sizeBytes
                            self.syncCurrentTab()
                        }
                    }
                }
            } catch {
                // Ignore failure
            }
        }
    }

    func closeCurrentTab() {
        if let id = selectedTabID {
            closeTab(id)
        }
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard tabs.count > 1 else { return }
        if let tab = tabs.first(where: { $0.id == id }) {
            cleanupEditSessions(tab.remoteEditSessions)
        }
        tabPasswords.removeValue(forKey: id)
        let index = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectTab(tabs[nextIndex].id)
        }
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
        if selectedConnectionID == connection.id, isConnected {
            showsConnectionEditor = false
            return
        }
        isSelectingConnection = true
        defer { isSelectingConnection = false }

        selectedConnectionID = connection.id
        connectionDraft = connection
        connectionPassword = ""
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
        isSuppressingSidebarSelection = true
        selectedConnectionID = connection.id
        connectionDraft = connection
        connectionPassword = ""
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
        if let index = connections.firstIndex(where: { $0.id == connectionDraft.id }) {
            connections[index] = connectionDraft
        } else {
            connections.append(connectionDraft)
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

    func connectDraft() {
        if let validationError = validate(connectionDraft) {
            status = validationError
            return
        }
        remotePath = connectionDraft.remotePath.isEmpty ? "/" : connectionDraft.remotePath
        saveDraft()
        showsConnectionEditor = false
        syncCurrentTab()
        refreshRemote()
    }

    func newConnection() {
        connectionDraft = SavedConnection()
        connectionPassword = ""
        selectedConnectionID = nil
        isConnected = false
        showsConnectionEditor = true
        showsPasswordPrompt = false
        remoteItems = []
        selectedRemoteID = nil
        remotePath = "/"
        syncCurrentTab()
    }

    func deleteSelectedConnection() {
        guard let id = selectedConnectionID else { return }
        removeConnection(id: id)
    }

    func disconnectConnection(id: UUID? = nil) {
        if id == nil || selectedConnectionID == id {
            cleanupEditSessions(remoteEditSessions)
            selectedConnectionID = nil
            connectionDraft = SavedConnection()
            connectionPassword = ""
            if let tabID = selectedTabID {
                tabPasswords.removeValue(forKey: tabID)
            }
            remoteItems = []
            selectedRemoteID = nil
            remotePath = "/"
            remoteEditSessions = []
            isConnected = false
            showsConnectionEditor = true
            showsPasswordPrompt = false
            status = "Disconnected"
            syncCurrentTab()
        }
    }

    func connectWithPassword() {
        showsPasswordPrompt = false
        syncCurrentTab()
        refreshRemote()
    }

    func cancelPasswordPrompt() {
        showsPasswordPrompt = false
        connectionPassword = ""
        syncCurrentTab()
    }

    func removeConnection(id: UUID) {
        connections.removeAll { $0.id == id }
        disconnectConnection(id: id)
        saveConnections()
        status = "Connection removed"
    }

    func refreshLocal() {
        do {
            let url = URL(fileURLWithPath: localPath)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            localItems = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .map { fileURL in
                    let values = try fileURL.resourceValues(forKeys: keys)
                    return FileItem(
                        name: fileURL.lastPathComponent,
                        path: fileURL.path,
                        isDirectory: values.isDirectory == true,
                        size: values.fileSize.map(Int64.init),
                        modified: values.contentModificationDate
                    )
                }
                .sorted(by: itemSort)
            status = "Local folder loaded"
            syncCurrentTab()
        } catch {
            status = error.localizedDescription
        }
    }

    func refreshRemote() {
        refreshRemote(finalStatus: "Remote folder loaded")
    }

    private func refreshRemote(finalStatus: String) {
        guard let connection = selectedConnection else { status = "Choose a connection"; return }
        if let validationError = validate(connection) {
            status = validationError
            return
        }
        let path = remotePath
        let password = connectionPassword
        runBusy("Loading remote folder") {
            try await self.verifyHostKey(for: connection)
            let items = try await self.sftp.list(connection: connection, password: password, path: path)
            await MainActor.run {
                guard self.selectedConnectionID == connection.id, self.remotePath == path else { return }
                self.remoteItems = items
                self.remoteDirectoryCache[self.remoteCacheKey(connectionID: connection.id, path: path)] = items
                self.isConnected = true
                self.showsConnectionEditor = false
                self.status = finalStatus
                self.syncCurrentTab()
            }
        }
    }

    func openLocal(_ item: FileItem) {
        guard item.isDirectory else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            return
        }
        localPath = item.path
        selectedLocalID = nil
        refreshLocal()
        syncCurrentTab()
    }

    func openRemote(_ item: FileItem) {
        guard item.isDirectory else { return }
        remotePath = item.path
        selectedRemoteID = nil
        if let connection = selectedConnection,
           let cachedItems = remoteDirectoryCache[remoteCacheKey(connectionID: connection.id, path: item.path)] {
            remoteItems = cachedItems
        }
        syncCurrentTab()
        refreshRemote()
    }

    func localUp() {
        let parent = URL(fileURLWithPath: localPath).deletingLastPathComponent().path
        localPath = parent.isEmpty ? "/" : parent
        refreshLocal()
        syncCurrentTab()
    }

    func remoteUp() {
        guard remotePath != "/" else { return }
        let parent = URL(fileURLWithPath: remotePath).deletingLastPathComponent().path
        remotePath = parent.isEmpty ? "/" : parent
        syncCurrentTab()
        refreshRemote()
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
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
        guard selectedConnection != nil, let item = selectedLocal else { return }
        let destination = joinRemote(remotePath, item.name)
        upload(localPath: item.path, remotePath: destination, refreshWhenDone: true)
    }

    func uploadFromPicker() {
        guard selectedConnection != nil else { status = "Choose a connection"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                upload(localPath: url.path, remotePath: joinRemote(remotePath, url.lastPathComponent), refreshWhenDone: true)
            }
        }
    }

    func uploadEditedRemoteFile(_ session: RemoteEditSession) {
        guard let connection = selectedConnection else { return }
        let password = connectionPassword
        enqueue(direction: .upload, source: session.localPath, destination: session.remotePath)
        runBusy("Uploading edited file") {
            let warning = try await self.sftp.upload(
                connection: connection,
                password: password,
                localPath: session.localPath,
                remotePath: session.remotePath
            )
            await MainActor.run {
                self.markLatestTransfer(.done, warning ?? "Uploaded edited file")
                self.remoteEditSessions.removeAll { $0.id == session.id }
                self.cleanupEditSessions([session])
                self.syncCurrentTab()
                self.refreshRemote()
            }
        }
    }

    private func upload(localPath: String, remotePath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        let password = connectionPassword
        enqueue(direction: .upload, source: localPath, destination: remotePath)
        runBusy("Uploading") {
            let warning = try await self.sftp.upload(connection: connection, password: password, localPath: localPath, remotePath: remotePath)
            await MainActor.run {
                self.markLatestTransfer(.done, warning ?? "Uploaded")
                if let warning { self.status = warning }
                if refreshWhenDone {
                    self.refreshRemote()
                }
            }
        }
    }

    func downloadSelected() {
        guard selectedConnection != nil, let item = selectedRemote else { return }
        let destination = URL(fileURLWithPath: localPath).appendingPathComponent(item.name).path
        download(remotePath: item.path, localPath: destination, refreshWhenDone: true)
    }

    func downloadSelectedToFolder() {
        guard let item = selectedRemote else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folder = panel.url {
            let destination = folder.appendingPathComponent(item.name).path
            download(remotePath: item.path, localPath: destination, refreshWhenDone: false)
        }
    }

    private func download(remotePath: String, localPath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        let password = connectionPassword
        enqueue(direction: .download, source: remotePath, destination: localPath)
        runBusy("Downloading") {
            try await self.sftp.download(connection: connection, password: password, remotePath: remotePath, localPath: localPath)
            await MainActor.run {
                self.markLatestTransfer(.done, "Downloaded")
                if refreshWhenDone {
                    self.refreshLocal()
                }
            }
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
        let password = connectionPassword
        runBusy("Creating folder") {
            let warning = try await self.sftp.makeDirectory(connection: connection, password: password, path: path)
            await MainActor.run {
                self.refreshRemote(finalStatus: warning ?? "Remote folder loaded")
            }
        }
    }

    func makeRemoteFile() {
        guard let connection = selectedConnection else { return }
        let name = prompt("New Remote File", defaultValue: "untitled.txt", actionTitle: "Create")
        guard !name.isEmpty else { return }
        let path = joinRemote(remotePath, name)
        let password = connectionPassword
        runBusy("Creating file") {
            let warning = try await self.sftp.createFile(connection: connection, password: password, remotePath: path)
            await MainActor.run {
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
        newTab.selectedLocalID = nil
        tabs.append(newTab)
        tabPasswords[newTab.id] = connectionPassword
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
            selectedLocalID = nil
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
        newTab.remoteItems = selectedConnection.flatMap {
            remoteDirectoryCache[remoteCacheKey(connectionID: $0.id, path: item.path)]
        } ?? []
        newTab.selectedRemoteID = nil
        tabs.append(newTab)
        tabPasswords[newTab.id] = connectionPassword
        selectTab(newTab.id)
        refreshRemote()
    }

    func duplicateRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        let newName = item.name + " copy"
        let newPath = joinRemote(remotePath, newName)
        let password = connectionPassword
        runBusy("Duplicating remote item") {
            // Using cp -r over SSH
            let runner = CommandRunner()
            let executable = "/usr/bin/ssh"
            let trimmedPassword = password.trimmingCharacters(in: .newlines)
            guard trimmedPassword.isEmpty else { throw AppError.unsupportedPasswordAuth }
            let controlDir = try SFTPClient.controlSocketDir()
            let knownHostsPath = try AppPaths.knownHostsURL().path
            var args = [
                "-oBatchMode=\(trimmedPassword.isEmpty ? "yes" : "no")",
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
            args.append("\(connection.username)@\(connection.host)")
            
            let quotedSrc = "'" + item.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let quotedDst = "'" + newPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            args.append("cp -r \(quotedSrc) \(quotedDst)")

            _ = try runner.run(executable, arguments: args, stdin: "")
            
            await MainActor.run { self.refreshRemote() }
        }
    }

    func moveRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        let newName = prompt("Move Remote Item To:", defaultValue: item.name, actionTitle: "Move")
        guard !newName.isEmpty, newName != item.name else { return }
        
        let newPath = joinRemote(remotePath, newName)
        let password = connectionPassword
        runBusy("Moving remote item") {
            try await self.sftp.rename(connection: connection, password: password, from: item.path, to: newPath)
            await MainActor.run {
                self.selectedRemoteID = nil
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
            selectedLocalID = nil
            refreshLocal()
        } catch {
            status = error.localizedDescription
        }
    }

    func deleteRemoteSelected() {
        guard let connection = selectedConnection, let item = selectedRemote else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(item.name)\"?"
        alert.informativeText = "This remote item will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = connectionPassword
        runBusy("Deleting remote item") {
            try await self.sftp.remove(connection: connection, password: password, path: item.path, isDirectory: item.isDirectory)
            await MainActor.run {
                self.selectedRemoteID = nil
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
            selectedLocalID = nil
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
        let password = connectionPassword
        runBusy("Renaming remote item") {
            try await self.sftp.rename(connection: connection, password: password, from: item.path, to: destination)
            await MainActor.run {
                self.selectedRemoteID = nil
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
        let localURL = directory.appendingPathComponent(item.name)
        enqueue(direction: .edit, source: item.path, destination: localURL.path)
        downloadForEdit(remoteItem: item, localURL: localURL, appURL: appURL)
    }

    private func downloadForEdit(remoteItem: FileItem, localURL: URL, appURL: URL?) {
        guard let connection = selectedConnection else { return }
        let password = connectionPassword
        runBusy("Downloading file for edit") {
            try await self.sftp.download(connection: connection, password: password, remotePath: remoteItem.path, localPath: localURL.path)
            await MainActor.run {
                self.remoteEditSessions.insert(RemoteEditSession(remotePath: remoteItem.path, localPath: localURL.path, fileName: remoteItem.name), at: 0)
                self.markLatestTransfer(.done, "Opened for edit")
                self.status = "Editing \(remoteItem.name). Save in editor, then click Upload Edited."
                self.openFile(localURL, with: appURL)
            }
        }
    }

    private func openFile(_ fileURL: URL, with appURL: URL?) {
        if let appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    Task { @MainActor in
                        self.status = error.localizedDescription
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func cleanupEditSessions(_ sessions: [RemoteEditSession]) {
        for session in sessions {
            let fileURL = URL(fileURLWithPath: session.localPath)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
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

    private func runBusy(_ label: String, operation: @escaping @Sendable () async throws -> Void) {
        isBusy = true
        status = label
        Task {
            do {
                try await operation()
            } catch {
                markLatestTransfer(.failed, error.localizedDescription)
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func enqueue(direction: TransferDirection, source: String, destination: String) {
        transfers.insert(TransferJob(direction: direction, source: source, destination: destination, state: .running), at: 0)
        showsTransfers = true
    }

    private func markLatestTransfer(_ state: TransferState, _ message: String) {
        guard !transfers.isEmpty else { return }
        transfers[0].state = state
        transfers[0].message = message
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

    private func remoteParentPath(_ path: String) -> String? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func loadConnections() {
        connections = SecureStorage.load()
    }

    private func saveConnections() {
        SecureStorage.save(connections)
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
        return nil
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
            selectedLocalID: selectedLocalID,
            selectedRemoteID: selectedRemoteID,
            remoteEditSessions: remoteEditSessions,
            isConnected: isConnected,
            showsConnectionEditor: showsConnectionEditor,
            showsInspector: showsInspector
        )
    }

    private func remoteCacheKey(connectionID: UUID, path: String) -> String {
        "\(connectionID.uuidString):\(path)"
    }

    private func syncCurrentTab() {
        guard !isRestoringTab, let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs[index].connectionID = selectedConnectionID
        tabs[index].connectionDraft = connectionDraft
        tabPasswords[selectedTabID] = connectionPassword
        tabs[index].localPath = localPath
        tabs[index].remotePath = remotePath
        tabs[index].localItems = localItems
        tabs[index].remoteItems = remoteItems
        tabs[index].selectedLocalID = selectedLocalID
        tabs[index].selectedRemoteID = selectedRemoteID
        tabs[index].remoteEditSessions = remoteEditSessions
        tabs[index].isConnected = isConnected
        tabs[index].showsConnectionEditor = showsConnectionEditor
        tabs[index].showsInspector = showsInspector
        if let connection = selectedConnection {
            tabs[index].title = connection.name
        } else {
            tabs[index].title = URL(fileURLWithPath: localPath).lastPathComponent.isEmpty ? "Local" : URL(fileURLWithPath: localPath).lastPathComponent
        }
    }

    private func restoreCurrentTab() {
        guard let tab = selectedTab else { return }
        isRestoringTab = true
        isSuppressingSidebarSelection = true
        selectedConnectionID = tab.connectionID
        connectionDraft = tab.connectionDraft
        connectionPassword = tabPasswords[tab.id] ?? ""
        localPath = tab.localPath
        remotePath = tab.remotePath
        localItems = tab.localItems
        remoteItems = tab.remoteItems
        selectedLocalID = tab.selectedLocalID
        selectedRemoteID = tab.selectedRemoteID
        remoteEditSessions = tab.remoteEditSessions
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

    private func itemSort(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func joinRemote(_ base: String, _ child: String) -> String {
        if base == "/" { return "/" + child }
        return "/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + child
    }

    // MARK: - Host Key Verification

    private func verifyHostKey(for connection: SavedConnection) async throws {
        let host = connection.host
        let port = connection.port
        let lookupHost = port == 22 ? host : "[\(host)]:\(port)"
        let verificationKey = "\(connection.id.uuidString):\(lookupHost)"
        if verifiedHosts.contains(verificationKey) { return }

        let probe = try await sftp.probeHostKey(connection: connection)
        if probe.trustStatus == VOLT_HOSTKEY_MATCH {
            verifiedHosts.insert(verificationKey)
            return
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
        verifiedHosts.insert(verificationKey)
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

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                SessionTabBar(model: model)
                if model.selectedConnection == nil || model.showsConnectionEditor {
                    ConnectionEditor(model: model)
                    Divider()
                } else {
                    ConnectionSummaryView(model: model)
                    Divider()
                }
                BrowserSplitView(model: model)
                Divider()
                RemoteEditSessionsView(model: model)
                TransferQueueView(model: model)
                StatusBar(model: model)
            }
        }
        .inspector(isPresented: $model.showsInspector) {
            InspectorView(model: model)
        }
        .sheet(isPresented: $model.showsPasswordPrompt) {
            PasswordPromptView(model: model)
        }
        .sheet(isPresented: $model.showsHostKeyPrompt) {
            HostKeyVerificationView(model: model)
        }
        .frame(minWidth: 1120, minHeight: 720)
    }
}

struct SessionTabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.tabs) { tab in
                Button {
                    model.selectTab(tab.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.isConnected ? "bolt.horizontal.fill" : "folder")
                        Text(tab.title)
                            .lineLimit(1)
                        if model.tabs.count > 1 {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .onTapGesture {
                                    model.closeTab(tab.id)
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 180)
                    .background(model.selectedTabID == tab.id ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Button(action: model.newTab) {
                Image(systemName: "plus")
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("New tab")
            Spacer()
            Button(action: { model.showsInspector.toggle() }) {
                Image(systemName: model.showsInspector ? "info.circle.fill" : "info.circle")
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Toggle Inspector")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
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

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedConnectionID) {
                ForEach(model.connections) { connection in
                    Label(connection.name, systemImage: "externaldrive.connected.to.line.below")
                        .tag(connection.id)
                        .contextMenu {
                            Button("Edit") { model.editConnection(connection) }
                            Button("Disconnect") { model.disconnectConnection(id: connection.id) }
                                .disabled(model.selectedConnectionID != connection.id)
                            Divider()
                            Button("Remove") { model.removeConnection(id: connection.id) }
                        }
                }
            }
            .onChange(of: model.selectedConnectionID) { _, id in
                model.sidebarSelectionChanged(id)
            }

            HStack {
                Button(action: model.newConnection) { Image(systemName: "plus") }
                    .help("New connection")
                Button(action: model.deleteSelectedConnection) { Image(systemName: "trash") }
                    .help("Delete connection")
                    .disabled(model.selectedConnectionID == nil)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

struct ConnectionEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                TextField("Name", text: $model.connectionDraft.name)
                TextField("Host", text: $model.connectionDraft.host)
                TextField("User", text: $model.connectionDraft.username)
                TextField("Port", value: $model.connectionDraft.port, format: .number)
                    .frame(width: 70)
                Picker("Protocol", selection: $model.connectionDraft.protocolKind) {
                    ForEach(ProtocolKind.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                if model.selectedConnection != nil {
                    Button(action: model.hideConnectionEditor) { Label("Cancel", systemImage: "xmark.circle") }
                }
                Button(action: model.saveDraft) { Label("Save", systemImage: "tray.and.arrow.down") }
                Button(action: model.connectDraft) { Label("Connect", systemImage: "bolt.horizontal") }
                    .disabled(model.connectionDraft.host.isEmpty)
            }
            GridRow {
                SecureField("Password or key passphrase (not saved)", text: $model.connectionPassword)
                    .gridCellColumns(2)
                HStack(spacing: 6) {
                    TextField("Private key", text: $model.connectionDraft.privateKeyPath)
                        .disabled(true)
                    Button(action: model.choosePrivateKey) {
                        Image(systemName: "key.horizontal")
                    }
                    .help("Choose SSH private key")
                }
                    .gridCellColumns(3)
                TextField("Remote start path", text: $model.connectionDraft.remotePath)
                EmptyView()
            }
            GridRow {
                Text("Remote permissions")
                    .foregroundStyle(.secondary)
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
                .gridCellColumns(4)
                EmptyView()
                EmptyView()
            }
        }
        .padding(12)
    }
}

struct PasswordPromptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to \(model.connectionDraft.name)")
                .font(.headline)
            Text("Enter the server password. Volt keeps it only in this tab's memory and never saves it to Keychain or UserDefaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $model.connectionPassword)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelPasswordPrompt()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.connectWithPassword()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
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

    var body: some View {
        HSplitView {
            FilePane(
                title: "Local",
                path: $model.localPath,
                items: model.localItems,
                selection: $model.selectedLocalID,
                toolbar: {
                    Button(action: model.chooseLocalFolder) { Image(systemName: "folder") }.help("Choose folder")
                    Button(action: model.localUp) { Image(systemName: "arrow.up") }.help("Parent folder")
                    Button(action: model.refreshLocal) { Image(systemName: "arrow.clockwise") }.help("Refresh")
                    Button(action: model.makeLocalFolder) { Image(systemName: "folder.badge.plus") }.help("New folder")
                    Button(action: model.uploadSelected) { Image(systemName: "arrow.right.circle") }.help("Upload")
                        .disabled(model.selectedLocal == nil || model.selectedConnection == nil)
                    Button(action: model.editLocalSelected) { Image(systemName: "pencil") }.help("Edit file")
                        .disabled(model.selectedLocal?.isDirectory != false)
                    Menu {
                        Button("New File", action: model.makeLocalFile)
                        Button("Open With...", action: model.openLocalSelectedWithApp)
                            .disabled(model.selectedLocal?.isDirectory != false)
                        Button("Rename", action: model.renameLocalSelected)
                            .disabled(model.selectedLocal == nil)
                        Button("Delete", action: model.deleteLocalSelected)
                            .disabled(model.selectedLocal == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("More local actions")
                },
                open: model.openLocal,
                contextMenu: { item in
                    let name = item.name
                    Button("Upload \"\(name)\"") {
                        model.selectedLocalID = item.id
                        model.uploadSelected()
                    }
                    .disabled(model.selectedConnection == nil)
                    Button("Get Info") {
                        model.selectedLocalID = item.id
                        model.getInfoLocalSelected()
                    }
                    Divider()
                    Button("Open") {
                        model.selectedLocalID = item.id
                        model.editLocalSelected()
                    }
                    .disabled(item.isDirectory)
                    Button("Open With...") {
                        model.selectedLocalID = item.id
                        model.openLocalSelectedWithApp()
                    }
                    .disabled(item.isDirectory)
                    Button("Copy Path") {
                        model.selectedLocalID = item.id
                        model.copyLocalPath()
                    }
                    Divider()
                    Button("Delete...") {
                        model.selectedLocalID = item.id
                        model.deleteLocalSelected()
                    }
                    Button("Move...") {
                        model.selectedLocalID = item.id
                        model.moveLocalSelected()
                    }
                    Button("Duplicate") {
                        model.selectedLocalID = item.id
                        model.duplicateLocalSelected()
                    }
                    Button("Rename") {
                        model.selectedLocalID = item.id
                        model.renameLocalSelected()
                    }
                    Divider()
                    Button("New Folder") { model.makeLocalFolder() }
                    Button("New File") { model.makeLocalFile() }
                    Button("Refresh") { model.refreshLocal() }
                    if item.isDirectory {
                        Divider()
                        Button("Open in New Tab") {
                            model.selectedLocalID = item.id
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
            FilePane(
                title: "Remote",
                path: $model.remotePath,
                items: model.remoteItems,
                selection: $model.selectedRemoteID,
                toolbar: {
                    Button(action: model.remoteUp) { Image(systemName: "arrow.up") }.help("Parent folder")
                    Button(action: model.refreshRemote) { Image(systemName: "arrow.clockwise") }.help("Refresh")
                    Button(action: model.makeRemoteFolder) { Image(systemName: "folder.badge.plus") }.help("New folder")
                    Button(action: model.uploadFromPicker) { Image(systemName: "square.and.arrow.up") }.help("Upload files or folders")
                        .disabled(model.selectedConnection == nil)
                    Button(action: model.downloadSelected) { Image(systemName: "arrow.left.circle") }.help("Download")
                        .disabled(model.selectedRemote == nil)
                    Button(action: model.editRemoteSelected) { Image(systemName: "pencil") }.help("Edit remote file")
                        .disabled(model.selectedRemote?.isDirectory != false)
                    Menu {
                        Button("Download To...", action: model.downloadSelectedToFolder)
                            .disabled(model.selectedRemote == nil)
                        Button("Open With...", action: model.openRemoteSelectedWithApp)
                            .disabled(model.selectedRemote?.isDirectory != false)
                        Button("New File", action: model.makeRemoteFile)
                            .disabled(model.selectedConnection == nil)
                        Button("Rename", action: model.renameRemoteSelected)
                            .disabled(model.selectedRemote == nil)
                        Button("Delete", action: model.deleteRemoteSelected)
                            .disabled(model.selectedRemote == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("More remote actions")
                },
                open: model.openRemote,
                contextMenu: { item in
                    let name = item.name
                    Button("Download \"\(name)\"") {
                        model.selectedRemoteID = item.id
                        model.downloadSelected()
                    }
                    Button("Download To...") {
                        model.selectedRemoteID = item.id
                        model.downloadSelectedToFolder()
                    }
                    Button("Get Info") {
                        model.selectedRemoteID = item.id
                        model.getInfoRemoteSelected()
                    }
                    Divider()
                    Button("Open") {
                        model.selectedRemoteID = item.id
                        model.editRemoteSelected()
                    }
                    .disabled(item.isDirectory)
                    Button("Open With...") {
                        model.selectedRemoteID = item.id
                        model.openRemoteSelectedWithApp()
                    }
                    .disabled(item.isDirectory)
                    Button("Copy Path") {
                        model.selectedRemoteID = item.id
                        model.copyRemotePath()
                    }
                    Divider()
                    Button("Delete...") {
                        model.selectedRemoteID = item.id
                        model.deleteRemoteSelected()
                    }
                    Button("Move...") {
                        model.selectedRemoteID = item.id
                        model.moveRemoteSelected()
                    }
                    Button("Duplicate") {
                        model.selectedRemoteID = item.id
                        model.duplicateRemoteSelected()
                    }
                    Button("Rename") {
                        model.selectedRemoteID = item.id
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
                            model.selectedRemoteID = item.id
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
}

struct FilePane<ToolbarContent: View, ContextMenuContent: View, BackgroundContextMenuContent: View>: View {
    var title: String
    @Binding var path: String
    var items: [FileItem]
    @Binding var selection: FileItem.ID?
    @ViewBuilder var toolbar: () -> ToolbarContent
    var open: (FileItem) -> Void
    @ViewBuilder var contextMenu: (FileItem) -> ContextMenuContent
    @ViewBuilder var backgroundContextMenu: () -> BackgroundContextMenuContent

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .frame(width: 70, alignment: .leading)
                TextField("Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                toolbar()
                    .buttonStyle(.borderless)
                    .controlSize(.large)
            }
            .padding(10)

            HStack {
                Text("Name")
                    .font(.headline)
                Spacer()
                Text("Size")
                    .font(.headline)
                    .frame(width: 140, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        FileRow(
                            item: item,
                            isSelected: selection == item.id,
                            isStriped: index.isMultiple(of: 2),
                            selection: $selection,
                            open: open,
                            contextMenu: contextMenu
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color.clear)
            .contentShape(Rectangle())
            .contextMenu { backgroundContextMenu() }
            .onTapGesture {
                selection = nil
            }
        }
        .frame(minWidth: 300)
    }
}

struct FileRow<ContextMenuContent: View>: View {
    var item: FileItem
    var isSelected: Bool
    var isStriped: Bool
    @Binding var selection: FileItem.ID?
    var open: (FileItem) -> Void
    @ViewBuilder var contextMenu: (FileItem) -> ContextMenuContent

    var body: some View {
        HStack(spacing: 12) {
            Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                .lineLimit(1)
            Spacer()
            Text(item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
        }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selectionBackground)
            .background {
                RightClickSelectionView {
                    selection = item.id
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selection = item.id
                open(item)
            }
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        selection = item.id
                    }
            )
            .contextMenu {
                contextMenu(item)
            }
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor : (isStriped ? Color.primary.opacity(0.06) : Color.clear))
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

private final class RightClickTrackingView: NSView {
    var onRightClick: (() -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitor()
        guard window != nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.onRightClick?()
            return event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeEventMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

struct TransferQueueView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.showsTransfers {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Transfers")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.showsTransfers = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Table(model.transfers) {
                    TableColumn("Direction") { Text($0.direction.rawValue) }.width(90)
                    TableColumn("Source") { Text($0.source).lineLimit(1) }
                    TableColumn("Destination") { Text($0.destination).lineLimit(1) }
                    TableColumn("State") { Text($0.state.rawValue) }.width(80)
                    TableColumn("Message") { Text($0.message).lineLimit(1) }
                }
                .frame(height: 140)
            }
            .padding(10)
        }
    }
}

struct RemoteEditSessionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.remoteEditSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Edits")
                    .font(.headline)
                Table(model.remoteEditSessions) {
                    TableColumn("File") { session in
                        Text(session.fileName)
                            .lineLimit(1)
                    }
                    TableColumn("Remote Path") { session in
                        Text(session.remotePath)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Action") { session in
                        Button("Upload Edited") {
                            model.uploadEditedRemoteFile(session)
                        }
                    }
                    .width(130)
                }
                .frame(height: 90)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
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
        .windowStyle(.titleBar)
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
