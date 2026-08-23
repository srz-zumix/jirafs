# CONFLUENCEFS — AI Agent Guide

This mount exposes Confluence content as a **read-only** filesystem via macOS FSKit.

## Top-level Layout

```
/
├── spaces/                # Confluence spaces visible to this instance
├── AGENTS.md              # This guide
├── .confluencefs/         # Internal placeholder directory
│   └── config.json        # Always returns `{}` (real config is not exposed)
└── .metadata_never_index  # Marker to suppress Spotlight indexing
```

## Space and Page Layout

Pages are nested: child pages live inside their parent page's directory.

```
/spaces/{SPACE_KEY}/
├── .space.json            # Structured metadata for the space (JSON)
├── AGENTS.md              # Copy of this guide (per-space)
└── pages/
    ├── AGENTS.md           # Copy of this guide (in pages/ directory)
    ├── {Page Title}.html  # Self-contained HTML view (only when HTML mode is enabled)
    └── {Page Title}/      # One directory per page (sibling of the .html file)
        ├── page.md          # Markdown-rendered page body
        ├── .metadata.json   # Structured page metadata (JSON)
        ├── .labels.txt      # One label per line
        ├── .comments/       # One .md file per comment
        │   └── NNN_author_YYYY-MM-DD.md  # NNN = 1-based comment index
        ├── .attachments/    # Raw attachment files
        │   └── <filename> # Original filename (sanitized; duplicates get " (N)" suffix)
        ├── {Folder Title}/     # Confluence folder (Cloud only; recursive)
        ├── {Whiteboard Title}/ # Confluence whiteboard (Cloud only)
        │   ├── .metadata.json    # Whiteboard metadata (JSON), including its webURL
        │   ├── whiteboard.md     # Canvas text via Rovo MCP (only when enabled for the mount)
        │   ├── whiteboard.json   # Raw Rovo MCP response (only when enabled for the mount)
        │   ├── whiteboard.svg    # Canvas drawn as SVG (only when enabled for the mount)
        │   └── ...               # Pages/folders/whiteboards nested under the board
        ├── {Child Page Title}.html  # Child page HTML (HTML mode only)
        └── {Child Page Title}/      # Child page directory (recursive)
```

## File Descriptions

| Path | Format | Description |
| ------ | -------- | ------------- |
| `.space.json` | JSON | Space key, name, description, and related metadata |
| `page.md` | Markdown | Rendered page body (Confluence storage format/XHTML or ADF → Markdown) |
| `.metadata.json` | JSON | Page id, title, spaceId, parentId, version, author, createdAt, webURL |
| `.labels.txt` | Plain text | One label per line (prefix-qualified when present) |
| `.comments/NNN_author_YYYY-MM-DD.md` | Markdown | Individual comment body; `NNN` is 1-based index for stable ordering |
| `.attachments/<filename>` | Binary | Attachment downloaded lazily on read (bounded range requests; never fully buffered) |
| `{Page Title}.html` | HTML | Self-contained view with body and comments (only when HTML mode is enabled) |
| `{Whiteboard Title}/.metadata.json` | JSON | Whiteboard id, title, spaceId, parentId, author, createdAt, webURL |
| `{Whiteboard Title}/whiteboard.md` | Markdown | Canvas rendered to Markdown from the Atlassian Rovo MCP server (beta): node texts in canvas reading order. Present only when the mount enables it |
| `{Whiteboard Title}/whiteboard.json` | JSON | The Rovo MCP response verbatim, including node geometry, colours and edges. Present only when the mount enables it |
| `{Whiteboard Title}/whiteboard.svg` | SVG | Approximate drawing of the canvas: sticky notes, freehand strokes and connectors are redrawn; embedded images become dashed placeholders labelled with their mimeType, native size and `fileId` prefix. Present only when the mount enables it |

## Notes for Agents

- Everything is **read-only**: writes, renames, and deletes return `EROFS`/`ENOTSUP`.
- **Error semantics**: A missing space, page, or file returns `ENOENT`; authentication or permission failures return `EACCES`; rate-limited requests return `EAGAIN`; transient server, network, or decoding errors return `EIO`.
- **Sanitized names**: Page titles and attachment filenames are sanitized (slashes, control characters, and leading dots become underscores). Duplicate names within a directory get a ` (N)` suffix. Page titles are unique within a space; the sanitized path is resolved internally to the stable Confluence page id.
- **Restricted/archived filtering**: By default, view-restricted pages are hidden (`includeRestricted` defaults to off) and archived pages are excluded (`includeArchived` defaults to off). Both are controlled per mount in the host app. A page that exists in Confluence but is absent here may be intentionally filtered out, not missing.
- **Whiteboards**: Cloud-only. A whiteboard directory always contains `.metadata.json` plus any pages/folders/whiteboards nested under it. The canvas itself is not available through the Confluence REST API; when the mount enables the experimental Rovo MCP integration it also contains `whiteboard.md`, `whiteboard.json` and `whiteboard.svg` (all three share one fetch). Otherwise, open `webURL` in a browser to see the board. Folders and whiteboards without a parent (top level of a space) are not listed, because Confluence Cloud offers no API to enumerate them.
- **Whiteboard images cannot be downloaded**: images on a board live in Atlassian Media Services and are not attachments. No Confluence API token reaches them — the `api.atlassian.com` gateway 401s every `/wiki/rest/api/media/*` path because no OAuth scope covers it, and on the site host `/wiki/rest/api/media/token` returns 404. Do not re-investigate; see `Documentation/SPEC.md` for the full probe results.
- **File timestamps**:
  - `page.md`, `.metadata.json`, `{Title}.html` → birthtime = page `created`; mtime is derived from the page `version` (advances one second per version past creation), so it moves forward on each edit. It is **not** a true wall-clock "last edited" time — use the `version` field in `.metadata.json` for exact change tracking.
  - `.comments/*.md` → mtime = birthtime = comment `created`.
  - `.attachments/<filename>` → timestamps are not derived from Confluence; do not rely on them.
- **Rendering**: `page.md` is rendered from the Confluence storage format (XHTML) or ADF. When rendering fails, a raw-fallback marker comment precedes the original body.
- **Cache TTL**: Data is cached with a TTL configured in the host app's Cache Settings (changes take effect after remount). Recently changed pages may briefly show stale content; re-reading after the background refresh completes returns fresh data.

## Efficiency Notes

- **Pages are recursively nested**: child pages live inside their parent's directory, so a full `find .` traverses the entire page tree and can be slow on large spaces. Prefer navigating to known page paths over enumerating everything.
- **Slow first access is expected when cache is cold**: the first `open()` of an uncached file triggers a Confluence API call. Subsequent reads within the TTL window are served from cache and are fast. If a read seems slow, **do not abort** — wait for the first read to complete.
