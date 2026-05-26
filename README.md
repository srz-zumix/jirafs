# jirafs

Mount your JIRA data as a macOS filesystem.  
Built on Apple [FSKit](https://developer.apple.com/documentation/FSKit) (FSUnaryFileSystem), jirafs exposes JIRA projects and issues as ordinary files and directories accessible with any standard tool.

> 日本語ドキュメントは [README.ja.md](README.ja.md) を参照してください。

## Features

- Supports both JIRA Cloud and Server
- **Multiple JIRA instances** — mount each instance at its own path simultaneously
- **Per-instance project filtering** — expose all projects or limit to specific project keys
- Issues represented as directories (`summary.txt`, `description.md`, `metadata.json`, `comments/`, `attachments/`)
- Browse JIRA data with standard UNIX tools (`ls`, `cat`, `grep`, `find`, …)
- Read-only mount
- Credentials stored securely in macOS Keychain (shared Access Group)
- TTL-based in-memory cache + optional AES-GCM encrypted disk cache
- Optional `issue.html` formatted view per issue

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

Project filtering and other options (disk cache, HTML view) are configured per instance in the host app.

## Documentation

- [Technical Specification](Documentation/SPEC.md)
- [Development Guide](Documentation/INSTRUCTIONS.md)

## License

See [LICENSE](LICENSE).
