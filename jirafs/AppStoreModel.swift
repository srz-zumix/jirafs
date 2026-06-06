import SwiftUI
import AtlassianCore

/// Shared, observable wrapper around the `AppStore` source of truth. A single
/// instance is created by the app and injected into both the main window and
/// the Preferences scene so server/mount edits stay in sync. Every mutation
/// persists immediately (which also regenerates the derived extension configs).
@MainActor
final class AppStoreModel: ObservableObject {
    @Published var store: AppStore
    /// Selected mount id in the main window.
    @Published var selection: String?

    init() {
        self.store = AppConfig.loadAppStore()
    }

    func reload() {
        store = AppConfig.loadAppStore()
    }

    private func persist() {
        do { try AppConfig.saveAppStore(store) }
        catch { print("Failed to save app store: \(error)") }
    }

    // MARK: - Servers

    var servers: [Server] {
        store.servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func server(id: String) -> Server? { store.server(id: id) }

    func upsertServer(_ server: Server) {
        if let idx = store.servers.firstIndex(where: { $0.id == server.id }) {
            store.servers[idx] = server
        } else {
            store.servers.append(server)
        }
        persist()
    }

    /// Mounts referencing a server (deletion of a referenced server is blocked
    /// in the UI).
    func mounts(forServer serverID: String) -> [Mount] {
        store.mounts(forServer: serverID)
    }

    func deleteServer(_ server: Server) {
        store.servers.removeAll { $0.id == server.id }
        // Remove the shared credential. Account follows the configured method.
        let account = server.auth.method.keychainAccount(email: server.auth.email)
        try? KeychainManager().deleteServerPassword(serverID: server.id, account: account)
        persist()
    }

    // MARK: - Mounts

    var mounts: [Mount] {
        store.mounts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func mount(id: String) -> Mount? { store.mounts.first { $0.id == id } }

    func upsertMount(_ mount: Mount) {
        if let idx = store.mounts.firstIndex(where: { $0.id == mount.id }) {
            store.mounts[idx] = mount
        } else {
            store.mounts.append(mount)
        }
        persist()
    }

    func deleteMount(_ mount: Mount) {
        store.mounts.removeAll { $0.id == mount.id }
        // Cache (key + files) is namespaced by the mount id.
        try? KeychainManager().deleteCacheKey(instanceName: mount.id, product: mount.product.fsType)
        persist()
    }

    func setAutoMount(_ enabled: Bool, for mount: Mount) {
        guard let idx = store.mounts.firstIndex(where: { $0.id == mount.id }) else { return }
        store.mounts[idx].autoMount = enabled
        persist()
    }

    // MARK: - Cache TTL defaults

    func saveCacheSettings() {
        persist()
    }
}
