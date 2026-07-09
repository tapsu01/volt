import AppKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

enum ProtocolKind: String, Codable, CaseIterable, Identifiable {
    case sftp = "SFTP"

    var id: String { rawValue }
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
            "Password login is not supported by the bundled SFTP runner. Use SSH key or agent authentication."
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
    private static let key = "connections"

    static func save(_ connections: [SavedConnection]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [SavedConnection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let connections = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return []
        }
        return connections
    }

    static func migrateFromUserDefaults() {
        // No longer needed
    }
}

final class SFTPClient: @unchecked Sendable {
    private let runner = CommandRunner()
    private let executable = "/usr/bin/sftp"

    func list(connection: SavedConnection, password: String, path: String) async throws -> [FileItem] {
        try await Task.detached {
            let output = try self.batch(connection: connection, password: password, commands: ["cd \(self.quote(path))", "ls -la"])
            return self.parseListing(output.stdout, basePath: path)
        }.value
    }

    func upload(connection: SavedConnection, password: String, localPath: String, remotePath: String) async throws {
        try await Task.detached {
            let output = try self.batch(connection: connection, password: password, commands: ["put -r \(self.quote(localPath)) \(self.quote(remotePath))"])
            guard output.status == 0 else { throw AppError.commandFailed(output.stderr + output.stdout) }
        }.value
    }

    func download(connection: SavedConnection, password: String, remotePath: String, localPath: String) async throws {
        try await Task.detached {
            let output = try self.batch(connection: connection, password: password, commands: ["get -r \(self.quote(remotePath)) \(self.quote(localPath))"])
            guard output.status == 0 else { throw AppError.commandFailed(output.stderr + output.stdout) }
        }.value
    }

    func makeDirectory(connection: SavedConnection, password: String, path: String) async throws {
        try await Task.detached {
            let output = try self.batch(connection: connection, password: password, commands: ["mkdir \(self.quote(path))"])
            guard output.status == 0 else { throw AppError.commandFailed(output.stderr + output.stdout) }
        }.value
    }

    func createFile(connection: SavedConnection, password: String, remotePath: String) async throws {
        try await Task.detached {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Volt-\(UUID().uuidString)")
            try Data().write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let output = try self.batch(connection: connection, password: password, commands: ["put \(self.quote(tempURL.path)) \(self.quote(remotePath))"])
            guard output.status == 0 else { throw AppError.commandFailed(output.stderr + output.stdout) }
        }.value
    }

    func rename(connection: SavedConnection, password: String, from: String, to: String) async throws {
        try await Task.detached {
            let output = try self.batch(connection: connection, password: password, commands: ["rename \(self.quote(from)) \(self.quote(to))"])
            guard output.status == 0 else { throw AppError.commandFailed(output.stderr + output.stdout) }
        }.value
    }

    func remove(connection: SavedConnection, password: String, path: String, isDirectory: Bool) async throws {
        try await Task.detached {
            let command = isDirectory ? "rmdir \(self.quote(path))" : "rm \(self.quote(path))"
            let output = try self.batch(connection: connection, password: password, commands: [command])
            guard output.status == 0 else { throw AppError.commandFailed(output.stderr + output.stdout) }
        }.value
    }

    static func controlSocketDir() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let controlDir = home.appendingPathComponent(".ssh/volt_control", isDirectory: true)
        if !FileManager.default.fileExists(atPath: controlDir.path) {
            try FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDir.path)
        }
        return controlDir.path
    }

    private func batch(connection: SavedConnection, password: String, commands: [String]) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AppError.commandFailed("OpenSSH SFTP was not found at \(executable).")
        }

        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        let controlDir = try SFTPClient.controlSocketDir()
        var args = [
            "-oBatchMode=\(trimmedPassword.isEmpty ? "yes" : "no")",
            "-oStrictHostKeyChecking=yes",
            "-oControlMaster=auto",
            "-oControlPath=\(controlDir)/volt_%h_%p_%r",
            "-oControlPersist=5m",
            "-P", "\(connection.port)"
        ]
        if !connection.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-i", connection.privateKeyPath])
        }
        args.append("\(connection.username)@\(connection.host)")

        let script = commands.joined(separator: "\n") + "\nbye\n"
        let askpass = try makeAskPassScript(password: trimmedPassword)
        defer {
            if let askpass {
                try? FileManager.default.removeItem(at: askpass.deletingLastPathComponent())
            }
        }

        var environment: [String: String] = [:]
        if let askpass {
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "Volt"
            environment["VOLT_SSH_PASS"] = trimmedPassword
        }

        let result = try runner.run(executable, arguments: args, stdin: script, environment: environment)
        guard result.status == 0 else { throw AppError.commandFailed(result.stderr + result.stdout) }
        return result
    }

    func makeAskPassScript(password: String) throws -> URL? {
        guard !password.isEmpty else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Volt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("askpass.sh")
        // Security: Password is passed via VOLT_SSH_PASS env var, never written to disk
        let script = "#!/bin/sh\nprintf '%s\\n' \"$VOLT_SSH_PASS\"\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func parseListing(_ text: String, basePath: String) -> [FileItem] {
        text.split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("sftp>") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard line.count > 10, line.first == "-" || line.first == "d" || line.first == "l" else { return nil }
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard parts.count >= 9 else { return nil }
                let name = String(parts[8])
                guard name != "." && name != ".." else { return nil }
                let path = joinRemote(basePath, name)
                return FileItem(
                    name: name,
                    path: path,
                    isDirectory: parts[0].first == "d",
                    size: Int64(parts[4]),
                    modified: nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func joinRemote(_ base: String, _ child: String) -> String {
        if base == "/" { return "/" + child }
        return "/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + child
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
    @Published var showsGetInfo = false
    @Published var infoItem: FileItem?
    @Published var pendingHostKeyFingerprint = ""
    @Published var pendingHostKeyHost = ""
    private var hostKeyConfirmationContinuation: CheckedContinuation<Bool, Never>?
    private var tabPasswords: [BrowserTab.ID: String] = [:]

    private let sftp = SFTPClient()
    private var isRestoringTab = false
    private var isSuppressingSidebarSelection = false
    private var isSelectingConnection = false

    init() {
        selectedTabID = tabs.first?.id
        SecureStorage.migrateFromUserDefaults()
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
            
            do {
                let askpass = try sftp.makeAskPassScript(password: trimmedPassword)
                let controlDir = try SFTPClient.controlSocketDir()
                defer {
                    if let askpass {
                        try? FileManager.default.removeItem(at: askpass.deletingLastPathComponent())
                    }
                }

                var args = [
                    "-oBatchMode=\(trimmedPassword.isEmpty ? "yes" : "no")",
                    "-oStrictHostKeyChecking=yes",
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

                var environment: [String: String] = [:]
                if let askpass {
                    environment["SSH_ASKPASS"] = askpass.path
                    environment["SSH_ASKPASS_REQUIRE"] = "force"
                    environment["DISPLAY"] = "Volt"
                    environment["VOLT_SSH_PASS"] = trimmedPassword
                }

                let result = try runner.run(executable, arguments: args, stdin: "", environment: environment)
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
        isSelectingConnection = true
        defer { isSelectingConnection = false }

        selectedConnectionID = connection.id
        connectionDraft = connection
        connectionPassword = ""
        remotePath = connection.remotePath
        isConnected = false
        showsConnectionEditor = false
        showsPasswordPrompt = true
        syncCurrentTab()
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

    func connectWithPassword() {
        showsPasswordPrompt = false
        remotePath = connectionDraft.remotePath.isEmpty ? "/" : connectionDraft.remotePath
        showsConnectionEditor = false
        syncCurrentTab()
        refreshRemote()
    }

    func cancelPasswordPrompt() {
        showsPasswordPrompt = false
        connectionPassword = ""
    }

    func sidebarSelectionChanged(_ id: UUID?) {
        guard !isSuppressingSidebarSelection else { return }
        guard let id, let connection = connections.first(where: { $0.id == id }) else { return }
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
            status = "Disconnected"
            syncCurrentTab()
        }
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
        guard let connection = selectedConnection else { status = "Choose a connection"; return }
        let path = remotePath
        let password = connectionPassword
        runBusy("Loading remote folder") {
            try await self.verifyHostKey(for: connection)
            let items = try await self.sftp.list(connection: connection, password: password, path: path)
            await MainActor.run {
                self.remoteItems = items
                self.isConnected = true
                self.showsConnectionEditor = false
                self.status = "Remote folder loaded"
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
        upload(localPath: session.localPath, remotePath: session.remotePath, refreshWhenDone: true)
        remoteEditSessions.removeAll { $0.id == session.id }
    }

    private func upload(localPath: String, remotePath: String, refreshWhenDone: Bool) {
        guard let connection = selectedConnection else { return }
        let password = connectionPassword
        enqueue(direction: .upload, source: localPath, destination: remotePath)
        runBusy("Uploading") {
            try await self.sftp.upload(connection: connection, password: password, localPath: localPath, remotePath: remotePath)
            await MainActor.run {
                self.markLatestTransfer(.done, "Uploaded")
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
            try await self.sftp.makeDirectory(connection: connection, password: password, path: path)
            await MainActor.run { self.refreshRemote() }
        }
    }

    func makeRemoteFile() {
        guard let connection = selectedConnection else { return }
        let name = prompt("New Remote File", defaultValue: "untitled.txt", actionTitle: "Create")
        guard !name.isEmpty else { return }
        let path = joinRemote(remotePath, name)
        let password = connectionPassword
        runBusy("Creating file") {
            try await self.sftp.createFile(connection: connection, password: password, remotePath: path)
            await MainActor.run { self.refreshRemote() }
        }
    }

    // MARK: - Local Context Menu Actions

    func getInfoLocalSelected() {
        guard let item = selectedLocal else { return }
        infoItem = item
        showsGetInfo = true
    }

    func openInNewTabLocal() {
        guard let item = selectedLocal, item.isDirectory else { return }
        let newTab = BrowserTab(title: item.name, localPath: item.path, remotePath: remotePath)
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
        guard let item = selectedRemote else { return }
        infoItem = item
        showsGetInfo = true
    }

    func openInNewTabRemote() {
        guard let item = selectedRemote, item.isDirectory else { return }
        let newTab = BrowserTab(title: item.name, localPath: localPath, remotePath: item.path)
        tabs.append(newTab)
        tabPasswords[newTab.id] = connectionPassword
        selectTab(newTab.id)
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
            let controlDir = try SFTPClient.controlSocketDir()
            var args = [
                "-oBatchMode=\(trimmedPassword.isEmpty ? "yes" : "no")",
                "-oStrictHostKeyChecking=yes",
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

            var environment: [String: String] = [:]
            let askpass = try self.sftp.makeAskPassScript(password: trimmedPassword)
            defer {
                if let askpass {
                    try? FileManager.default.removeItem(at: askpass.deletingLastPathComponent())
                }
            }
            if let askpass {
                environment["SSH_ASKPASS"] = askpass.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = "Volt"
                environment["VOLT_SSH_PASS"] = trimmedPassword
            }

            _ = try runner.run(executable, arguments: args, stdin: "", environment: environment)
            
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoltEdits", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

        // Check if host is already in known_hosts
        let isKnown = try await Task.detached {
            let runner = CommandRunner()
            let result = try runner.run("/usr/bin/ssh-keygen", arguments: ["-F", host])
            return result.status == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.value

        if isKnown { return }

        // Scan for host key fingerprint
        let (hostKeys, fingerprint) = try await Task.detached {
            let runner = CommandRunner()
            let scanResult = try runner.run("/usr/bin/ssh-keyscan", arguments: ["-p", "\(port)", host])
            guard scanResult.status == 0,
                  !scanResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.commandFailed("Could not retrieve host key from \(host):\(port).")
            }

            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("volt_hostkey_\(UUID().uuidString)")
            try scanResult.stdout.write(to: tempFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let fpResult = try runner.run("/usr/bin/ssh-keygen", arguments: ["-lf", tempFile.path])
            return (scanResult.stdout, fpResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value

        // Show host key fingerprint dialog and wait for user confirmation
        let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pendingHostKeyFingerprint = fingerprint
            self.pendingHostKeyHost = "\(host):\(port)"
            self.hostKeyConfirmationContinuation = continuation
            self.showsHostKeyPrompt = true
        }

        guard confirmed else {
            throw AppError.hostKeyRejected
        }

        // Add key to known_hosts
        try await Task.detached {
            let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            if !FileManager.default.fileExists(atPath: sshDir.path) {
                try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
            }
            let knownHostsURL = sshDir.appendingPathComponent("known_hosts")
            if FileManager.default.fileExists(atPath: knownHostsURL.path) {
                let handle = try FileHandle(forWritingTo: knownHostsURL)
                handle.seekToEndOfFile()
                handle.write(Data(hostKeys.utf8))
                try handle.close()
            } else {
                try hostKeys.write(to: knownHostsURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: knownHostsURL.path)
            }
        }.value
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
        .sheet(isPresented: $model.showsGetInfo) {
            GetInfoView(item: model.infoItem, isPresented: $model.showsGetInfo)
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

struct PasswordPromptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Connect to \(model.connectionDraft.name.isEmpty ? model.connectionDraft.host : model.connectionDraft.name)")
                .font(.headline)

            Text("\(model.connectionDraft.username)@\(model.connectionDraft.host):\(model.connectionDraft.port)")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $model.connectionPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    model.connectWithPassword()
                }

            Text("Leave empty to use SSH key / agent authentication")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
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
        .padding(24)
        .frame(width: 360)
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

struct GetInfoView: View {
    let item: FileItem?
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(item?.name ?? "Info")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            if let item = item {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("Kind:").foregroundStyle(.secondary)
                        Text(item.isDirectory ? "Folder" : "File")
                    }
                    GridRow {
                        Text("Size:").foregroundStyle(.secondary)
                        Text(item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                    }
                    GridRow {
                        Text("Where:").foregroundStyle(.secondary)
                        Text(item.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    GridRow {
                        Text("Modified:").foregroundStyle(.secondary)
                        if let mod = item.modified {
                            Text(mod.formatted(date: .abbreviated, time: .shortened))
                        } else {
                            Text("--")
                        }
                    }
                }
            } else {
                Text("No item selected.")
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 400, height: 250)
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
                SecureField("Password (leave empty for SSH key/agent auth)", text: $model.connectionPassword)
                    .gridCellColumns(2)
                TextField("Private key path", text: $model.connectionDraft.privateKeyPath)
                    .gridCellColumns(3)
                TextField("Remote start path", text: $model.connectionDraft.remotePath)
                EmptyView()
            }
        }
        .padding(12)
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
            nsImage = NSWorkspace.shared.icon(forFileType: "public.folder")
        } else {
            let ext = (item.name as NSString).pathExtension
            nsImage = ext.isEmpty ? NSWorkspace.shared.icon(forFileType: "public.data") : NSWorkspace.shared.icon(forFileType: ext)
        }
        return Image(nsImage: nsImage)
    }
}

@main
struct VoltApp: App {
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
