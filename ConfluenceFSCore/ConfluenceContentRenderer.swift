import Foundation
import AtlassianCore
import ConfluenceAPI

/// Renders a Confluence page/comment body to Markdown, dispatching on the body
/// format: storage / server-rendered `view` XHTML via `StorageFormatRenderer`,
/// Cloud ADF JSON via the shared `ADFRenderer`.
public enum ConfluenceContentRenderer {
    public static let rawFallbackMarker = "<!-- confluencefs: raw fallback -->"

    public static func renderBody(_ body: ConfluenceBody?) -> String {
        guard let body else { return "" }
        switch body.format {
        case .storage, .view:
            // Storage XHTML and the server-rendered `view` HTML both use standard
            // (X)HTML tags, so the same tokenizer/walker renders both. With `view`,
            // dynamic macros (e.g. Table of Contents) arrive already expanded.
            return StorageFormatRenderer.render(body.value, rawFallbackMarker: rawFallbackMarker)
        case .atlasDocFormat:
            guard let data = body.value.data(using: .utf8),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return StorageFormatRenderer.rawFallback(body.value, marker: rawFallbackMarker)
            }
            return ADFRenderer.render(json, rawFallbackMarker: rawFallbackMarker)
        }
    }
}
