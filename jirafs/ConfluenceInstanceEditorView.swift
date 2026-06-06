import SwiftUI
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore

/// Editor for a Confluence instance, mirroring `InstanceEditorView` but driven
/// by `ConfluenceConfiguration` (spaces instead of projects, `confluence://`
/// scheme, Cloud / Data Center editions).
struct ConfluenceInstanceEditorView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var edition: ConfluenceEdition
    @State private var method: ConfluenceConfiguration.AuthEntry.Method
    @State private var email: String
    @State private var token: String
    @State private var mountPath: String
    @State private var diskCache: Bool
    @State private var htmlView: Bool
    @State private var includeArchived: Bool
    /// Comma-separated space keys to allow. Empty string = all spaces.
    @State private var spaceFilter: String

    private enum VerifyState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }
    @State private var verifyState: VerifyState = .idle
    /// Non-nil when `save()` was aborted (e.g. Keychain provisioning failed),
    /// surfaced to the user instead of silently swallowing the failure.
    @State private var saveError: String?

    private let originalName: String?
    private let originalMethod: ConfluenceConfiguration.AuthEntry.Method?
    private let originalEmail: String?
    @EnvironmentObject private var monitor: MountStatusMonitor
    let onSave: (ConfluenceConfiguration.InstanceEntry) -> Void
    let onCancel: () -> Void

    init(
        initial: ConfluenceConfiguration.InstanceEntry?,
        onSave: @escaping (ConfluenceConfiguration.InstanceEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalName = initial?.name
        self.originalMethod = initial?.auth.method
        self.originalEmail = initial?.auth.email
        _name = State(initialValue: initial?.name ?? "")
        _urlString = State(initialValue: initial?.url.absoluteString ?? "https://example.atlassian.net")
        _edition = State(initialValue: initial?.type ?? .cloud)
        _method = State(initialValue: initial?.auth.method ?? .apiToken)
        _email = State(initialValue: initial?.auth.email ?? "")
        _token = State(initialValue: "")
        _mountPath = State(initialValue: initial?.mountPath ?? "")
        _diskCache = State(initialValue: initial?.diskCache ?? true)
        _htmlView  = State(initialValue: initial?.htmlView ?? false)
        _includeArchived = State(initialValue: initial?.includeArchived ?? false)
        let keys = initial?.allowedSpaceKeys ?? []
        _spaceFilter = State(initialValue: keys.joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(originalName == nil ? "New Confluence Instance" : "Edit Confluence Instance")
                .font(.title2.bold())
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

            Divider()

            if let instName = originalName, monitor.mountedStates["confluence:\(instName)"] == true {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This instance is currently mounted. Changes take effect after remounting.")
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formSection("Connection") {
                        fieldRow("Name")        { TextField("My Confluence", text: $name) }
                        fieldRow("URL")         { TextField("https://example.atlassian.net", text: $urlString) }
                        fieldRow("Edition") {
                            Picker("", selection: $edition) {
                                Text("Cloud").tag(ConfluenceEdition.cloud)
                                Text("Data Center").tag(ConfluenceEdition.dataCenter)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    formSection("Authentication") {
                        fieldRow("Method") {
                            Picker("", selection: $method) {
                                Text("API Token").tag(ConfluenceConfiguration.AuthEntry.Method.apiToken)
                                Text("PAT").tag(ConfluenceConfiguration.AuthEntry.Method.pat)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if method == .apiToken {
                            fieldRow("Email")  { TextField("user@example.com", text: $email) }
                        }
                        fieldRow("Token") {
                            SecureField(
                                token.isEmpty && originalName != nil && !keychainKeyChanged
                                    ? "leave blank to keep current"
                                    : "required",
                                text: $token
                            )
                        }
                    }

                    formSection("Mount") {
                        fieldRow("Path") {
                            TextField(
                                "~/confluencefs/\(name.isEmpty ? "<name>" : name)",
                                text: $mountPath
                            )
                            .help("Directory where the volume will be mounted. Tilde (~) is supported.")
                        }
                        fieldRow("Disk Cache") {
                            Toggle("", isOn: $diskCache)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Persist cached Confluence data to disk (AES-GCM encrypted). Survives fskitd restarts.")
                        }
                        fieldRow("HTML View") {
                            Toggle("", isOn: $htmlView)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Add a sibling {Title}.html file next to each page directory — a formatted view of the page body.")
                        }
                        fieldRow("Archived Pages") {
                            Toggle("", isOn: $includeArchived)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Include archived pages in directory listings. Off by default.")
                        }
                    }

                    formSection("Spaces") {
                        fieldRow("Filter") {
                            TextField("ALL (e.g. DEV, DOCS)", text: $spaceFilter)
                            .help("Comma-separated space keys to expose. Leave blank to show all spaces.")
                        }
                        .overlay(alignment: .bottom) { Color.clear }
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Leave blank to show all spaces. Keys are case-insensitive.")
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

            if verifyState != .idle {
                HStack(spacing: 6) {
                    switch verifyState {
                    case .running:
                        ProgressView().controlSize(.small)
                        Text("Verifying…").foregroundStyle(.secondary)
                    case .success(let msg):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(msg).foregroundStyle(.primary)
                    case .failure(let msg):
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(msg).foregroundStyle(.primary)
                    case .idle:
                        EmptyView()
                    }
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Verify") { Task { await verify() } }
                    .disabled(!canVerify || verifyState == .running)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 400)
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
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

    private var keychainKeyChanged: Bool {
        guard originalName != nil,
              let origMethod = originalMethod else { return false }
        if name != originalName { return true }
        if method != origMethod { return true }
        if method == .apiToken {
            let origAcc = (originalEmail ?? "").isEmpty ? "api_token" : (originalEmail ?? "")
            let newAcc  = email.isEmpty ? "api_token" : email
            if newAcc != origAcc { return true }
        }
        return false
    }

    private var isValid: Bool {
        !name.isEmpty && URL(string: urlString) != nil
            && (!token.isEmpty || (originalName != nil && !keychainKeyChanged))
    }

    private var canVerify: Bool {
        URL(string: urlString) != nil
            && (!token.isEmpty || (originalName != nil && !keychainKeyChanged))
    }

    @MainActor
    private func verify() async {
        guard let url = URL(string: urlString) else { return }
        verifyState = .running

        do {
            let resolvedToken: String
            if !token.isEmpty {
                resolvedToken = token
            } else if let instName = originalName {
                let account = method == .apiToken ? (email.isEmpty ? "api_token" : email) : "pat"
                resolvedToken = try KeychainManager().password(instanceName: instName, account: account)
            } else {
                throw AtlassianError.missingCredentials
            }

            let cfg = ConfluenceInstanceConfig(name: name.isEmpty ? "verify" : name,
                                               baseURL: url, edition: edition)
            let auth: AuthProvider = method == .apiToken
                ? APITokenAuth(email: email, token: resolvedToken)
                : PATAuth(token: resolvedToken)
            let client = ConfluenceRESTClient(config: cfg, auth: auth)

            let spaces = try await client.listSpaces(cursor: nil, limit: 250).items
            let spaceKeys = Set(spaces.map { $0.key.uppercased() })

            let filterKeys = spaceFilter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty }

            if filterKeys.isEmpty {
                let count = spaces.count
                verifyState = .success("Connected · \(count) space\(count == 1 ? "" : "s") accessible")
            } else {
                let notFound = filterKeys.filter { !spaceKeys.contains($0) }
                if notFound.isEmpty {
                    verifyState = .success("Connected · \(filterKeys.count) space\(filterKeys.count == 1 ? "" : "s") verified (\(filterKeys.joined(separator: ", ")))")
                } else {
                    verifyState = .failure("Space\(notFound.count == 1 ? "" : "s") not found: \(notFound.joined(separator: ", "))")
                }
            }
        } catch {
            verifyState = .failure(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        switch error as? AtlassianError {
        case .unauthorized:
            return "Authentication failed — check credentials"
        case .forbidden:
            return "Access denied — check permissions"
        case .missingCredentials:
            return "No token available — enter the token first"
        case .serverError(let status):
            return "Server error (HTTP \(status))"
        case .invalidURL:
            return "Invalid URL"
        case .rateLimited:
            return "Rate limited — try again later"
        case .decoding(let detail):
            return "Unexpected response — \(detail)"
        case .transport(let detail):
            return "Network error — \(detail)"
        default:
            let msg = error.localizedDescription
            return msg.isEmpty ? "Connection failed" : msg
        }
    }

    private func save() {
        guard let url = URL(string: urlString) else { return }
        saveError = nil
        // Provision the disk-cache encryption key before any other Keychain
        // mutation so a provisioning failure aborts the save without leaving an
        // orphaned credential behind (e.g. when editing + renaming an instance).
        if diskCache && !name.isEmpty {
            do {
                _ = try KeychainManager().loadOrCreateCacheKey(instanceName: name, product: "confluencefs")
            } catch {
                print("Cache key provisioning failed: \(error)")
                saveError = "Disk cache could not be enabled because its encryption key could not be created in the Keychain. Turn off Disk Cache to save, or try again. (\(error.localizedDescription))"
                return
            }
        }
        if !token.isEmpty {
            do {
                let account = method == .apiToken ? (email.isEmpty ? "api_token" : email) : "pat"
                try KeychainManager().setPassword(token, instanceName: name, account: account)
            } catch {
                print("Keychain save failed: \(error)")
                saveError = "Could not save the credential to the Keychain. \(error.localizedDescription)"
                return
            }
        }
        let auth = ConfluenceConfiguration.AuthEntry(method: method, email: method == .apiToken ? email : nil)
        var _seen = Set<String>()
        let parsedKeys = spaceFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && _seen.insert($0).inserted }
        let entry = ConfluenceConfiguration.InstanceEntry(
            name: name, type: edition, url: url, auth: auth,
            mountPath: mountPath.isEmpty ? nil : mountPath,
            allowedSpaceKeys: parsedKeys.isEmpty ? nil : parsedKeys,
            diskCache: diskCache,
            htmlView: htmlView,
            includeArchived: includeArchived
        )
        // Best-effort cleanup of the previous instance's orphaned cache key when
        // the instance was renamed. Non-fatal: a failure must not abort the save.
        if let original = originalName, original != name {
            do {
                try KeychainManager().deleteCacheKey(instanceName: original, product: "confluencefs")
            } catch {
                print("Old cache key cleanup failed: \(error)")
            }
        }
        onSave(entry)
    }
}
