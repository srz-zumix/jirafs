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
- **File timestamps**: Each file's modification time (mtime) and creation time (birthtime) reflect the corresponding Jira timestamps:
  - `summary.txt`, `description.md`, `metadata.json`, `issue.html` → mtime = ticket `updated`, birthtime = ticket `created`
  - `comments/*.md` → mtime = comment `updated`, birthtime = comment `created`
  - `attachments/<filename>` → mtime = birthtime = attachment `created`
  - Directory entries (issue dirs, etc.) do not follow this rule; their mtime is managed internally.
- **Stale-while-revalidate cache**: Directory listings and file contents may be slightly stale on first access while a background refresh runs in the background. Re-reading a file after the refresh completes gives fresh data; refresh is triggered automatically and requires no action from the agent.
- **Cache TTL**: Controlled via the host app's Cache Settings (changes take effect after remount).
- **Per-file reading order**: To inspect an issue, read `summary.txt` first (cheap), then `metadata.json`, then `description.md` as needed. Avoid opening `attachments/` unless necessary. Check for the presence of `issue.html` before reading it; its absence means HTML mode is disabled for this mount.
- **Project filter**: Only projects configured in the host app are visible under `projects/`.

## Efficient Query Patterns

### Listing issues/ can be slow when there are many tickets

`issues/` may contain thousands of entries. A full directory listing (`ls`, `find .`) fetches all issue keys from Jira before returning, which can take tens of seconds on large projects.

- For **small projects** (hundreds of issues or fewer), a plain `ls` is fine.
- For **large projects**, avoid listing everything at once. Prefer reading known keys directly or use the high-numbered key approach below.

### Recently *created* issues — use high-numbered keys

Issue keys are assigned sequentially, so the highest-numbered keys are the most recently **created**. This does NOT mean they were recently updated — an old low-numbered issue may have been updated today. Use this approach only when you care about creation order:

```sh
# List only the 20 most-recently-numbered issues
ls issues/ | sort -t- -k2 -rn | head -20
```

Or read a specific range of metadata files directly if you know the approximate key range:

```sh
# Read metadata for the last ~50 issues in parallel
for key in PROJ-1580 PROJ-1581 PROJ-1582 PROJ-1583 PROJ-1584; do
  cat issues/$key/metadata.json &
done
wait
```

### Filtering by date — read metadata in batch, not one-by-one

When filtering issues by a date field, avoid reading files one-by-one in a sequential loop. Read `metadata.json` for a set of candidate issues and filter client-side.

Which issues to include as candidates depends on what you are filtering by:

- **Filter by `created`**: High-numbered keys are recently created. Scan from the top and stop when `created` goes out of range.
- **Filter by `updated`**: Any issue — regardless of number — may have been recently updated. You cannot use key order as a shortcut; you must scan all issues and filter by the `updated` field client-side.
- **Filter by other fields** (assignee, status, label, etc.): Similarly requires scanning all issues or narrowing candidates by another means first.

`metadata.json` fields useful for filtering: `created`, `updated`, `status`, `assignee`, `labels`, `priority`, `fixVersions`, and custom fields.

### Slow first access is expected when cache is cold

The first `open()` of a file that is not yet in cache triggers a Jira API call. Subsequent accesses within the TTL window are served from cache and are fast. If a file read seems slow, **do not abort** — wait for the first read to complete, then subsequent reads of the same file will be instant.
