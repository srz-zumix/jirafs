import Foundation
import JiraAPI
import JiraFSCore

/// Resolves the `~/Library/Application Support/jirafs/config.json` path used
/// by both the host app and the FSKit extension.
enum AppConfig {
    static func configURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("jirafs/config.json")
    }

    static func load() -> Configuration {
        (try? Configuration.load(from: configURL())) ?? Configuration()
    }

    static func save(_ config: Configuration) throws {
        try config.save(to: configURL())
    }
}
