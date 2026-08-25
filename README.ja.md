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
- **匿名アクセス** — 公開された JIRA/Confluence サイトを認証なしでマウント
- **ホワイトボードのキャンバス取得（実験的）** — Atlassian Rovo MCP サーバ経由で `whiteboard.md` / `whiteboard.json` / `whiteboard.svg` を生成（Confluence Cloud + *API Token (scoped)* 認証のみ。デフォルトはオフ）
- TTL ベースの In-Memory キャッシュ + オプションで AES-GCM 暗号化ディスクキャッシュ
- バックグラウンド自動更新—フォルダを開いたまま待つだけで新規 issue / page が表示される（間隔は設定可能、オフにもできる）
- `issue.html` / `{タイトル}.html` フォーマットビュー（オプション）

## 対象環境

- macOS 15.4+ (Sequoia)
- Xcode 16.4+
- Swift 6.0

## API トークンのスコープ（Confluence Cloud）

*API Token (scoped)* 認証を使う場合、必要なのは以下のスコープだけです。Confluence REST アクセスは読み取り専用で `GET` / `HEAD` しか発行しないため、**`write:` / `delete:` 系は一切不要**です。（オプションの Rovo MCP ホワイトボード連携は Atlassian の MCP エンドポイントへ読み取り専用の JSON-RPC `POST` を発行しますが、これは Confluence スコープではなく後述の設定で制御されます。）

| スコープ | 用途 |
| --- | --- |
| `read:attachment:confluence` | `.attachments/` の一覧とダウンロード |
| `read:comment:confluence` | `.comments/` |
| `read:folder:confluence` | ページ配下のフォルダ |
| `read:hierarchical-content:confluence` | ページツリーの探索 (`direct-children`) |
| `read:label:confluence` | `.labels.txt` |
| `read:page:confluence` | ページ本文・スペース配下のページ一覧 |
| `read:space:confluence` | スペース一覧 (`/spaces`) |
| `read:whiteboard:confluence` | ホワイトボードのメタデータと子要素 |

対応するオプションを有効にしている場合のみ追加します。

| スコープ | 用途 |
| --- | --- |
| `read:content-details:confluence`, `read:content.restriction:confluence` | 閲覧制限ページの除外（デフォルトの `includeRestricted = off`。制限情報を v1 content API から取得するため） |
| `readonly:content.attachment:confluence` | 添付のダウンロードが 401 になる場合のみ。レガシーな `/wiki/download/...` パスはこのクラシックスコープでルーティングされます |

補足:

- scoped トークンは Confluence のみ対応です。JIRA のマウントには通常の API トークンか PAT を使ってください
- 実験的な Rovo MCP ホワイトボード連携は scoped トークンが必須ですが、可否は Confluence のスコープではなく組織の「API トークンでの接続を許可する」設定で決まります
- ホワイトボードの**画像**はどのトークンでも取得できません。実体が Atlassian Media Services にあり、対応する Confluence の OAuth スコープが存在しないためです。`whiteboard.svg` ではラベル付きのプレースホルダとして描画されます

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
                ├── My Whiteboard/      # ホワイトボード (Cloud のみ)
                │   ├── .metadata.json  # ホワイトボードのメタデータ (webURL を含む)
                │   ├── whiteboard.md   # キャンバスのテキスト   ┐
                │   ├── whiteboard.json # MCP レスポンス生データ │ 実験的、デフォルトはオフ
                │   └── whiteboard.svg  # キャンバスの描画       ┘
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
