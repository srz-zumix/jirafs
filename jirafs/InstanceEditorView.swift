import SwiftUI
import JiraAPI
import JiraFSCore

struct InstanceEditorView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var edition: JiraEdition
    @State private var method: Configuration.AuthEntry.Method
    @State private var email: String
    @State private var token: String
    @State private var mountPath: String
    @State private var diskCache: Bool
    /// Comma-separated project keys to allow. Empty string = all projects.
    @State private var projectFilter: String

    // MARK: Verify state
    private enum VerifyState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }
    @State private var verifyState: VerifyState = .idle

    private let originalName: String?
    let onSave: (Configuration.InstanceEntry) -> Void
    let onCancel: () -> Void

    init(
        initial: Configuration.InstanceEntry?,
        onSave: @escaping (Configuration.InstanceEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalName = initial?.name
        _name = State(initialValue: initial?.name ?? "")
        _urlString = State(initialValue: initial?.url.absoluteString ?? "https://example.atlassian.net")
        _edition = State(initialValue: initial?.type ?? .cloud)
        _method = State(initialValue: initial?.auth.method ?? .apiToken)
        _email = State(initialValue: initial?.auth.email ?? "")
        _token = State(initialValue: "")
        _mountPath = State(initialValue: initial?.mountPath ?? "")
        _diskCache = State(initialValue: initial?.diskCache ?? false)
        let keys = initial?.allowedProjectKeys ?? []
        _projectFilter = State(initialValue: keys.joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(originalName == nil ? "New Instance" : "Edit Instance")
                .font(.title2.bold())
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formSection("Connection") {
                        fieldRow("Name")        { TextField("My JIRA", text: $name) }
                        fieldRow("URL")         { TextField("https://example.atlassian.net", text: $urlString) }
                        fieldRow("Edition") {
                            Picker("", selection: $edition) {
                                Text("Cloud").tag(JiraEdition.cloud)
                                Text("Server").tag(JiraEdition.server)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    formSection("Authentication") {
                        fieldRow("Method") {
                            Picker("", selection: $method) {
                                Text("API Token").tag(Configuration.AuthEntry.Method.apiToken)
                                Text("PAT").tag(Configuration.AuthEntry.Method.pat)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if method == .apiToken {
                            fieldRow("Email")  { TextField("user@example.com", text: $email) }
                        }
                        fieldRow("Token") {
                            SecureField(
                                token.isEmpty && originalName != nil
                                    ? "leave blank to keep current"
                                    : "required",
                                text: $token
                            )
                        }
                    }

                    formSection("Mount") {
                        fieldRow("Path") {
                            TextField(
                                "~/jirafs/\(name.isEmpty ? "<name>" : name)",
                                text: $mountPath
                            )
                            .help("Directory where the volume will be mounted. Tilde (~) is supported.")
                        }
                        fieldRow("Disk Cache") {
                            Toggle("", isOn: $diskCache)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Persist cached JIRA data to disk (AES-GCM encrypted). Survives fskitd restarts.")
                        }
                    }

                    formSection("Projects") {
                        fieldRow("Filter") {
                            TextField("ALL (e.g. PROJ, ALPHA)", text: $projectFilter)
                            .help("Comma-separated project keys to expose. Leave blank to show all projects.")
                        }
                        .overlay(alignment: .bottom) { Color.clear }
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Leave blank to show all projects. Keys are case-insensitive.")
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

            // Verify result banner
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

    private var isValid: Bool {
        !name.isEmpty && URL(string: urlString) != nil && (!token.isEmpty || originalName != nil)
    }

    /// Verify is possible when URL is set and a token is available (entered or stored).
    private var canVerify: Bool {
        URL(string: urlString) != nil && (!token.isEmpty || originalName != nil)
    }

    @MainActor
    private func verify() async {
        guard let url = URL(string: urlString) else { return }
        verifyState = .running

        do {
            // Resolve token: use form field first, fall back to Keychain.
            let resolvedToken: String
            if !token.isEmpty {
                resolvedToken = token
            } else if let instName = originalName {
                let account = method == .apiToken ? (email.isEmpty ? "api_token" : email) : "pat"
                resolvedToken = try KeychainManager().password(instanceName: instName, account: account)
            } else {
                throw JiraAPIError.missingCredentials
            }

            let cfg = JiraInstanceConfig(name: name.isEmpty ? "verify" : name,
                                         baseURL: url, edition: edition)
            let auth: AuthProvider = method == .apiToken
                ? APITokenAuth(email: email, token: resolvedToken)
                : PATAuth(token: resolvedToken)
            let client = JiraRESTClient(config: cfg, auth: auth)

            // Verify: server reachability + auth
            try await client.serverInfo()

            // Count accessible projects
            let projects = try await client.listProjects()
            let projectKeys = Set(projects.map { $0.key.uppercased() })

            // Check project filter
            let filterKeys = projectFilter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty }

            if filterKeys.isEmpty {
                // No filter: show total count
                let count = projects.count
                verifyState = .success("Connected · \(count) project\(count == 1 ? "" : "s") accessible")
            } else {
                let notFound = filterKeys.filter { !projectKeys.contains($0) }
                if notFound.isEmpty {
                    verifyState = .success("Connected · \(filterKeys.count) project\(filterKeys.count == 1 ? "" : "s") verified (\(filterKeys.joined(separator: ", ")))")
                } else {
                    verifyState = .failure("Project\(notFound.count == 1 ? "" : "s") not found: \(notFound.joined(separator: ", "))")
                }
            }
        } catch {
            verifyState = .failure(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        switch error as? JiraAPIError {
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
        if !token.isEmpty {
            do {
                let account = method == .apiToken ? email : "pat"
                try KeychainManager().setPassword(token, instanceName: name, account: account)
            } catch {
                print("Keychain save failed: \(error)")
                return
            }
        }
        let auth = Configuration.AuthEntry(method: method, email: method == .apiToken ? email : nil)
        let parsedKeys = projectFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        let entry = Configuration.InstanceEntry(
            name: name, type: edition, url: url, auth: auth,
            mountPath: mountPath.isEmpty ? nil : mountPath,
            allowedProjectKeys: parsedKeys.isEmpty ? nil : parsedKeys,
            diskCache: diskCache
        )
        onSave(entry)
    }
}
