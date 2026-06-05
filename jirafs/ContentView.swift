import SwiftUI
import JiraAPI
import JiraFSCore
import AtlassianCore
import ConfluenceFSCore

/// Discriminates the two supported Atlassian products in the host UI.
enum InstanceKind: String, Hashable {
    case jira
    case confluence
}

/// Stable identity for a row in the unified instance list.
struct InstanceRef: Identifiable, Hashable {
    let kind: InstanceKind
    let name: String
    var id: String { "\(kind.rawValue):\(name)" }
}

@MainActor
final class InstanceListModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var confluenceConfiguration: ConfluenceConfiguration
    @Published var selection: InstanceRef.ID?

    init() {
        self.configuration = AppConfig.load()
        self.confluenceConfiguration = AppConfig.loadConfluence()
    }

    func reload() {
        configuration = AppConfig.load()
        confluenceConfiguration = AppConfig.loadConfluence()
    }

    // MARK: JIRA

    func saveJira() {
        do { try AppConfig.save(configuration) }
        catch { print("Failed to save JIRA config: \(error)") }
    }

    func add(_ entry: Configuration.InstanceEntry) {
        configuration.instances.removeAll { $0.name == entry.name }
        configuration.instances.append(entry)
        saveJira()
    }

    func update(original: Configuration.InstanceEntry, updated: Configuration.InstanceEntry) {
        if let idx = configuration.instances.firstIndex(where: { $0.id == original.id }) {
            configuration.instances[idx] = updated
        } else {
            configuration.instances.append(updated)
        }
        saveJira()
    }

    func removeJira(name: String) {
        configuration.instances.removeAll { $0.name == name }
        try? KeychainManager().deleteCacheKey(instanceName: name, product: "jirafs")
        saveJira()
    }

    // MARK: Confluence

    func saveConfluence() {
        do { try AppConfig.saveConfluence(confluenceConfiguration) }
        catch { print("Failed to save Confluence config: \(error)") }
    }

    func add(_ entry: ConfluenceConfiguration.InstanceEntry) {
        confluenceConfiguration.instances.removeAll { $0.name == entry.name }
        confluenceConfiguration.instances.append(entry)
        saveConfluence()
    }

    func update(original: ConfluenceConfiguration.InstanceEntry,
                updated: ConfluenceConfiguration.InstanceEntry) {
        if let idx = confluenceConfiguration.instances.firstIndex(where: { $0.id == original.id }) {
            confluenceConfiguration.instances[idx] = updated
        } else {
            confluenceConfiguration.instances.append(updated)
        }
        saveConfluence()
    }

    func removeConfluence(name: String) {
        confluenceConfiguration.instances.removeAll { $0.name == name }
        try? KeychainManager().deleteCacheKey(instanceName: name, product: "confluencefs")
        saveConfluence()
    }
}

struct ContentView: View {
    @StateObject private var model = InstanceListModel()
    @EnvironmentObject private var navigation: NavigationModel
    @State private var showingAddJira = false
    @State private var showingAddConfluence = false
    @State private var editingJira: Configuration.InstanceEntry?
    @State private var editingConfluence: ConfluenceConfiguration.InstanceEntry?
    @State private var showingCacheSettings = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    if !model.configuration.instances.isEmpty {
                        Section("JIRA") {
                            ForEach(model.configuration.instances.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { entry in
                                instanceRow(name: entry.name,
                                            host: entry.url.host ?? entry.url.absoluteString,
                                            systemImage: "ladybug")
                                .tag(InstanceRef(kind: .jira, name: entry.name).id)
                            }
                        }
                    }
                    if !model.confluenceConfiguration.instances.isEmpty {
                        Section("Confluence") {
                            ForEach(model.confluenceConfiguration.instances.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { entry in
                                instanceRow(name: entry.name,
                                            host: entry.url.host ?? entry.url.absoluteString,
                                            systemImage: "doc.richtext")
                                .tag(InstanceRef(kind: .confluence, name: entry.name).id)
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showingAddJira = true
                            } label: {
                                Label("Add JIRA Instance…", systemImage: "ladybug")
                            }
                            Button {
                                showingAddConfluence = true
                            } label: {
                                Label("Add Confluence Instance…", systemImage: "doc.richtext")
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            showingCacheSettings = true
                        } label: {
                            Label("Cache Settings", systemImage: "clock.arrow.2.circlepath")
                        }
                    }
                }
                .navigationTitle("Instances")

                Divider()

                // System settings shortcuts
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Extension Settings", systemImage: "puzzlepiece.extension")
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
        .sheet(isPresented: $showingAddJira) {
            InstanceEditorView(initial: nil) { entry in
                model.add(entry)
                showingAddJira = false
            } onCancel: {
                showingAddJira = false
            }
        }
        .sheet(isPresented: $showingAddConfluence) {
            ConfluenceInstanceEditorView(initial: nil) { entry in
                model.add(entry)
                showingAddConfluence = false
            } onCancel: {
                showingAddConfluence = false
            }
        }
        .sheet(item: $editingJira) { entry in
            InstanceEditorView(initial: entry) { updated in
                model.update(original: entry, updated: updated)
                editingJira = nil
            } onCancel: {
                editingJira = nil
            }
        }
        .sheet(item: $editingConfluence) { entry in
            ConfluenceInstanceEditorView(initial: entry) { updated in
                model.update(original: entry, updated: updated)
                editingConfluence = nil
            } onCancel: {
                editingConfluence = nil
            }
        }
        .sheet(isPresented: $showingCacheSettings) {
            CacheSettingsView(ttl: $model.configuration.cache) {
                model.saveJira()
            }
        }
        .onReceive(navigation.$pendingSelection) { id in
            guard let id else { return }
            model.selection = id
            navigation.pendingSelection = nil
        }
    }

    @ViewBuilder
    private func instanceRow(name: String, host: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(name)
                .font(.body)
            Text(host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let id = model.selection,
           let jira = model.configuration.instances.first(where: {
               InstanceRef(kind: .jira, name: $0.name).id == id
           }) {
            InstanceDetailView(entry: jira,
                               onEdit: { editingJira = jira },
                               onDelete: {
                model.removeJira(name: jira.name)
                model.selection = nil
            }, onAutoMountToggle: { newValue in
                var updated = jira
                updated.autoMount = newValue
                model.update(original: jira, updated: updated)
            })
        } else if let id = model.selection,
                  let conf = model.confluenceConfiguration.instances.first(where: {
                      InstanceRef(kind: .confluence, name: $0.name).id == id
                  }) {
            ConfluenceInstanceDetailView(entry: conf,
                                         onEdit: { editingConfluence = conf },
                                         onDelete: {
                model.removeConfluence(name: conf.name)
                model.selection = nil
            }, onAutoMountToggle: { newValue in
                var updated = conf
                updated.autoMount = newValue
                model.update(original: conf, updated: updated)
            })
        } else {
            ContentUnavailableView("No Instance Selected",
                                   systemImage: "externaldrive",
                                   description: Text("Add a JIRA or Confluence instance to get started."))
        }
    }
}

struct InstanceDetailView: View {
    let entry: Configuration.InstanceEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAutoMountToggle: (Bool) -> Void

    @State private var showClearCacheConfirm = false
    @State private var clearCacheResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.title2.bold())
                        Text(entry.url.host ?? entry.url.absoluteString)
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

                // Instance info
                GroupBox("Connection") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Edition").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(entry.type.rawValue)
                        }
                        GridRow {
                            Text("Auth").foregroundStyle(.secondary)
                            Text(entry.auth.method.rawValue)
                        }
                        if let email = entry.auth.email {
                            GridRow {
                                Text("Email").foregroundStyle(.secondary)
                                Text(email).textSelection(.enabled)
                            }
                        }
                        if let keys = entry.allowedProjectKeys, !keys.isEmpty {
                            GridRow {
                                Text("Projects").foregroundStyle(.secondary)
                                Text(keys.joined(separator: ", "))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }

                MountControlView(descriptor: MountDescriptor(jira: entry))
                    .id(entry.id)

                GroupBox("Startup") {
                    Toggle("Auto-mount on app launch", isOn: Binding(
                        get: { entry.autoMount },
                        set: { onAutoMountToggle($0) }
                    ))
                    .font(.callout)
                    .padding(.vertical, 4)
                }

                // Cache management
                if entry.diskCache {
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
                        "Clear disk cache for \"\(entry.name)\"?",
                        isPresented: $showClearCacheConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Cache", role: .destructive) {
                            let deleted = CacheManager.clearCache(for: entry.name)
                            clearCacheResult = "Deleted \(deleted) file\(deleted == 1 ? "" : "s")"
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Cached data will be re-fetched from JIRA on next access.")
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}

struct ConfluenceInstanceDetailView: View {
    let entry: ConfluenceConfiguration.InstanceEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAutoMountToggle: (Bool) -> Void

    @State private var showClearCacheConfirm = false
    @State private var clearCacheResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.title2.bold())
                        Text(entry.url.host ?? entry.url.absoluteString)
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

                GroupBox("Connection") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Edition").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(entry.type.rawValue)
                        }
                        GridRow {
                            Text("Auth").foregroundStyle(.secondary)
                            Text(entry.auth.method.rawValue)
                        }
                        if let email = entry.auth.email {
                            GridRow {
                                Text("Email").foregroundStyle(.secondary)
                                Text(email).textSelection(.enabled)
                            }
                        }
                        if let keys = entry.allowedSpaceKeys, !keys.isEmpty {
                            GridRow {
                                Text("Spaces").foregroundStyle(.secondary)
                                Text(keys.joined(separator: ", "))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }

                MountControlView(descriptor: MountDescriptor(confluence: entry))
                    .id(entry.id)

                GroupBox("Startup") {
                    Toggle("Auto-mount on app launch", isOn: Binding(
                        get: { entry.autoMount },
                        set: { onAutoMountToggle($0) }
                    ))
                    .font(.callout)
                    .padding(.vertical, 4)
                }

                if entry.diskCache {
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
                        "Clear disk cache for \"\(entry.name)\"?",
                        isPresented: $showClearCacheConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Cache", role: .destructive) {
                            let deleted = CacheManager.clearCache(
                                for: entry.name,
                                product: "confluencefs",
                                containerBundleID: "com.zumix.jirafs.confluencefs.fskit")
                            clearCacheResult = "Deleted \(deleted) file\(deleted == 1 ? "" : "s")"
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Cached data will be re-fetched from Confluence on next access.")
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}
