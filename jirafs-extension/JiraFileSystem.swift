#if canImport(FSKit)
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
        _ resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        guard let urlResource = resource as? FSGenericURLResource else {
            reply(nil, FSKitError.notFound); return
        }
        let url = urlResource.url
        guard let normalized = JiraFileSystem.normalize(url: url) else {
            reply(nil, FSKitError.notFound); return
        }
        do {
            let (instanceName, config, auth) = try JiraFileSystem.lookupInstance(for: normalized)
            let client = JiraRESTClient(config: config, auth: auth)
            let dataSource = IssueDataSource(client: client)
            let isReadOnly = options.taskOptions.contains("ro") || !options.taskOptions.contains("rw")
            let volume = JiraVolume(name: instanceName, dataSource: dataSource, isReadOnly: isReadOnly)
            logger.info("loaded volume for \(instanceName, privacy: .public)")
            reply(volume, nil)
        } catch {
            reply(nil, FSKitError.from(error))
        }
    }

    func unloadResource(_ resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func probeResource(_ resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let urlResource = resource as? FSGenericURLResource,
              JiraFileSystem.normalize(url: urlResource.url) != nil else {
            reply(.notRecognized, nil); return
        }
        reply(.usable(name: "jirafs", containerID: nil), nil)
    }

    func didFinishLoading() {
        logger.info("JiraFileSystem loaded")
    }

    // MARK: - URL handling

    /// Convert `jira://host` or `https://host` into a normalized
    /// `https://host` JIRA base URL.
    static func normalize(url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "jira" {
            components.scheme = "https"
        }
        guard components.scheme == "https", components.host != nil else { return nil }
        components.path = ""
        return components.url
    }

    /// Resolve a normalized base URL into instance config + auth provider by
    /// reading the host app's configuration file and Keychain.
    static func lookupInstance(for url: URL) throws -> (String, JiraInstanceConfig, AuthProvider) {
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        guard let entry = config.instances.first(where: { entry in
            entry.url.host == url.host
        }) else {
            throw JiraAPIError.missingCredentials
        }
        let keychain = KeychainManager()
        let cfg = JiraInstanceConfig(name: entry.name, baseURL: url, edition: entry.type)
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
#endif
