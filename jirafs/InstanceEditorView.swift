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
    /// Comma-separated project keys to allow. Empty string = all projects.
    @State private var projectFilter: String

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
            allowedProjectKeys: parsedKeys.isEmpty ? nil : parsedKeys
        )
        onSave(entry)
    }
}
