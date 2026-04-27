import SwiftUI
import JiraAPI
import JiraFSCore

@MainActor
final class InstanceListModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var selection: Configuration.InstanceEntry.ID?

    init() {
        self.configuration = AppConfig.load()
    }

    func reload() {
        configuration = AppConfig.load()
    }

    func save() {
        do {
            try AppConfig.save(configuration)
        } catch {
            // Surfacing in UI is left to the caller.
            print("Failed to save config: \(error)")
        }
    }

    func add(_ entry: Configuration.InstanceEntry) {
        configuration.instances.removeAll { $0.name == entry.name }
        configuration.instances.append(entry)
        save()
    }

    func remove(name: String) {
        configuration.instances.removeAll { $0.name == name }
        save()
    }
}

struct ContentView: View {
    @StateObject private var model = InstanceListModel()
    @State private var showingEditor = false
    @State private var editingInstance: Configuration.InstanceEntry?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.configuration.instances) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.name).font(.headline)
                        Text(entry.url.host ?? entry.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingInstance = nil
                        showingEditor = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Instances")
            .frame(minWidth: 220)
        } detail: {
            if let id = model.selection,
               let entry = model.configuration.instances.first(where: { $0.id == id }) {
                InstanceDetailView(entry: entry,
                                   onEdit: {
                    editingInstance = entry
                    showingEditor = true
                },
                                   onDelete: {
                    model.remove(name: entry.name)
                    model.selection = nil
                })
            } else {
                ContentUnavailableView("No Instance Selected",
                                       systemImage: "externaldrive",
                                       description: Text("Add a JIRA instance to get started."))
            }
        }
        .sheet(isPresented: $showingEditor) {
            InstanceEditorView(initial: editingInstance) { entry in
                model.add(entry)
                showingEditor = false
            } onCancel: {
                showingEditor = false
            }
        }
    }
}

struct InstanceDetailView: View {
    let entry: Configuration.InstanceEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.name).font(.title)
            Group {
                LabeledContent("URL", value: entry.url.absoluteString)
                LabeledContent("Edition", value: entry.type.rawValue)
                LabeledContent("Auth", value: entry.auth.method.rawValue)
                if let email = entry.auth.email {
                    LabeledContent("Email", value: email)
                }
            }
            MountControlView(entry: entry)
            Divider()
            HStack {
                Button("Edit", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
            }
            Spacer()
        }
        .padding()
    }
}
