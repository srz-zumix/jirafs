import AppKit
import Foundation

/// Custom "About jirafs" panel that augments the standard macOS about panel
/// with the bundled third-party license notices (NOTICE.txt) shown in the
/// scrollable credits area.
enum AboutPanel {
    @MainActor
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        // Hide the build number (CFBundleVersion / CURRENT_PROJECT_VERSION)
        // shown in parentheses; only the marketing version is displayed.
        options[.version] = ""
        if let credits = creditsAttributedString() {
            options[.credits] = credits
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    /// Load the bundled `NOTICE.txt` and render it as monospaced credits text.
    /// Returns `nil` when the resource is missing so the panel falls back to
    /// the default credits.
    private static func creditsAttributedString() -> NSAttributedString? {
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }
}
