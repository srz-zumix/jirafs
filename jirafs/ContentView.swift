import SwiftUI
import AtlassianCore

/// Main window: a list of mounts on the left and a detail/control panel on the
/// right. Servers (connection + credentials) are managed in the Preferences
/// window; this window manages mounts (mount point + filters + options) that
/// reference those servers.
struct ContentView: View {
    @EnvironmentObject private var appStore: AppStoreModel
    @EnvironmentObject private var navigation: NavigationModel
    @Environment(\.openSettings) private var openSettings

    @State private var showingAddMount = false
    @State private var editingMount: Mount?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $appStore.selection) {
                    let jiraMounts = appStore.mounts.filter { $0.product == .jira }
                    let confluenceMounts = appStore.mounts.filter { $0.product == .confluence }
                    if !jiraMounts.isEmpty {
                        Section("JIRA") {
                            ForEach(jiraMounts) { mount in
                                mountRow(mount)
                                    .tag(mount.id)
                                    .contextMenu {
                                        Button("Edit…") { editingMount = mount }
                                        Button("Delete", role: .destructive) {
                                            appStore.deleteMount(mount)
                                            if appStore.selection == mount.id { appStore.selection = nil }
                                        }
                                    }
                            }
                        }
                    }
                    if !confluenceMounts.isEmpty {
                        Section("Confluence") {
                            ForEach(confluenceMounts) { mount in
                                mountRow(mount)
                                    .tag(mount.id)
                                    .contextMenu {
                                        Button("Edit…") { editingMount = mount }
                                        Button("Delete", role: .destructive) {
                                            appStore.deleteMount(mount)
                                            if appStore.selection == mount.id { appStore.selection = nil }
                                        }
                                    }
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddMount = true
                        } label: {
                            Label("Add Mount", systemImage: "plus")
                        }
                        .disabled(appStore.servers.isEmpty)
                        .help(appStore.servers.isEmpty
                              ? "Add a server in Preferences first"
                              : "Add a mount")
                    }
                }
                .navigationTitle("Mounts")

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        openSettings()
                    } label: {
                        Label("Preferences…", systemImage: "gearshape")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 250)
        } detail: {
            detailView
        }
        .sheet(isPresented: $showingAddMount) {
            MountEditorView(initial: nil, servers: appStore.servers) { mount in
                appStore.upsertMount(mount)
                appStore.selection = mount.id
                showingAddMount = false
            } onCancel: {
                showingAddMount = false
            }
        }
        .sheet(item: $editingMount) { mount in
            MountEditorView(initial: mount, servers: appStore.servers) { updated in
                appStore.upsertMount(updated)
                editingMount = nil
            } onCancel: {
                editingMount = nil
            }
        }
        .onAppear { appStore.reload() }
        .onReceive(navigation.$pendingSelection) { id in
            guard let id else { return }
            appStore.selection = id
            navigation.pendingSelection = nil
        }
    }

    @ViewBuilder
    private func mountRow(_ mount: Mount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mount.product == .jira ? "ladybug" : "doc.richtext")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(mount.name).font(.body)
                Text(serverHost(for: mount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func serverHost(for mount: Mount) -> String {
        guard let server = appStore.server(id: mount.serverID) else { return "Unknown server" }
        let host: String?
        switch mount.product {
        case .jira: host = server.jira?.url.host
        case .confluence: host = server.confluence?.url.host
        }
        return "\(server.name) · \(host ?? "—")"
    }

    @ViewBuilder
    private var detailView: some View {
        if let id = appStore.selection, let mount = appStore.mount(id: id) {
            MountDetailView(
                mount: mount,
                server: appStore.server(id: mount.serverID),
                onEdit: { editingMount = mount },
                onDelete: {
                    appStore.deleteMount(mount)
                    appStore.selection = nil
                },
                onAutoMountToggle: { newValue in
                    appStore.setAutoMount(newValue, for: mount)
                }
            )
            .id(mount.id)
        } else {
            ContentUnavailableView(
                appStore.servers.isEmpty ? "No Servers Configured" : "No Mount Selected",
                systemImage: "externaldrive",
                description: Text(appStore.servers.isEmpty
                    ? "Add a server in Preferences, then create a mount."
                    : "Add a mount to get started.")
            )
        }
    }
}

/// Detail panel for a single mount: connection summary (from its server), the
/// mount control, startup option, and cache management.
struct MountDetailView: View {
    let mount: Mount
    let server: Server?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAutoMountToggle: (Bool) -> Void

    @State private var showClearCacheConfirm = false
    @State private var clearCacheResult: String?

    private var host: String {
        switch mount.product {
        case .jira: return server?.jira?.url.host ?? server?.jira?.url.absoluteString ?? "—"
        case .confluence: return server?.confluence?.url.host ?? server?.confluence?.url.absoluteString ?? "—"
        }
    }

    private var edition: String {
        switch mount.product {
        case .jira: return server?.jira?.edition.rawValue ?? "—"
        case .confluence: return server?.confluence?.edition.rawValue ?? "—"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mount.name).font(.title2.bold())
                        Text("\(mount.product.displayName) · \(host)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Edit", action: onEdit)
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                GroupBox("Server") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Server").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(server?.name ?? "Unknown")
                        }
                        GridRow {
                            Text("Edition").foregroundStyle(.secondary)
                            Text(edition)
                        }
                        if let method = server?.auth.method {
                            GridRow {
                                Text("Auth").foregroundStyle(.secondary)
                                Text(method.displayName)
                            }
                        }
                        if let email = server?.auth.email {
                            GridRow {
                                Text("Email").foregroundStyle(.secondary)
                                Text(email).textSelection(.enabled)
                            }
                        }
                        if let keys = mount.allowedKeys, !keys.isEmpty {
                            GridRow {
                                Text(mount.product == .confluence ? "Spaces" : "Projects")
                                    .foregroundStyle(.secondary)
                                Text(keys.joined(separator: ", "))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }

                MountControlView(descriptor: MountDescriptor(mount: mount))

                GroupBox("Startup") {
                    Toggle("Auto-mount on app launch", isOn: Binding(
                        get: { mount.autoMount },
                        set: { onAutoMountToggle($0) }
                    ))
                    .font(.callout)
                    .padding(.vertical, 4)
                }

                if mount.diskCache {
                    GroupBox("Cache") {
                        HStack {
                            if let result = clearCacheResult {
                                Text(result)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear Cache", role: .destructive) {
                                showClearCacheConfirm = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                    .confirmationDialog(
                        "Clear disk cache for \"\(mount.name)\"?",
                        isPresented: $showClearCacheConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Cache", role: .destructive) {
                            let deleted: Int
                            switch mount.product {
                            case .jira:
                                deleted = CacheManager.clearCache(for: mount.id)
                            case .confluence:
                                deleted = CacheManager.clearCache(
                                    for: mount.id,
                                    product: "confluencefs",
                                    containerBundleID: "com.zumix.jirafs.confluencefs.fskit")
                            }
                            clearCacheResult = "Deleted \(deleted) file\(deleted == 1 ? "" : "s")"
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Cached data will be re-fetched on next access.")
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}
