# JIRAFS — AI Agent Guide

This mount exposes Jira data as a **read-only** filesystem via macOS FSKit.

## Top-level Layout

```
/
├── projects/              # Jira projects visible to this instance
├── AGENTS.md              # This guide
├── .jirafs/               # Internal placeholder directory
│   └── config.json        # Always returns `{}` (real config is not exposed)
└── .metadata_never_index  # Marker to suppress Spotlight indexing
```

## Project and Issue Layout

```
/projects/{PROJECT_KEY}/
├── .project.json          # Structured metadata for the project (JSON)
└── issues/
    └── {ISSUE_KEY}/       # One directory per issue (e.g. PROJ-123)
        ├── summary.txt    # One-line issue summary (plain text)
        ├── description.md # Markdown-rendered issue description
        ├── metadata.json  # Full structured issue metadata (JSON)
        ├── comments/      # One .md file per comment
        │   └── NNN_author_YYYY-MM-DD.md  # NNN = 1-based comment index
        ├── attachments/   # Raw attachment files
        │   └── <filename> # Original filename (sanitized; duplicates get " (N)" suffix)
        └── issue.html     # Self-contained HTML view (absent when HTML mode is disabled)
```

## File Descriptions

| Path | Format | Description |
| ------ | -------- | ------------- |
| `.project.json` | JSON | Project key, name, description, lead, etc. |
| `summary.txt` | Plain text | Single-line issue summary |
| `description.md` | Markdown | Rendered description (Jira wiki markup → Markdown) |
| `metadata.json` | JSON | Issue type, status, priority, assignee, reporter, labels, fix versions, custom fields, etc. |
| `comments/NNN_author_YYYY-MM-DD.md` | Markdown | Individual comment body; `NNN` is 1-based index for stable ordering |
| `attachments/<filename>` | Binary | Attachment downloaded on first access (cached in memory) |
| `issue.html` | HTML | All-in-one view with description, comments, and attachment links |

## Notes for Agents

- **Read-only**: All write operations (create, rename, remove) return ENOTSUP.
- **Sanitized filenames**: Slashes, control characters, and leading dots in attachment names are replaced with underscores. Duplicate names get ` (N)` suffixes.
- **Stale-while-revalidate cache**: Directory listings and file contents may be slightly stale on first access while a background refresh runs in the background. Re-reading a file after the refresh completes gives fresh data; refresh is triggered automatically and requires no action from the agent.
- **Cache TTL**: Controlled via the host app's Cache Settings (changes take effect after remount).
- **Efficient scanning**: To inspect an issue, read `summary.txt` first (cheap), then `metadata.json`, then `description.md` as needed. Avoid opening `attachments/` unless necessary. Check for the presence of `issue.html` before reading it; its absence means HTML mode is disabled for this mount.
- **Project filter**: Only projects configured in the host app are visible under `projects/`.
