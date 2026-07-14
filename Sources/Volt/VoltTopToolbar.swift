import SwiftUI

struct VoltTopToolbar: View {
    @ObservedObject var model: AppModel
    var layout: AppLayoutContext
    @Binding var showsSidebar: Bool
    @Binding var searchText: String
    @Binding var appAppearance: AppAppearance

    var body: some View {
        HStack(spacing: 12) {
            sidebarToggle
            connectionMenu
            Divider().frame(height: 28)
            navigationControls
            Divider().frame(height: 28)
            transferControls
            Spacer(minLength: 12)
            if layout.toolbarDensity == .expanded {
                searchField
            }
            appearanceToggle
            viewControls
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 48)
        .clipped()
        .background(VoltTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(height: 1)
        }
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                showsSidebar.toggle()
            }
        } label: {
                Image(systemName: "sidebar.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(showsSidebar ? "Hide Sidebar" : "Show Sidebar")
    }

    private var connectionMenu: some View {
        Menu {
            Button("New Connection", action: model.newConnection)
            Divider()
            ForEach(model.connections) { connection in
                Button {
                    model.select(connection)
                } label: {
                    Label(connection.name, systemImage: model.selectedConnectionID == connection.id ? "checkmark.circle.fill" : "server.rack")
                }
            }
            if model.selectedConnection != nil {
                Divider()
                Button("Edit Current", action: model.showConnectionEditor)
                Button("Disconnect", action: { model.disconnectConnection() })
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.gray.opacity(0.55))
                    .frame(width: 10, height: 10)
                Text(model.selectedConnection?.name ?? "No Server")
                    .lineLimit(1)
                    .frame(maxWidth: layout.toolbarDensity == .expanded ? 150 : 92, alignment: .leading)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(VoltTheme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(VoltTheme.hairline)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose server")
    }

    private var navigationControls: some View {
        HStack(spacing: 6) {
            toolbarButton("arrow.left", help: "Local parent folder", action: model.localUp)
            toolbarButton("arrow.right", help: "Remote parent folder", action: model.remoteUp)
                .disabled(!model.isConnected)
            toolbarButton("arrow.clockwise", help: "Refresh") {
                model.refreshLocal()
                if model.isConnected { model.refreshRemote() }
            }
        }
    }

    private var transferControls: some View {
        HStack(alignment: .center, spacing: 15) {
            HStack(alignment: .center, spacing: 14) {
                Button(action: model.uploadFromPicker) {
                    commandLabel("Upload", systemImage: "arrow.up.to.line")
                }
                .frame(height: 30)

                Menu {
                    Button("Download Selected", action: model.downloadSelected)
                        .disabled(model.selectedRemote == nil)
                    Button("Download To...", action: model.downloadSelectedToFolder)
                        .disabled(model.selectedRemote == nil)
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        commandLabel("Download", systemImage: "arrow.down.to.line")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(VoltTheme.mutedText)
                            .frame(width: 10, height: 18)
                    }
                    .frame(height: 30)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            if layout.toolbarDensity != .minimal {
                Divider()
                    .frame(height: 24)
            }

            if layout.toolbarDensity != .minimal {
                HStack(alignment: .center, spacing: 13) {
                    toolbarIconButton("folder.badge.plus", help: "New folder") {
                        if model.isConnected {
                            model.makeRemoteFolder()
                        } else {
                            model.makeLocalFolder()
                        }
                    }
                    toolbarIconButton("terminal", help: "Open SSH terminal") {
                        model.showTerminal()
                    }
                    .disabled(model.selectedConnection == nil)
                    toolbarIconButton("trash", help: "Delete selected item") {
                        if model.selectedRemote != nil {
                            model.deleteRemoteSelected()
                        } else {
                            model.deleteLocalSelected()
                        }
                    }
                    .disabled(model.selectedRemote == nil && model.selectedLocal == nil)
                }
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(VoltTheme.mutedText)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 120, idealWidth: 170, maxWidth: 220)
                .lineLimit(1)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(VoltTheme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(VoltTheme.hairline)
        )
        .layoutPriority(-1)
    }

    private var viewControls: some View {
        HStack(spacing: 6) {
            toolbarButton(model.showsInspector ? "info.circle.fill" : "info.circle", help: "Toggle Inspector") {
                model.showsInspector.toggle()
            }
            if layout.toolbarDensity == .expanded {
                toolbarButton("list.bullet", help: "List view") {
                    model.localBrowserPreferences.viewMode = .list
                    model.remoteBrowserPreferences.viewMode = .list
                }
                toolbarButton("square.grid.2x2", help: "Icon view") {
                    model.localBrowserPreferences.viewMode = .icons
                    model.remoteBrowserPreferences.viewMode = .icons
                }
            } else {
                Menu {
                    Button("List View") {
                        model.localBrowserPreferences.viewMode = .list
                        model.remoteBrowserPreferences.viewMode = .list
                    }
                    Button("Icon View") {
                        model.localBrowserPreferences.viewMode = .icons
                        model.remoteBrowserPreferences.viewMode = .icons
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .help("More view options")
            }
        }
    }

    private var appearanceToggle: some View {
        Button {
            appAppearance.toggle()
        } label: {
            Image(systemName: appAppearance == .light ? "moon" : "sun.max")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(appAppearance == .light ? "Switch to Dark Mode" : "Switch to Light Mode")
    }

    private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toolbarIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func commandLabel(_ title: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 19, height: 18)
            if layout.toolbarDensity == .expanded {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: 30, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}
