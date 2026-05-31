import Foundation
import os

/// Logging facility for jirafs / confluencefs (subsystem: `com.zumix.jirafs`).
public enum AtlassianLog {
    public static let subsystem = "com.zumix.jirafs"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
