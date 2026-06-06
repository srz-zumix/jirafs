import SwiftUI
import JiraFSCore
import ConfluenceFSCore
import AtlassianCore

/// Application Preferences window (Settings scene): manage reusable servers,
/// startup/extension settings, and global cache TTL defaults.
struct PreferencesView: View {
    var body: some View {
        TabView {
            ServersPreferencesTab()
                .tabItem { Label("Servers", systemImage: "server.rack") }
            GeneralPreferencesTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            CachePreferencesTab()
                .tabItem { Label("Cache", systemImage: "clock.arrow.2.circlepath") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Servers tab

private struct ServersPreferencesTab: View {
    @EnvironmentObject private var appStore: AppStoreModel
    @State private var selection: String?
    @State private var showingAdd = false
    @State private var editing: Server?
    @State private var deleteBlocked: (server: Server, mountCount: Int)?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(appStore.servers) { server in
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.body)
                            Text(productsSummary(server))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(server.id)
                    .onTapGesture(count: 2) { editing = server }
                    .contextMenu {
                        Button("Edit…") { editing = server }
                        Button("Delete", role: .destructive) { attemptDelete(server) }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add server")
                Button {
                    if let id = selection, let s = appStore.server(id: id) { attemptDelete(s) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Delete server")
                Button {
                    if let id = selection, let s = appStore.server(id: id) { editing = s }
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(selection == nil)
                .help("Edit server")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(isPresented: $showingAdd) {
            ServerEditorView(initial: nil) { server in
                appStore.upsertServer(server)
                showingAdd = false
            } onCancel: { showingAdd = false }
        }
        .sheet(item: $editing) { server in
            ServerEditorView(initial: server) { updated in
                appStore.upsertServer(updated)
                editing = nil
            } onCancel: { editing = nil }
        }
        .alert(
            "Server in use",
            isPresented: Binding(
                get: { deleteBlocked != nil },
                set: { if !$0 { deleteBlocked = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteBlocked = nil }
        } message: {
            if let blocked = deleteBlocked {
                Text("\"\(blocked.server.name)\" is used by \(blocked.mountCount) mount\(blocked.mountCount == 1 ? "" : "s"). Remove those mounts before deleting the server.")
            }
        }
    }

    private func productsSummary(_ server: Server) -> String {
        var parts: [String] = []
        if let j = server.jira { parts.append("JIRA · \(j.url.host ?? j.url.absoluteString)") }
        if let c = server.confluence { parts.append("Confluence · \(c.url.host ?? c.url.absoluteString)") }
        return parts.isEmpty ? "No products" : parts.joined(separator: "   ")
    }

    private func attemptDelete(_ server: Server) {
        let mounts = appStore.mounts(forServer: server.id)
        if mounts.isEmpty {
            appStore.deleteServer(server)
            if selection == server.id { selection = nil }
        } else {
            deleteBlocked = (server, mounts.count)
        }
    }
}

// MARK: - General tab

private struct GeneralPreferencesTab: View {
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
            }
            Section {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Extension Settings…", systemImage: "puzzlepiece.extension")
                }
                .help("Enable the jirafs / confluencefs file system extensions in System Settings.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Cache tab

private struct CachePreferencesTab: View {
    @EnvironmentObject private var appStore: AppStoreModel

    /// Valid TTL range (seconds). 0 disables caching; cap at 24h.
    private static let ttlMin: TimeInterval = 0
    private static let ttlMax: TimeInterval = 86_400

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                formSection("JIRA TTL") {
                    ttlRow("Projects",     value: jiraBinding(\.projects))
                    rowDivider
                    ttlRow("Issues",       value: jiraBinding(\.issues))
                    rowDivider
                    ttlRow("Issue Detail", value: jiraBinding(\.issueDetail))
                    rowDivider
                    ttlRow("Attachments",  value: jiraBinding(\.attachments))
                    rowDivider
                    ttlRow("File Content", value: jiraBinding(\.attachmentBinary))
                }

                formSection("Confluence TTL") {
                    ttlRow("Spaces",       value: confluenceBinding(\.spaces))
                    rowDivider
                    ttlRow("Pages",        value: confluenceBinding(\.pages))
                    rowDivider
                    ttlRow("Page Detail",  value: confluenceBinding(\.pageDetail))
                    rowDivider
                    ttlRow("Attachments",  value: confluenceBinding(\.attachments))
                    rowDivider
                    ttlRow("File Content", value: confluenceBinding(\.attachmentBinary))
                }

                HStack {
                    Button("Reset to Defaults") {
                        appStore.store.jiraCache = .default
                        appStore.store.confluenceCache = .default
                        appStore.saveCacheSettings()
                    }
                    Spacer()
                }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Changes take effect after remounting each mount.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var rowDivider: some View { Divider().padding(.leading, 100) }

    private func jiraBinding(_ keyPath: WritableKeyPath<Configuration.CacheTTLConfig, TimeInterval>) -> Binding<TimeInterval> {
        Binding(
            get: { appStore.store.jiraCache[keyPath: keyPath] },
            set: {
                appStore.store.jiraCache[keyPath: keyPath] = max(Self.ttlMin, min(Self.ttlMax, $0.rounded()))
                appStore.saveCacheSettings()
            }
        )
    }

    private func confluenceBinding(_ keyPath: WritableKeyPath<ConfluenceConfiguration.CacheTTLConfig, TimeInterval>) -> Binding<TimeInterval> {
        Binding(
            get: { appStore.store.confluenceCache[keyPath: keyPath] },
            set: {
                appStore.store.confluenceCache[keyPath: keyPath] = max(Self.ttlMin, min(Self.ttlMax, $0.rounded()))
                appStore.saveCacheSettings()
            }
        )
    }

    @ViewBuilder
    private func ttlRow(_ label: String, value: Binding<TimeInterval>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
                .padding(.trailing, 10)
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text("sec")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Text("(\(formatMinutes(value.wrappedValue)))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let mins = seconds / 60
        if mins < 1 { return "\(Int(seconds.rounded()))s" }
        if mins == Double(Int(mins)) { return "\(Int(mins)) min" }
        return String(format: "%.1f min", mins)
    }

    @ViewBuilder
    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }
}
