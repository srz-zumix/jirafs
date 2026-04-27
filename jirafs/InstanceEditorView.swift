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
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(originalName == nil ? "New Instance" : "Edit Instance").font(.title2)
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $urlString)
                Picker("Edition", selection: $edition) {
                    Text("Cloud").tag(JiraEdition.cloud)
                    Text("Server").tag(JiraEdition.server)
                }
                Picker("Auth Method", selection: $method) {
                    Text("API Token").tag(Configuration.AuthEntry.Method.apiToken)
                    Text("PAT").tag(Configuration.AuthEntry.Method.pat)
                }
                if method == .apiToken {
                    TextField("Email", text: $email)
                }
                SecureField("Token", text: $token)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private var isValid: Bool {
        !name.isEmpty && URL(string: urlString) != nil && !token.isEmpty
    }

    private func save() {
        guard let url = URL(string: urlString) else { return }
        do {
            let account = method == .apiToken ? email : "pat"
            try KeychainManager().setPassword(token, instanceName: name, account: account)
        } catch {
            print("Keychain save failed: \(error)")
            return
        }
        let auth = Configuration.AuthEntry(method: method, email: method == .apiToken ? email : nil)
        let entry = Configuration.InstanceEntry(name: name, type: edition, url: url, auth: auth)
        onSave(entry)
    }
}
