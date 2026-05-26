# jirafs

Mount your JIRA data as a macOS filesystem.  
Built on Apple [FSKit](https://developer.apple.com/documentation/FSKit) (FSUnaryFileSystem), jirafs exposes JIRA projects and issues as ordinary files and directories accessible with any standard tool.

> 日本語ドキュメントは [README.ja.md](README.ja.md) を参照してください。

## Features

- Supports both JIRA Cloud and Server
- **1 mount = 1 JIRA instance** — simple, predictable mapping
- Issues represented as directories (`summary.txt`, `description.md`, `metadata.json`, `comments/`, `attachments/`)
- Browse JIRA data with standard UNIX tools (`ls`, `cat`, `grep`, `find`, …)
- Read-only mount
- Credentials stored securely in macOS Keychain (shared Access Group)
- TTL-based in-memory cache + optional AES-GCM encrypted disk cache

## Requirements

- macOS 15.4+ (Sequoia)
- Xcode 16.4+
- Swift 6.0

## Filesystem Layout

```text
~/jirafs/
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

Mount from the host app UI or the command line.

```bash
# Create the mount point
mkdir ~/jirafs

# Mount (read-only recommended)
mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs

# Access JIRA data
ls ~/jirafs/projects/
cat ~/jirafs/projects/PROJ/issues/PROJ-1/summary.txt

# Unmount
umount ~/jirafs
```

> To use multiple JIRA instances simultaneously, mount each one at a separate path.

## Documentation

- [Technical Specification](Documentation/SPEC.md)
- [Development Guide](Documentation/INSTRUCTIONS.md)

## License

See [LICENSE](LICENSE).
