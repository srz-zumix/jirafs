import Foundation

/// Sanitizes JIRA-derived strings so they're safe to use as filesystem
/// component names. Prevents path traversal and removes characters illegal on
/// macOS/HFS+/APFS.
public enum FileNameSanitizer {
    /// Replace forbidden characters with `_`.
    public static func sanitize(_ raw: String) -> String {
        // Avoid the special names "." / ".." before trimming dots.
        if raw == "." || raw == ".." {
            return raw + "_"
        }
        var s = raw
        s = s.replacingOccurrences(of: "\0", with: "_")
        // Replace path separators
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "\\", with: "_")
        // Strip control characters
        s = String(s.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 { return "_" }
            return Character(scalar)
        })
        // Trim leading/trailing whitespace and dots
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if s.isEmpty { s = "_" }
        return s
    }

    /// Resolve naming collisions by appending ` (2)`, ` (3)`, ... suffixes
    /// before the file extension.
    public static func deduplicate(_ name: String, taken: inout Set<String>) -> String {
        if !taken.contains(name) {
            taken.insert(name)
            return name
        }
        let (stem, ext) = splitExtension(name)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            n += 1
        }
    }

    private static func splitExtension(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              dot != name.index(before: name.endIndex) else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
