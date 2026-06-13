# jirafs

JIRA / Confluence のデータを macOS のファイルシステムとしてマウントするツール。
Apple [FSKit](https://developer.apple.com/documentation/FSKit) フレームワーク (FSUnaryFileSystem) を利用し、JIRA のプロジェクト・イシューや Confluence のスペース・ページを標準的なファイル操作でアクセス可能にします。

## 特徴

- JIRA Cloud / Server、Confluence Cloud / Data Center 両対応
- **複数インスタンス**の同時マウント対応（JIRA / Confluence ともインスタンスごとにマウントパスを設定）
- **プロジェクト / スペースフィルター**対応—全件公開するか、特定のキーのみに絞り込むかをインスタンスごとに設定可能
- JIRA イシューをディレクトリとして表現 (summary.txt, description.md, metadata.json, comments/, attachments/)
- Confluence ページをディレクトリとして表現 (page.md, .metadata.json, .labels.txt, .comments/, .attachments/)。子ページは親ディレクトリ配下に再帰的にネスト
- 標準 UNIX ツール (`ls`, `cat`, `grep`, `find`) でデータを操作
- read-only マウント
- macOS Keychain (Access Group 共有) による安全な認証情報管理
- TTL ベースの In-Memory キャッシュ + オプションで AES-GCM 暗号化ディスクキャッシュ
- バックグラウンド自動更新—フォルダを開いたまま待つだけで新規 issue / page が表示される（間隔は設定可能、オフにもできる）
- `issue.html` / `{タイトル}.html` フォーマットビュー（オプション）

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

各 Confluence インスタンスは独自のマウントパスにマウントされます（デフォルトは `~/confluencefs/<name>`）。子ページは親ページのディレクトリ配下にネストされます。

```text
~/confluencefs/myinstance/
└── spaces/
    └── DOCS/
        ├── .space.json                # スペースのメタデータ
        └── pages/
            ├── Getting Started.html    # HTML ビュー (htmlView: true 時のみ)
            └── Getting Started/
                ├── page.md             # ページ本文 (Markdown)
                ├── .metadata.json      # メタデータ
                ├── .labels.txt         # ラベル
                ├── .comments/          # コメントファイル群
                ├── .attachments/       # 添付ファイル
                └── Child Page/         # 子ページ（再帰的にネスト）
                    └── page.md
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

Confluence インスタンスも同様にホストアプリで設定し、`confluencefs` ファイルシステムでマウントします。

```bash
# Confluence インスタンスをマウント
mkdir -p ~/confluencefs/myinstance
sudo mount -F -t confluencefs -o ro confluence://mycompany.atlassian.net ~/confluencefs/myinstance

# Confluence データにアクセス
ls ~/confluencefs/myinstance/spaces/
cat "~/confluencefs/myinstance/spaces/DOCS/pages/Getting Started/page.md"

# アンマウント
sudo diskutil unmount ~/confluencefs/myinstance
```

プロジェクト / スペースフィルターやその他のオプション（ディスクキャッシュ、HTML ビュー）はホストアプリでインスタンスごとに設定できます。

### 自動更新 (Auto-Refresh)

FSKit のボリュームは受動的で、カーネルはディレクトリの更新日時 (mtime) が変わらない限り再列挙しません。フォルダを開いた後に作成された issue / page を自動表示するため、各マウントは閲覧済み一覧をバックグラウンドで再取得し mtime を更新します（これにより Finder が再列挙します）。

ホストアプリの **Preferences → Cache → Auto-Refresh Interval** で JIRA / Confluence 別に設定できます。

- **オフ** — ポーリングを無効化（更新には再度開く / `ls` が必要）
- **0**（既定）— イシュー / ページのキャッシュ TTL を流用（その TTL が 0 のときはポーリングも無効）
- **N 秒** — その間隔でポーリング（1 秒〜1 日にクランプ）

変更は再マウントで反映されます。

## ドキュメント

- [技術仕様](Documentation/SPEC.md)
- [開発手順](Documentation/INSTRUCTIONS.md)

## ライセンス

[LICENSE](LICENSE) を参照。

本プロジェクトはサードパーティコンポーネントを同梱しています。各ライセンスと帰属表示は [NOTICE.txt](NOTICE.txt) を参照してください。
