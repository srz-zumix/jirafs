import Foundation
import os

/// Logging facility for jirafs (subsystem: `com.zumix.jirafs`).
public enum JiraLog {
    public static let subsystem = "com.zumix.jirafs"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
