import SwiftUI
import JiraAPI
import ConfluenceAPI
import AtlassianCore
import os

private let serverEditorLogger = Logger(subsystem: "com.zumix.jirafs", category: "server-editor")

/// Editor for a reusable `Server`: connection details for JIRA and/or
/// Confluence plus a single shared credential. The credential token lives in
/// the Keychain keyed by the server id; everything else is stored in the
/// `AppStore`.
struct ServerEditorView: View {
    @State private var name: String
    /// Whether this is an Atlassian **Cloud** server. Cloud shares a single
    /// base URL across products (Confluence derives `/wiki`); Server / Data
    /// Center installs JIRA and Confluence at independent URLs.
    @State private var isCloud: Bool
    /// Shared base URL used in Cloud mode.
    @State private var cloudURL: String
    @State private var enableJira: Bool
    /// JIRA URL used in Server (non-Cloud) mode.
    @State private var jiraURL: String
    @State private var enableConfluence: Bool
    /// Confluence URL used in Server (non-Cloud) mode.
    @State private var confluenceURL: String
    @State private var method: ServerAuthMethod
    @State private var email: String
    @State private var token: String

    private enum VerifyState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }
    @State private var verifyState: VerifyState = .idle
    @State private var saveError: String?

    private let serverID: String
    private let isNew: Bool
    /// Original auth account, to detect when the Keychain key changes.
    private let originalMethod: ServerAuthMethod?
    private let originalEmail: String?

    let onSave: (Server) -> Void
    let onCancel: () -> Void

    init(
        initial: Server?,
        onSave: @escaping (Server) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.serverID = initial?.id ?? UUID().uuidString
        self.isNew = initial == nil
        self.originalMethod = initial?.auth.method
        self.originalEmail = initial?.auth.email

        let cloud = initial.map {
            ($0.jira?.edition == .cloud) || ($0.confluence?.edition == .cloud)
        } ?? true
        // Derive the Cloud base URL from JIRA, else strip Confluence's `/wiki`.
        let cloudBase = initial?.jira?.url.absoluteString
            ?? initial?.confluence?.url.deletingLastPathComponent().absoluteString
            ?? "https://example.atlassian.net"

        _name = State(initialValue: initial?.name ?? "")
        _isCloud = State(initialValue: cloud)
        _cloudURL = State(initialValue: Self.trimTrailingSlash(cloudBase))
        _enableJira = State(initialValue: initial == nil || initial?.jira != nil)
        _jiraURL = State(initialValue: initial?.jira?.url.absoluteString ?? "https://jira.example.com")
        _enableConfluence = State(initialValue: initial == nil || initial?.confluence != nil)
        _confluenceURL = State(initialValue: initial?.confluence?.url.absoluteString ?? "https://confluence.example.com")
        _method = State(initialValue: initial?.auth.method ?? .apiToken)
        _email = State(initialValue: initial?.auth.email ?? "")
        _token = State(initialValue: "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Server" : "Edit Server")
                .font(.title2.bold())
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formSection("General") {
                        fieldRow("Name") { TextField("My Atlassian", text: $name) }
                        fieldRow("Edition") {
                            Picker("", selection: $isCloud) {
                                Text("Cloud").tag(true)
                                Text("Server / Data Center").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if isCloud {
                            fieldRow("URL") {
                                TextField("https://example.atlassian.net", text: $cloudURL)
                                    .help("Your Atlassian Cloud site URL. Confluence uses the same site (the /wiki path is added automatically).")
                            }
                        }
                    }

                    formSection("JIRA") {
                        fieldRow("Enable") {
                            Toggle("", isOn: $enableJira)
                                .labelsHidden().toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if enableJira && !isCloud {
                            fieldRow("URL") { TextField("https://jira.example.com", text: $jiraURL) }
                        }
                    }

                    formSection("Confluence") {
                        fieldRow("Enable") {
                            Toggle("", isOn: $enableConfluence)
                                .labelsHidden().toggleStyle(.switch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if enableConfluence && !isCloud {
                            fieldRow("URL") { TextField("https://confluence.example.com", text: $confluenceURL) }
                        }
                    }

                    formSection("Authentication") {
                        fieldRow("Method") {
                            Picker("", selection: $method) {
                                Text("API Token").tag(ServerAuthMethod.apiToken)
                                Text("PAT").tag(ServerAuthMethod.pat)
                                Text("Anonymous").tag(ServerAuthMethod.anonymous)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if method == .apiToken {
                            fieldRow("Email") { TextField("user@example.com", text: $email) }
                        }
                        if method != .anonymous {
                            fieldRow("Token") {
                                SecureField(
                                    token.isEmpty && !isNew && !keychainKeyChanged
                                        ? "leave blank to keep current"
                                        : "required",
                                    text: $token
                                )
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            if let warning = httpsWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).foregroundStyle(.primary)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()
            }

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
        .frame(minWidth: 460, minHeight: 440)
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

    // MARK: - Validation

    private var keychainKeyChanged: Bool {
        guard !isNew, let origMethod = originalMethod else { return false }
        if method != origMethod { return true }
        if method == .apiToken {
            let origAcc = (originalEmail ?? "").isEmpty ? "api_token" : (originalEmail ?? "")
            let newAcc = email.isEmpty ? "api_token" : email
            if newAcc != origAcc { return true }
        }
        return false
    }

    private var hasProduct: Bool { enableJira || enableConfluence }

    /// Effective JIRA edition: Cloud sites use `.cloud`, otherwise `.server`.
    private var jiraEdition: JiraEdition { isCloud ? .cloud : .server }
    /// Effective Confluence edition: Cloud uses `.cloud`, otherwise `.dataCenter`.
    private var confluenceEdition: ConfluenceEdition { isCloud ? .cloud : .dataCenter }

    /// Resolved JIRA base URL for the current mode.
    private var effectiveJiraURL: URL? {
        URL(string: isCloud ? cloudURL : jiraURL)
    }

    /// Resolved Confluence base URL.
    ///
    /// Cloud: same site URL as JIRA — **without** `/wiki`. The REST client's
    /// `cloudURL()` helper already prepends `/wiki/api/v2/` to every path, so
    /// including `/wiki` here would produce a double `/wiki/wiki/…` URL.
    ///
    /// Server / Data Center: the individual Confluence URL entered by the user.
    private var effectiveConfluenceURL: URL? {
        if isCloud {
            return URL(string: cloudURL)
        }
        return URL(string: confluenceURL)
    }

    private static func trimTrailingSlash(_ s: String) -> String {
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    private var urlsValid: Bool {
        (!enableJira || effectiveJiraURL != nil)
            && (!enableConfluence || effectiveConfluenceURL != nil)
    }

    /// Non-nil when any active URL uses a scheme other than `https` (e.g. plain
    /// `http://`). Basic / Bearer tokens are sent in clear text over HTTP, so
    /// the UI shows a warning and blocks save.
    private var httpsWarning: String? {
        if isCloud {
            if let url = effectiveJiraURL ?? effectiveConfluenceURL,
               url.scheme?.lowercased() != "https" {
                return "URL must start with https://"
            }
        } else {
            if enableJira, let url = effectiveJiraURL,
               url.scheme?.lowercased() != "https" {
                return "JIRA URL must start with https://"
            }
            if enableConfluence, let url = effectiveConfluenceURL,
               url.scheme?.lowercased() != "https" {
                return "Confluence URL must start with https://"
            }
        }
        return nil
    }

    private var tokenAvailable: Bool {
        // Anonymous access needs no credential.
        if method == .anonymous { return true }
        return !token.isEmpty || (!isNew && !keychainKeyChanged)
    }

    private var isValid: Bool {
        !name.isEmpty && hasProduct && urlsValid && httpsWarning == nil && tokenAvailable
    }

    private var canVerify: Bool {
        hasProduct && urlsValid && httpsWarning == nil && tokenAvailable
    }

    private var account: String { method.keychainAccount(email: email) }

    // MARK: - Verify

    @MainActor
    private func verify() async {
        verifyState = .running
        do {
            let auth: AuthProvider
            if method == .anonymous {
                auth = NoneAuth()
            } else {
                let resolvedToken: String
                if !token.isEmpty {
                    resolvedToken = token
                } else if !isNew {
                    resolvedToken = try KeychainManager().serverPassword(serverID: serverID, account: account)
                } else {
                    throw AtlassianError.missingCredentials
                }

                auth = method == .apiToken
                    ? APITokenAuth(email: email, token: resolvedToken)
                    : PATAuth(token: resolvedToken)
            }

            var summaries: [String] = []

            if enableJira, let url = effectiveJiraURL {
                let cfg = JiraInstanceConfig(name: name.isEmpty ? "verify" : name,
                                             baseURL: url, edition: jiraEdition)
                let client = JiraRESTClient(config: cfg, auth: auth)
                try await client.serverInfo()
                let projects = try await client.listProjects()
                summaries.append("JIRA · \(projects.count) project\(projects.count == 1 ? "" : "s")")
            }

            if enableConfluence, let url = effectiveConfluenceURL {
                let cfg = ConfluenceInstanceConfig(name: name.isEmpty ? "verify" : name,
                                                   baseURL: url, edition: confluenceEdition)
                let client = ConfluenceRESTClient(config: cfg, auth: auth)
                let spaces = try await client.listSpaces(cursor: nil, limit: 250).items
                summaries.append("Confluence · \(spaces.count) space\(spaces.count == 1 ? "" : "s")")
            }

            verifyState = .success("Connected · " + summaries.joined(separator: " · "))
        } catch {
            verifyState = .failure(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let e = error as? JiraAPIError {
            switch e {
            case .unauthorized: return unauthorizedMessage
            case .forbidden: return forbiddenMessage
            case .missingCredentials: return "No token available — enter the token first"
            case .serverError(let status): return "Server error (HTTP \(status))"
            case .invalidURL: return "Invalid URL"
            case .rateLimited: return "Rate limited — try again later"
            case .decoding(let detail): return "Unexpected response — \(detail)"
            case .transport(let detail): return "Network error — \(detail)"
            default: break
            }
        }
        if let e = error as? AtlassianError {
            switch e {
            case .unauthorized: return unauthorizedMessage
            case .forbidden: return forbiddenMessage
            case .notFound: return "Endpoint not found — check the URL"
            case .missingCredentials: return "No token available — enter the token first"
            case .serverError(let status): return "Server error (HTTP \(status))"
            case .invalidURL: return "Invalid URL"
            case .rateLimited: return "Rate limited — try again later"
            case .decoding(let detail): return "Unexpected response — \(detail)"
            case .transport(let detail): return "Network error — \(detail)"
            default: return "Connection failed"
            }
        }
        let msg = error.localizedDescription
        return msg.isEmpty ? "Connection failed" : msg
    }

    /// Message for HTTP 401. In anonymous mode there are no credentials to
    /// check, so guide the user toward authenticated access instead.
    private var unauthorizedMessage: String {
        method == .anonymous
            ? "This site requires sign-in — switch to API Token or PAT"
            : "Authentication failed — check credentials"
    }

    /// Message for HTTP 403. In anonymous mode the content isn't publicly
    /// accessible, so suggest authenticating rather than "check permissions".
    private var forbiddenMessage: String {
        method == .anonymous
            ? "Not publicly accessible — switch to API Token or PAT"
            : "Access denied — check permissions"
    }

    // MARK: - Save

    private func save() {
        saveError = nil
        guard urlsValid else { saveError = "One or more URLs are invalid."; return }

        if method == .anonymous {
            // Anonymous access stores no credential. If the server previously
            // used a token-based method, remove the now-orphaned Keychain entry.
            if let origMethod = originalMethod, origMethod != .anonymous {
                let origAccount = origMethod.keychainAccount(email: originalEmail)
                do {
                    try KeychainManager().deleteServerPassword(serverID: serverID, account: origAccount)
                } catch {
                    serverEditorLogger.error("Failed to delete orphaned Keychain entry (serverID=\(serverID, privacy: .public), account=\(origAccount, privacy: .private)): \(error.localizedDescription, privacy: .public)")
                }
            }
        } else if !token.isEmpty {
            do {
                try KeychainManager().setServerPassword(token, serverID: serverID, account: account)
            } catch {
                serverEditorLogger.error("Keychain save failed: \(error.localizedDescription, privacy: .public)")
                saveError = "Could not save the credential to the Keychain. \(error.localizedDescription)"
                return
            }
            // Delete the old credential entry only after the new one is stored
            // successfully, so a delete failure can never leave the server
            // without any credential. The account key changes when the auth
            // method or email changes; leaving the stale entry would orphan a
            // token in the shared Keychain. A failure here is non-fatal (the new
            // credential is already saved) but must not be silently discarded.
            if keychainKeyChanged, let origMethod = originalMethod {
                let origAccount = origMethod.keychainAccount(email: originalEmail)
                do {
                    try KeychainManager().deleteServerPassword(serverID: serverID, account: origAccount)
                } catch {
                    serverEditorLogger.error("Failed to delete orphaned Keychain entry (serverID=\(serverID, privacy: .public), account=\(origAccount, privacy: .private)): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let jiraConn: Server.JiraConnection? = enableJira
            ? effectiveJiraURL.map { Server.JiraConnection(url: $0, edition: jiraEdition) }
            : nil
        let confluenceConn: Server.ConfluenceConnection? = enableConfluence
            ? effectiveConfluenceURL.map { Server.ConfluenceConnection(url: $0, edition: confluenceEdition) }
            : nil

        let server = Server(
            id: serverID,
            name: name,
            jira: jiraConn,
            confluence: confluenceConn,
            auth: Server.Auth(method: method, email: method == .apiToken ? email : nil)
        )
        onSave(server)
    }
}
