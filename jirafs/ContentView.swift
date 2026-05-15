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

    func update(original: Configuration.InstanceEntry, updated: Configuration.InstanceEntry) {
        configuration.instances.removeAll { $0.id == original.id }
        configuration.instances.append(updated)
        save()
    }

    func remove(name: String) {
        configuration.instances.removeAll { $0.name == name }
        save()
    }
}

struct ContentView: View {
    @StateObject private var model = InstanceListModel()
    @State private var showingAddEditor = false
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
                        showingAddEditor = true
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
        .sheet(isPresented: $showingAddEditor) {
            InstanceEditorView(initial: nil) { entry in
                model.add(entry)
                showingAddEditor = false
            } onCancel: {
                showingAddEditor = false
            }
        }
        .sheet(item: $editingInstance) { entry in
            InstanceEditorView(initial: entry) { updated in
                model.update(original: entry, updated: updated)
                editingInstance = nil
            } onCancel: {
                editingInstance = nil
            }
        }
    }
}

struct InstanceDetailView: View {
    let entry: Configuration.InstanceEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

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

                MountControlView(entry: entry)
                    .id(entry.id)

                Spacer()
            }
            .padding()
        }
    }
}
