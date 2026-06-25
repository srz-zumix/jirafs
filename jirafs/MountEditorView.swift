import SwiftUI
import os
import AtlassianCore

private let mountEditorLogger = Logger(subsystem: "com.zumix.jirafs", category: "mount-editor")

/// Editor for a `Mount`: binds a server + product to a mount point with content
/// filtering and per-mount options. The credential comes from the chosen
/// server; this view never touches the Keychain credential, only the per-mount
/// disk-cache encryption key (keyed by the mount id).
struct MountEditorView: View {
    /// Servers available to back this mount.
    let servers: [Server]

    @State private var serverID: String
    @State private var product: MountProduct
    @State private var name: String
    @State private var mountPath: String
    @State private var filter: String
    @State private var diskCache: Bool
    @State private var htmlView: Bool
    @State private var includeArchived: Bool
    @State private var includeRestricted: Bool
    @State private var renderMacros: Bool
    @State private var autoMount: Bool
    @State private var saveError: String?

    private let mountID: String
    private let isNew: Bool

    let onSave: (Mount) -> Void
    let onCancel: () -> Void

    init(
        initial: Mount?,
        servers: [Server],
        onSave: @escaping (Mount) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.servers = servers
        self.mountID = initial?.id ?? UUID().uuidString
        self.isNew = initial == nil

        let defaultServer = initial?.serverID ?? servers.first?.id ?? ""
        _serverID = State(initialValue: defaultServer)

        // Pick a product the chosen server supports.
        let server = servers.first { $0.id == defaultServer }
        let defaultProduct: MountProduct = initial?.product
            ?? (server?.supports(.jira) == true ? .jira : .confluence)
        _product = State(initialValue: defaultProduct)

        _name = State(initialValue: initial?.name ?? "")
        _mountPath = State(initialValue: initial?.mountPath ?? "")
        _filter = State(initialValue: (initial?.allowedKeys ?? []).joined(separator: ", "))
        _diskCache = State(initialValue: initial?.diskCache ?? true)
        _htmlView = State(initialValue: initial?.htmlView ?? false)
        _includeArchived = State(initialValue: initial?.includeArchived ?? false)
        _includeRestricted = State(initialValue: initial?.includeRestricted ?? false)
        // Normalize legacy non-Confluence mounts (which may have persisted
        // `renderMacros == false`) back to the documented default so switching
        // a mount to Confluence in-editor doesn't unexpectedly default macros off.
        _renderMacros = State(initialValue: initial?.product == .confluence ? (initial?.renderMacros ?? true) : true)
        _autoMount = State(initialValue: initial?.autoMount ?? false)

        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var selectedServer: Server? { servers.first { $0.id == serverID } }

    private var availableProducts: [MountProduct] {
        guard let server = selectedServer else { return [] }
        return MountProduct.allCases.filter { server.supports($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Mount" : "Edit Mount")
                .font(.title2.bold())
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formSection("Server") {
                        fieldRow("Server") {
                            Picker("", selection: $serverID) {
                                ForEach(servers) { server in
                                    Text(server.name).tag(server.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: serverID) { _, _ in normalizeProduct() }
                        }
                        fieldRow("Product") {
                            Picker("", selection: $product) {
                                ForEach(availableProducts) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(availableProducts.count <= 1)
                        }
                    }

                    formSection("Mount") {
                        fieldRow("Name") { TextField("My Mount", text: $name) }
                        fieldRow("Path") {
                            TextField(
                                "\(product.defaultMountPrefix)/\(name.isEmpty ? "<name>" : name)",
                                text: $mountPath
                            )
                            .help("Directory where the volume will be mounted. Tilde (~) is supported.")
                        }
                        fieldRow("Disk Cache") {
                            Toggle("", isOn: $diskCache)
                                .labelsHidden().toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Persist cached data to disk (AES-GCM encrypted).")
                        }
                        fieldRow("HTML View") {
                            Toggle("", isOn: $htmlView)
                                .labelsHidden().toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Add a formatted HTML view to each item directory.")
                        }
                        if product == .confluence {
                            fieldRow("Archived") {
                                Toggle("", isOn: $includeArchived)
                                    .labelsHidden().toggleStyle(.switch)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Include archived pages.")
                            }
                            fieldRow("Restricted") {
                                Toggle("", isOn: $includeRestricted)
                                    .labelsHidden().toggleStyle(.switch)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Include pages with user/group restrictions. Off by default.")
                            }
                            fieldRow("Render Macros") {
                                Toggle("", isOn: $renderMacros)
                                    .labelsHidden().toggleStyle(.switch)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Fetch the server-rendered view so dynamic macros (e.g. Table of Contents) are expanded. On by default.")
                            }
                        }
                        fieldRow("Auto-mount") {
                            Toggle("", isOn: $autoMount)
                                .labelsHidden().toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Mount automatically when the app launches.")
                        }
                    }

                    formSection(product == .confluence ? "Spaces" : "Projects") {
                        fieldRow("Filter") {
                            TextField(
                                product == .confluence ? "ALL (e.g. DEV, DOCS)" : "ALL (e.g. PROJ, ALPHA)",
                                text: $filter
                            )
                            .help("Comma-separated keys to expose. Leave blank to show all.")
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Leave blank to show all. Keys are case-insensitive.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 420)
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Form helpers

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

    @ViewBuilder
    private func fieldRow<F: View>(_ label: String, @ViewBuilder field: () -> F) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
                .padding(.trailing, 10)
            field()
                .textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 94)
        }
    }

    // MARK: - Logic

    /// Keep `product` valid when the selected server changes.
    private func normalizeProduct() {
        if !availableProducts.contains(product) {
            product = availableProducts.first ?? product
        }
    }

    private var isValid: Bool {
        !name.isEmpty && selectedServer != nil && !availableProducts.isEmpty
    }

    private func save() {
        saveError = nil
        guard let server = selectedServer, server.supports(product) else {
            saveError = "The selected server does not provide \(product.displayName)."
            return
        }

        if diskCache {
            do {
                _ = try KeychainManager().loadOrCreateCacheKey(instanceName: mountID, product: product.fsType)
            } catch {
                mountEditorLogger.error("Cache key provisioning failed: \(error.localizedDescription, privacy: .public)")
                saveError = "Disk cache could not be enabled because its encryption key could not be created in the Keychain. Turn off Disk Cache to save, or try again. (\(error.localizedDescription))"
                return
            }
        }

        var seen = Set<String>()
        let keys = filter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let mount = Mount(
            id: mountID,
            serverID: serverID,
            product: product,
            name: name,
            mountPath: mountPath.isEmpty ? nil : mountPath,
            allowedKeys: keys.isEmpty ? nil : keys,
            diskCache: diskCache,
            htmlView: htmlView,
            includeArchived: product == .confluence ? includeArchived : false,
            includeRestricted: product == .confluence ? includeRestricted : false,
            renderMacros: renderMacros,
            autoMount: autoMount
        )
        onSave(mount)
    }
}
