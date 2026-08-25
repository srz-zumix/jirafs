# jirafs

Mount your JIRA and Confluence data as a macOS filesystem.
Built on Apple [FSKit](https://developer.apple.com/documentation/FSKit) (FSUnaryFileSystem), jirafs exposes JIRA projects/issues and Confluence spaces/pages as ordinary files and directories accessible with any standard tool.

> 日本語ドキュメントは [README.ja.md](README.ja.md) を参照してください。

## Features

- Supports both JIRA Cloud and Server, and Confluence Cloud and Data Center
- **Multiple instances** — mount each JIRA/Confluence instance at its own path simultaneously
- **Per-instance filtering** — expose all projects/spaces or limit to specific keys
- JIRA issues represented as directories (`summary.txt`, `description.md`, `metadata.json`, `comments/`, `attachments/`)
- Confluence pages represented as directories (`page.md`, `.metadata.json`, `.labels.txt`, `.comments/`, `.attachments/`) with child pages nested recursively
- Browse data with standard UNIX tools (`ls`, `cat`, `grep`, `find`, …)
- Read-only mount
- Credentials stored securely in macOS Keychain (shared Access Group)
- **Anonymous access** — mount public JIRA/Confluence sites without credentials
- **Whiteboard canvases (experimental)** — Confluence whiteboards can expose `whiteboard.md`, `whiteboard.json` and `whiteboard.svg` via the Atlassian Rovo MCP server (Confluence Cloud with an *API Token (scoped)* only; off by default)
- TTL-based in-memory cache + optional AES-GCM encrypted disk cache
- Background auto-refresh — newly created issues/pages appear while a folder stays open (configurable interval, can be turned off)
- Optional `issue.html` / `{Title}.html` formatted view

## Requirements

- macOS 15.4+ (Sequoia)
- Xcode 16.4+
- Swift 6.0

## API Token Scopes (Confluence Cloud)

When using *API Token (scoped)* authentication, grant only these scopes. The Confluence REST access is read-only and issues nothing but `GET` and `HEAD`, so **no `write:` or `delete:` scope is ever needed**. (The optional Rovo MCP whiteboard integration issues read-only JSON-RPC `POST` requests to Atlassian's MCP endpoint, but these are not governed by Confluence scopes — see the notes below.)

| Scope | Needed for |
| --- | --- |
| `read:attachment:confluence` | `.attachments/` listing and downloads |
| `read:comment:confluence` | `.comments/` |
| `read:folder:confluence` | Folders under a page |
| `read:hierarchical-content:confluence` | Walking the page tree (`direct-children`) |
| `read:label:confluence` | `.labels.txt` |
| `read:page:confluence` | Page bodies and per-space page lists |
| `read:space:confluence` | Listing spaces (`/spaces`) |
| `read:whiteboard:confluence` | Whiteboard metadata and its children |

Add these only if the matching option is enabled:

| Scope | Needed for |
| --- | --- |
| `read:content-details:confluence`, `read:content.restriction:confluence` | Hiding view-restricted pages (the default `includeRestricted = off`, which reads restrictions through the v1 content API) |
| `readonly:content.attachment:confluence` | Only if attachment downloads return 401; the legacy `/wiki/download/...` path is routed by this classic scope |

Notes:

- Scoped tokens are supported for Confluence only. JIRA mounts require a regular API token or a PAT.
- The experimental Rovo MCP whiteboard integration needs a scoped token, but access is governed by your organisation's "connect via API token" setting rather than by a Confluence scope.
- Whiteboard **images** cannot be downloaded by any token. They live in Atlassian Media Services, which no Confluence OAuth scope covers, so they are drawn as labelled placeholders in `whiteboard.svg`.

## Filesystem Layout

Each JIRA instance is mounted at its own path (configurable, default `~/jirafs/<name>`).

```text
~/jirafs/myinstance/
└── projects/
    └── PROJ/
        └── issues/
            └── PROJ-1/
                ├── summary.txt        # One-line issue summary
                ├── description.md     # Description (Markdown)
                ├── metadata.json      # Structured metadata (status, assignee, …)
                ├── issue.html         # Formatted HTML view (when htmlView is enabled)
                ├── comments/          # Comment files
                └── attachments/       # Attached files
```

Each Confluence instance is mounted at its own path (default `~/confluencefs/<name>`). Child pages are nested under their parent page directory.

```text
~/confluencefs/myinstance/
└── spaces/
    └── DOCS/
        ├── .space.json                # Space metadata
        └── pages/
            ├── Getting Started.html    # Formatted view (when htmlView is enabled)
            └── Getting Started/
                ├── page.md             # Page body (Markdown)
                ├── .metadata.json      # Structured metadata
                ├── .labels.txt         # Labels
                ├── .comments/          # Comment files
                ├── .attachments/       # Attached files
                ├── My Whiteboard/      # Whiteboard (Cloud only)
                │   ├── .metadata.json  # Whiteboard metadata (includes webURL)
                │   ├── whiteboard.md   # Canvas text      ┐
                │   ├── whiteboard.json # Raw MCP response │ experimental, off by default
                │   └── whiteboard.svg  # Canvas drawing   ┘
                └── Child Page/         # Child pages nested recursively
                    └── page.md
```

## Installation

### Homebrew (recommended)

```bash
brew install srz-zumix/tap/jirafs
```

### Build from source

See [Development Guide](Documentation/INSTRUCTIONS.md).

## Usage

Configure JIRA instances in the host app (jirafs.app), then mount from the command line or via the app UI.

```bash
# Mount a JIRA instance (path is configured per instance in the app)
mkdir -p ~/jirafs/myinstance
sudo mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs/myinstance

# Multiple instances can be mounted simultaneously
mkdir -p ~/jirafs/work ~/jirafs/personal
sudo mount -F -t jirafs -o ro jira://work.atlassian.net ~/jirafs/work
sudo mount -F -t jirafs -o ro jira://personal.atlassian.net ~/jirafs/personal

# Access JIRA data
ls ~/jirafs/myinstance/projects/
cat ~/jirafs/myinstance/projects/PROJ/issues/PROJ-1/summary.txt

# Unmount
sudo diskutil unmount ~/jirafs/myinstance
```

Confluence instances are configured the same way in the host app and mounted with the `confluencefs` filesystem.

```bash
# Mount a Confluence instance
mkdir -p ~/confluencefs/myinstance
sudo mount -F -t confluencefs -o ro confluence://mycompany.atlassian.net ~/confluencefs/myinstance

# Access Confluence data
ls ~/confluencefs/myinstance/spaces/
cat "~/confluencefs/myinstance/spaces/DOCS/pages/Getting Started/page.md"

# Unmount
sudo diskutil unmount ~/confluencefs/myinstance
```

Project/space filtering and other options (disk cache, HTML view) are configured per instance in the host app.

### Auto-Refresh

FSKit volumes are passive: the kernel only re-enumerates a directory when its modification time changes. To make issues/pages created after a folder was opened appear automatically, each mount runs a background poll that refreshes browsed listings and bumps their mtime (so Finder re-enumerates).

Configure it in the host app under **Preferences → Cache → Auto-Refresh Interval** (separately for JIRA and Confluence):

- **Off** — disable polling (re-open or `ls` again to update)
- **0** (default) — reuse the Issues/Pages cache TTL (polling is disabled too when that TTL is 0)
- **N seconds** — poll at that interval (clamped to 1 s – 1 day)

Changes take effect after remounting.

## Documentation

- [Technical Specification](Documentation/SPEC.md)
- [Development Guide](Documentation/INSTRUCTIONS.md)

## License

See [LICENSE](LICENSE).

This project bundles third-party components. See [NOTICE.txt](NOTICE.txt) for their licenses and attributions.
