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
- TTL-based in-memory cache + optional AES-GCM encrypted disk cache
- Optional `issue.html` / `{Title}.html` formatted view

## Requirements

- macOS 15.4+ (Sequoia)
- Xcode 16.4+
- Swift 6.0

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

## Documentation

- [Technical Specification](Documentation/SPEC.md)
- [Development Guide](Documentation/INSTRUCTIONS.md)

## License

See [LICENSE](LICENSE).

This project bundles third-party components. See [NOTICE.txt](NOTICE.txt) for their licenses and attributions.
