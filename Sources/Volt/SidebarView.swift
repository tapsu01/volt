import Foundation
import AppKit
import SwiftUI

struct SidebarBrandHeader: View {
    var layout: AppLayoutContext

    var body: some View {
        Group {
            if layout.sidebarMode == .iconOnly {
                Color.clear
            } else {
                HStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Volt")
                        .font(.system(size: 18, weight: .bold))
                    Spacer(minLength: 12)
                }
                .padding(.leading, VoltWindowChrome.trafficLightSafeInset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: VoltWindowChrome.toolbarHeight, maxHeight: VoltWindowChrome.toolbarHeight)
        .background(VoltTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(height: 1)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var layout: AppLayoutContext

    var body: some View {
        Group {
            if layout.sidebarMode == .iconOnly {
                iconOnlyBody
            } else {
                fullBody
            }
        }
        .background(VoltTheme.sidebarBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarSection("FAVORITES") {
                        favoriteRow("My Mac", systemImage: "display", path: FileManager.default.homeDirectoryForCurrentUser.path)
                        favoriteRow("Desktop", systemImage: "macwindow", path: desktopPath)
                        favoriteRow("Downloads", systemImage: "arrow.down.app.fill", path: downloadsPath)
                        favoriteRow("Documents", systemImage: "doc.fill", path: documentsPath)
                        favoriteRow("Projects", systemImage: "folder.fill", path: projectsPath)
                    }

                    sidebarSection("SERVERS", trailing: {
                        Button(action: model.newConnection) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("New connection")
                    }) {
                        if model.connections.isEmpty {
                            Button(action: model.newConnection) {
                                Label("Add Server", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        } else {
                            ForEach(model.connections) { connection in
                                serverRow(connection)
                            }
                        }
                    }

                    sidebarSection("RECENT") {
                        recentRow(title: URL(fileURLWithPath: model.localPath).lastPathComponent.isEmpty ? model.localPath : URL(fileURLWithPath: model.localPath).lastPathComponent, subtitle: model.localPath, systemImage: "folder.fill")
                        if model.isConnected {
                            recentRow(title: model.remotePath == "/" ? "/" : URL(fileURLWithPath: model.remotePath).lastPathComponent, subtitle: model.remotePath, systemImage: "externaldrive.fill")
                        }
                        ForEach(Array(model.transfers.prefix(3))) { transfer in
                            recentRow(title: URL(fileURLWithPath: transfer.destination).lastPathComponent, subtitle: transfer.direction.rawValue, systemImage: transfer.direction == .upload ? "arrow.up.doc.fill" : "arrow.down.doc.fill")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .frame(width: layout.sidebarWidth, alignment: .leading)
            }
            Spacer(minLength: 0)

            HStack {
                Button(action: { model.showsTransfers.toggle() }) {
                    Image(systemName: "clock")
                        .frame(width: 30, height: 30)
                }
                .help("Transfers")

                Button(action: model.showConnectionEditor) {
                    Image(systemName: "gearshape")
                        .frame(width: 30, height: 30)
                }
                .help("Connection settings")

                Spacer()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: layout.sidebarWidth, alignment: .leading)
        }
    }

    private var iconOnlyBody: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 10) {
                    iconButton("display", help: "My Mac") {
                        model.localPath = FileManager.default.homeDirectoryForCurrentUser.path
                        model.selectedLocalIDs.removeAll()
                        model.refreshLocal()
                    }
                    iconButton("macwindow", help: "Desktop") {
                        model.localPath = desktopPath
                        model.selectedLocalIDs.removeAll()
                        model.refreshLocal()
                    }
                    iconButton("arrow.down.app.fill", help: "Downloads") {
                        model.localPath = downloadsPath
                        model.selectedLocalIDs.removeAll()
                        model.refreshLocal()
                    }
                    iconButton("doc.fill", help: "Documents") {
                        model.localPath = documentsPath
                        model.selectedLocalIDs.removeAll()
                        model.refreshLocal()
                    }

                    Divider()
                        .padding(.vertical, 4)

                    iconButton("plus", help: "New connection", action: model.newConnection)

                    ForEach(model.connections) { connection in
                        let isSelected = model.selectedConnectionID == connection.id
                        let isLive = model.isConnectionConnected(connection.id)
                        Button {
                            model.select(connection)
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 40, height: 34)
                                Circle()
                                    .fill(isLive ? Color.green : Color.gray.opacity(0.65))
                                    .frame(width: 8, height: 8)
                                    .offset(x: -6, y: -5)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isSelected ? VoltTheme.selectedFill : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(connection.name)
                    }
                }
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                iconButton("clock", help: "Transfers") {
                    model.showsTransfers.toggle()
                }
                iconButton("gearshape", help: "Connection settings", action: model.showConnectionEditor)
            }
            .padding(.bottom, 12)
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var desktopPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
    }

    private var downloadsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }

    private var documentsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
    }

    private var projectsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path
    }

    private func sidebarSection<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sidebarSection(title, trailing: { EmptyView() }, content: content)
    }

    private func favoriteRow(_ title: String, systemImage: String, path: String) -> some View {
        Button {
            model.localPath = path
            model.selectedLocalIDs.removeAll()
            model.refreshLocal()
        } label: {
            sidebarRowContent(title: title, subtitle: nil, systemImage: systemImage, tint: .accentColor)
        }
        .buttonStyle(.plain)
        .help(path)
    }

    private func serverRow(_ connection: SavedConnection) -> some View {
        let isSelected = model.selectedConnectionID == connection.id
        let isLive = model.isConnectionConnected(connection.id)
        return Button {
            model.select(connection)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(isLive ? Color.green : (isSelected ? Color.blue : Color.gray.opacity(0.55)))
                    .frame(width: 10, height: 10)
                Text(connection.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? VoltTheme.selectedFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { model.editConnection(connection) }
            Button("Disconnect") { model.disconnectConnection(id: connection.id) }
                .disabled(!isLive)
            Divider()
            Button("Remove") { model.removeConnection(id: connection.id) }
        }
    }

    private func recentRow(title: String, subtitle: String, systemImage: String) -> some View {
        sidebarRowContent(title: title, subtitle: subtitle, systemImage: systemImage, tint: .accentColor)
            .help(subtitle)
    }

    private func sidebarRowContent(title: String, subtitle: String?, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, subtitle == nil ? 7 : 5)
        .contentShape(Rectangle())
    }
}
