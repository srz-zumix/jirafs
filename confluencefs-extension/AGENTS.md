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
└── pages/
    ├── {Page Title}.html  # Self-contained HTML view (only when HTML mode is enabled)
    └── {Page Title}/      # One directory per page (sibling of the .html file)
        ├── page.md          # Markdown-rendered page body
        ├── .metadata.json   # Structured page metadata (JSON)
        ├── .labels.txt      # One label per line
        ├── .comments/       # One .md file per comment
        │   └── NNN_author_YYYY-MM-DD.md  # NNN = 1-based comment index
        ├── .attachments/    # Raw attachment files
        │   └── <filename> # Original filename (sanitized; duplicates get " (N)" suffix)
        ├── {Child Page Title}.html  # Child page HTML (HTML mode only)
        └── {Child Page Title}/      # Child page directory (recursive)
```

## Notes for Agents

- Everything is **read-only**: writes, renames, and deletes return errors.
- Page titles are unique within a space; the path uses a sanitized title and is
  resolved internally to the stable Confluence page id.
- `page.md` is rendered from the Confluence storage format (XHTML) or ADF.
  When rendering fails, a raw-fallback marker comment precedes the original body.
- Data is cached with a TTL; recently changed pages may briefly show stale content.
