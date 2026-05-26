# jirafs

JIRA のデータを macOS のファイルシステムとしてマウントするツール。
Apple [FSKit](https://developer.apple.com/documentation/FSKit) フレームワーク (FSUnaryFileSystem) を利用し、JIRA のプロジェクト・イシューを標準的なファイル操作でアクセス可能にします。

## 特徴

- JIRA Cloud / Server 両対応
- **複数 JIRA インスタンス**の同時マウント対応（インスタンスごとにマウントパスを設定）
- **プロジェクトフィルター**対応—全プロジェクトを公開するか、特定のプロジェクトキーのみに絞り込むかをインスタンスごとに設定可能
- イシューをディレクトリとして表現 (summary.txt, description.md, metadata.json, comments/, attachments/)
- 標準 UNIX ツール (`ls`, `cat`, `grep`, `find`) で JIRA データを操作
- read-only マウント
- macOS Keychain (Access Group 共有) による安全な認証情報管理
- TTL ベースの In-Memory キャッシュ + オプションで AES-GCM 暗号化ディスクキャッシュ
- イシューごとの `issue.html` フォーマットビュー（オプション）

## 対象環境

- macOS 15.4+ (Sequoia)
- Xcode 16.4+
- Swift 6.0

## ファイルシステムレイアウト

各 JIRA インスタンスは独自のマウントパスにマウントされます（設定可能、デフォルトは `~/jirafs/<name>`）。

```text
~/jirafs/myinstance/
└── projects/
    └── PROJ/
        └── issues/
            └── PROJ-1/
                ├── summary.txt        # イシューのサマリー
                ├── description.md     # 説明 (Markdown)
                ├── metadata.json      # メタデータ (status, assignee 等)
                ├── issue.html         # HTML ビュー (htmlView: true 時のみ)
                ├── comments/          # コメントファイル群
                └── attachments/       # 添付ファイル
```

## インストール

### Homebrew（推奨）

```bash
brew install srz-zumix/tap/jirafs
```

### ソースからビルド

[開発手順](Documentation/INSTRUCTIONS.md) を参照してください。

## 使い方

JIRA インスタンスをホストアプリ (jirafs.app) で設定した後、コマンドラインまたはアプリ UI からマウントします。

```bash
# インスタンスをマウント（パスはアプリでインスタンスごとに設定）
mkdir -p ~/jirafs/myinstance
sudo mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs/myinstance

# 複数インスタンスの同時マウント
mkdir -p ~/jirafs/work ~/jirafs/personal
sudo mount -F -t jirafs -o ro jira://work.atlassian.net ~/jirafs/work
sudo mount -F -t jirafs -o ro jira://personal.atlassian.net ~/jirafs/personal

# JIRA データにアクセス
ls ~/jirafs/myinstance/projects/
cat ~/jirafs/myinstance/projects/PROJ/issues/PROJ-1/summary.txt

# アンマウント
sudo diskutil unmount ~/jirafs/myinstance
```

プロジェクトフィルターやその他のオプション（ディスクキャッシュ、HTML ビュー）はホストアプリでインスタンスごとに設定できます。

## ドキュメント

- [技術仕様](Documentation/SPEC.md)
- [開発手順](Documentation/INSTRUCTIONS.md)

## ライセンス

[LICENSE](LICENSE) を参照
