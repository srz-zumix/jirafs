import Foundation
import FSKit
import JiraAPI
import JiraFSCore
import os

/// Top-level `FSUnaryFileSystem` that resolves a `jira://` URL into a
/// `JiraVolume`.
@available(macOS 15.4, *)
@objc(JiraFileSystem)
final class JiraFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    let logger = JiraLog.logger("filesystem")

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        do {
            let (instanceName, config, auth) = try JiraFileSystem.lookupInstance()
            let client = JiraRESTClient(config: config, auth: auth)
            let dataSource = IssueDataSource(client: client)
            let isReadOnly = true
            let volume = JiraVolume(name: instanceName, dataSource: dataSource, isReadOnly: isReadOnly)
            logger.info("loaded volume for \(instanceName, privacy: .public)")
            // Transition container state from notReady → ready before handing the
            // volume to fskitd.  Without this, fskitd sees the container still in
            // notReady state and returns EAGAIN to the caller.
            self.containerStatus = .ready
            reply(volume, nil)
        } catch {
            logger.error("loadResource failed: \(error, privacy: .public)")
            reply(nil, FSKitError.from(error))
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        // URL-based resources are recognized by scheme (FSMatchingURLSchemes in Info.plist).
        // Always return usable; actual credential validation happens in loadResource.
        let name = JiraFileSystem.firstInstance()?.name ?? "jirafs"
        // Use deterministic UUID so fskitd recognises the container across the applyResource
        // state machine.  Random UUIDs cause fskitd to treat every attempt as an unknown
        // container and immediately close it (EAGAIN).  Cross-session collisions are
        // avoided by restarting fskitd (launchctl kickstart) before each mount.
        let containerID = FSContainerIdentifier(uuid: JiraFileSystem.deterministicUUID(for: name))
        reply(.usable(name: name, containerID: containerID), nil)
    }

    func didFinishLoading() {
        logger.info("JiraFileSystem loaded")
    }

    // MARK: - Configuration lookup

    static func firstInstance() -> Configuration.InstanceEntry? {
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        return config.instances.first
    }

    static func deterministicUUID(for name: String) -> UUID {
        var bytes = Array<UInt8>(repeating: 0, count: 16)
        for (i, b) in Array(name.utf8).enumerated() { bytes[i % 16] ^= b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Resolve the first configured instance into config + auth provider.
    static func lookupInstance() throws -> (String, JiraInstanceConfig, AuthProvider) {
        guard let entry = firstInstance() else {
            throw JiraAPIError.missingCredentials
        }
        let keychain = KeychainManager()
        let cfg = JiraInstanceConfig(name: entry.name, baseURL: entry.url, edition: entry.type)
        let auth: AuthProvider
        switch entry.auth.method {
        case .apiToken:
            let email = entry.auth.email ?? ""
            let token = try keychain.password(instanceName: entry.name, account: email)
            auth = APITokenAuth(email: email, token: token)
        case .pat:
            let token = try keychain.password(instanceName: entry.name, account: "pat")
            auth = PATAuth(token: token)
        }
        return (entry.name, cfg, auth)
    }

    static func configURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("jirafs/config.json")
    }
}
