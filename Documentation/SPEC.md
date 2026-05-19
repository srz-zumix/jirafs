# jirafs 技術仕様書

## 概要

jirafs は Apple の FSKit フレームワークを使い、JIRA のデータを macOS 上のファイルシステムとしてマウントするツールです。
JIRA のプロジェクトやイシューをディレクトリ・ファイルとして操作でき、標準的な UNIX ツール (`ls`, `cat`, `grep`, `find` 等) で JIRA データにアクセスできます。

## 対象環境

| 項目 | 値 |
|---|---|
| プラットフォーム | macOS 15.4+ (Sequoia) |
| フレームワーク | FSKit (`FSUnaryFileSystem`) |
| 言語 | Swift 6.0 |
| 配布形態 | macOS App + App Extension |
| JIRA 対応 | Atlassian Cloud / JIRA Server |

## マウント単位

**1 マウント = 1 JIRA スペース** (Cloud であれば 1 サイト、Server であれば 1 ホスト)。
複数の JIRA インスタンスを並行利用する場合は、それぞれ別のマウントポイントにマウントする。これによりパスの一意性とキャッシュのスコープを単純化する。

```bash
mount -F -t jirafs jira://companyA.atlassian.net ~/jirafs/companyA
mount -F -t jirafs jira://jira.internal.example.com ~/jirafs/internal
```

## アーキテクチャ

```
┌─────────────────────────────────────────────────┐
│                   macOS VFS                     │
├─────────────────────────────────────────────────┤
│                    FSKit                        │
├─────────────────────────────────────────────────┤
│             JiraFS App Extension                │
│  ┌───────────────────────────────────────────┐  │
│  │  JiraFileSystem (FSUnaryFileSystem)       │  │
│  │  ※ 1 マウント = 1 JIRA スペース           │  │
│  │  ┌─────────────────────────────────────┐  │  │
│  │  │  JiraVolume (FSVolume)              │  │  │
│  │  │  ├── FSVolume.Operations            │  │  │
│  │  │  ├── FSVolume.ReadWriteOperations   │  │  │
│  │  │  └── FSVolume.OpenCloseOperations   │  │  │
│  │  └─────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────┐  │
│  │  JIRA API Client                         │  │
│  │  ├── AuthProvider (Token/OAuth/PAT)      │  │
│  │  ├── REST API v2 (Server)                │  │
│  │  └── REST API v3 (Cloud)                 │  │
│  └───────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────┐  │
│  │  Cache Layer                              │  │
│  │  ├── In-Memory Cache (TTL ベース)         │  │
│  │  └── Disk Cache (オプション)              │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## ディレクトリ構造

### Phase 1: Issues ビュー (MVP)

```
/jirafs/                              # マウントポイント
├── projects/                         # プロジェクト一覧
│   ├── PROJ1/                        # プロジェクトキー
│   │   ├── .project.json             # プロジェクトメタデータ
│   │   └── issues/                   # イシュー一覧
│   │       ├── PROJ1-1/              # イシューキー
│   │       │   ├── summary.txt       # サマリー (1行テキスト)
│   │       │   ├── description.md    # 説明 (Markdown)
│   │       │   ├── metadata.json     # メタデータ (status, assignee, priority 等)
│   │       │   ├── issue.html        # HTMLビュー (htmlView: true 時のみ)
│   │       │   ├── comments/         # コメント一覧
│   │       │   │   ├── 001_user_2024-01-01.md
│   │       │   │   ├── 002_user_2024-01-02.md
│   │       │   │   └── ...
│   │       │   └── attachments/      # 添付ファイル
│   │       │       ├── screenshot.png
│   │       │       └── ...
│   │       ├── PROJ1-2/
│   │       └── ...
│   └── PROJ2/
│       └── ...
└── .jirafs/                          # 設定・キャッシュ
    ├── config.json                   # 接続設定
    └── cache/                        # キャッシュ
```

### Phase 2: 拡張ビュー (将来)

```
/jirafs/
├── projects/
│   └── PROJ1/
│       ├── issues/                   # Phase 1
│       ├── boards/                   # ボードビュー
│       │   └── Sprint Board/
│       │       ├── Sprint 1/
│       │       │   ├── PROJ1-1/ → ../../issues/PROJ1-1  # シンボリックリンク
│       │       │   └── ...
│       │       └── Backlog/
│       ├── epics/                    # エピックビュー
│       │   └── Epic Name/
│       │       ├── PROJ1-1/ → ../../issues/PROJ1-1
│       │       └── ...
│       └── filters/                  # フィルタビュー (JQL)
│           └── My Open Issues/
│               ├── PROJ1-1/ → ../../issues/PROJ1-1
│               └── ...
└── .jirafs/
```

> **注**: `.jirafs/` ディレクトリはマウント内に表示されるが、設定ファイル本体 (`config.json`) はホストアプリと Extension の両方からアクセス可能にするため、**実際は `~/Library/Application Support/jirafs/config.json` に保存される**。マウント内の `.jirafs/config.json` は読み取り専用ビュー (Phase 1 では空オブジェクトを返すスタブ)。

## 動作モード (read-only / read-write)

MVP では **2 つのモード**を切り替え可能とする。マウント時のオプションまたは設定 (`config.json`) で選択する。

| モード | `supportedVolumeCapabilities` | 書き込み API | 用途 |
|---|---|---|---|
| `read-only` (既定) | `readOnly = true` | カーネルが書き込みを拒否 (`EROFS`) | 安全に閲覧のみ行う |
| `read-write` | `readOnly = false` | Phase 1 ではメソッド側で `ENOTSUP` を返す。Phase 2 で実装拡充 | 将来の書き込み対応への準備 |

マウントオプション例:

```bash
mount -F -t jirafs -o ro jira://example.atlassian.net ~/jirafs   # read-only
mount -F -t jirafs -o rw jira://example.atlassian.net ~/jirafs   # read-write
```

## ファイル表現の詳細

### summary.txt

イシューの summary フィールド。改行なしの 1 行テキスト。

```
Implement user authentication
```

### description.md

JIRA の description フィールドを Markdown に変換して表示。
JIRA Cloud (ADF 形式) と Server (wiki markup) の両方を Markdown に変換する。

変換実装方針:

- **Markdown 出力**: [`apple/swift-markdown`](https://github.com/apple/swift-markdown) を採用
- **ADF パーサ**: 自作 (`JiraFSCore/ContentRenderer.swift`)。Atlassian Document Format の主要ノード (paragraph, heading, list, codeBlock, mention, link, table, mediaSingle 等) をマッピング
- **Wiki Markup パーサ**: 自作の最小実装 (見出し, リスト, リンク, 強調, コードブロック, パネル)
- **フォールバック**: 変換に失敗した場合は raw 文字列 (ADF JSON または wiki markup) をそのまま出力し、ファイル先頭に `<!-- jirafs: raw fallback -->` コメントを付与

### metadata.json

イシューのメタデータを構造化 JSON で表現。

```json
{
  "key": "PROJ-1",
  "id": "10001",
  "type": "Story",
  "status": "In Progress",
  "priority": "High",
  "assignee": {
    "displayName": "John Doe",
    "emailAddress": "john@example.com"
  },
  "reporter": {
    "displayName": "Jane Smith",
    "emailAddress": "jane@example.com"
  },
  "labels": ["backend", "api"],
  "components": ["Authentication"],
  "created": "2024-01-01T00:00:00.000+0000",
  "updated": "2024-01-15T12:00:00.000+0000",
  "resolution": null,
  "parent": "PROJ-100",
  "subtasks": ["PROJ-2", "PROJ-3"],
  "links": [
    {
      "type": "blocks",
      "direction": "outward",
      "key": "PROJ-50"
    }
  ],
  "customFields": {
    "customfield_10016": 5,
    "customfield_10020": "Sprint 1"
  }
}
```

### comments/NNN_author_date.md

コメントをファイルとして表現。ファイル名にインデックス・著者・日付を含む。

```markdown
<!-- author: John Doe (john@example.com) -->
<!-- created: 2024-01-01T10:00:00.000+0000 -->
<!-- updated: 2024-01-01T10:05:00.000+0000 -->
<!-- comment_id: 12345 -->

コメント本文をここに Markdown で表示
```

### attachments/

添付ファイルをそのままの名前で表示。ファイルの読み取りは JIRA API 経由でダウンロード。

## JIRA API クライアント

### 対応 API バージョン

| JIRA タイプ | API | ベース URL |
|---|---|---|
| Cloud | REST API v3 | `https://{domain}.atlassian.net/rest/api/3/` |
| Server | REST API v2 | `https://{host}/rest/api/2/` |

### 認証方式

| 方式 | Cloud | Server | 設定項目 |
|---|---|---|---|
| API Token | ✅ | ❌ | email + token |
| Personal Access Token (PAT) | ❌ | ✅ | token |

認証情報は macOS Keychain に保存する。

### 主要エンドポイント

```
GET /rest/api/{ver}/project                        # プロジェクト一覧
GET /rest/api/{ver}/project/{key}                  # プロジェクト詳細
GET /rest/api/{ver}/search?jql=project={key}       # イシュー検索
GET /rest/api/{ver}/issue/{key}                    # イシュー詳細
GET /rest/api/{ver}/issue/{key}/comment            # コメント一覧
GET /rest/api/{ver}/issue/{key}/attachments        # 添付ファイル
GET /rest/api/{ver}/attachment/content/{id}        # 添付ファイルダウンロード
```

### レート制限

- Cloud: 直近1分あたりのリクエスト上限あり (429 レスポンスに対する Retry-After 対応)
- Server: 管理者設定に依存
- 指数バックオフ + リトライを実装

## FSKit 実装詳細

### FSUnaryFileSystem (JiraFileSystem)

`FSUnaryFileSystemOperations` プロトコルに準拠。

| メソッド | 実装内容 |
|---|---|
| `loadResource(resource:options:replyHandler:)` | リソースから JiraVolume を生成 (現状は `config.json` 先頭インスタンスを使用) |
| `unloadResource(resource:options:replyHandler:)` | リソース解放・キャッシュクリア |
| `probeResource(resource:replyHandler:)` | リソースが有効な JIRA 設定を持つか検証 (deterministic UUID で `FSContainerIdentifier` 返却) |
| `didFinishLoading()` | 初期化完了処理 |

> **注**: `loadResource` は `jira://` URL のホスト名を `JiraFileSystem+ServerURL.m` で取得し、`config.json` の対応インスタンスを選択する。複数インスタンスを並行利用する場合は、それぞれ別の `jira://` URL でマウントする。

### FSVolume (JiraVolume)

#### 必須: FSVolume.Operations

| メソッド | 実装内容 |
|---|---|
| `activate(options:replyHandler:)` | JIRA 接続確認、ルートアイテム作成 |
| `deactivate(options:replyHandler:)` | 接続切断、リソース解放 |
| `mount(options:replyHandler:)` | ボリュームマウント |
| `unmount(replyHandler:)` | アンマウント |
| `lookupItem(named:inDirectory:replyHandler:)` | ディレクトリ/ファイル検索 |
| `createItem(named:type:inDirectory:attributes:replyHandler:)` | Phase 1: ENOTSUP / Phase 2: イシュー作成 |
| `removeItem(_:named:fromDirectory:replyHandler:)` | Phase 1: ENOTSUP |
| `renameItem(...)` | Phase 1: ENOTSUP |
| `reclaimItem(_:replyHandler:)` | アイテムリソース解放 |
| `getAttributes(_:of:replyHandler:)` | ファイル/ディレクトリ属性返却 |
| `setAttributes(_:on:replyHandler:)` | Phase 1: ENOTSUP |
| `enumerateDirectory(...)` | ディレクトリ内容列挙 |
| `synchronize(flags:replyHandler:)` | キャッシュフラッシュ |
| `createLink(...)` / `createSymbolicLink(...)` / `readSymbolicLink(...)` | Phase 2 で使用 |
| `supportedVolumeCapabilities` | 読み取り専用ケイパビリティ |
| `volumeStatistics` | ボリューム統計情報 |

#### オプション: FSVolume.ReadWriteOperations

| メソッド | 実装内容 |
|---|---|
| `read(from:at:length:into:replyHandler:)` | ファイル内容読み取り (JIRA API → バッファ) |
| `write(to:at:from:replyHandler:)` | Phase 2: イシューフィールド更新 |

#### オプション: FSVolume.OpenCloseOperations

| メソッド | 実装内容 |
|---|---|
| `openItem(_:modes:replyHandler:)` | アイテムオープン (cachedData をフェッチ) |
| `closeItem(_:modes:replyHandler:)` | アイテムクローズ (cachedData を解放) |

### JiraFSItem (FSItem サブクラス)

JIRA データをファイルシステムアイテムとして表現するクラス。ノード種別は `FSNodeKind` 列挙型で管理する。

```swift
public enum FSNodeKind: Hashable, Sendable {
    case root                                               // /
    case metadataNeverIndex                                 // /.metadata_never_index
    case configDir                                          // /.jirafs
    case configFile                                         // /.jirafs/config.json
    case projectsDir                                        // /projects
    case project(key: String)                               // /projects/{KEY}
    case projectMeta(key: String)                           // /projects/{KEY}/.project.json
    case issuesDir(project: String)                         // /projects/{KEY}/issues
    case issue(key: String)                                 // /projects/{KEY}/issues/{ISSUE-KEY}
    case summary(issueKey: String)                          // .../summary.txt
    case description(issueKey: String)                      // .../description.md
    case metadata(issueKey: String)                         // .../metadata.json
    case issueHtml(issueKey: String)                        // .../issue.html (htmlView: true 時)
    case commentsDir(issueKey: String)                      // .../comments/
    case comment(issueKey: String, index: Int)              // .../comments/NNN_author_date.md
    case attachmentsDir(issueKey: String)                   // .../attachments/
    case attachment(issueKey: String, attachmentId: String) // .../attachments/{filename}
}

final class JiraFSItem: FSItem {
    let kind: FSNodeKind
    var cachedData: Data?
    var cachedSize: UInt64
}
```

## キャッシュ戦略

### 2 層キャッシュ構造

`CacheManager` は **In-Memory** と **Disk** の 2 層を持つ。

| 層 | 実体 | 用途 |
|---|---|---|
| L1: In-Memory | actor-isolated `[String: Entry]` | TTL 期間中の高速応答 |
| L2: Disk | AES-GCM 暗号化 `.cache` ファイル | マウント間のウォームアップ |

#### ディスクヒット時のメモリウォームアップ

L1 ミス→ L2 ヒット時、デコードした値を L1 にも書き戻す (**ただし添付バイナリは除く**)。

- `get<T: Codable>` / `getStale<T: Codable>`: L2 ヒット時に `storage[key]` へ書き戻す。次回以降の読み出しは L1 でヒットし、再デクリプトが不要になる。
- `get(Data)` / `getStale(Data)` (添付バイナリ): L2 ヒット時でも **L1 への書き戻しは行わない**。添付バイナリは MB〜数百 MB に達するため、ディスク読み出しと AES 復号アロケーションが並走する状況でヒープフラグメントが起きやすい。ディスクキャッシュ自体が十分な warm-up となるため L1 への保持は不要と判断している。

### TTL

| データ種別 | TTL | 理由 |
|---|---|---|
| プロジェクト一覧 | 5 分 (300s) | 変更頻度が低い |
| イシュー一覧 | 10 分 (600s) | 変更頻度が中程度 |
| イシュー詳細 | 10 分 (600s) | コメントや状態が変わりうる |
| 添付ファイル一覧 | 10 分 (600s) | 変更頻度が低い |
| 添付ファイル本体 | 30 分 (1800s) | サイズが大きいため長めにキャッシュ |

### Stale-while-revalidate

`IssueDataSource` は以下の優先順位でデータを返す。

1. **L1 Fresh** (TTL 内) → 即返却
2. **L1/L2 Stale** (TTL 超過だが 7 日以内) → 即返却 + バックグラウンドで再取得
3. **L1/L2 なし** → API フェッチ (初回アクセスのみ)

### キャッシュ無効化

- `synchronize()` 呼び出し時に L1・L2 を全クリア
- ディレクトリ列挙時に TTL 超過分をバックグラウンドリフレッシュ
- ファイルクローズ時に `JiraFSItem.cachedData` を解放 (レンダリング済みコンテンツの再生成を保証)

## セキュリティ

- 認証情報は macOS Keychain に保存 (ファイルや環境変数に平文保存しない)
- HTTPS 通信必須 (証明書検証あり)
- App Sandbox 対応
- FSKit entitlement (`com.apple.developer.fskit.fsmodule`)
- JIRA API レスポンスのサニタイズ (パストラバーサル防止: ファイル名に `..` や `/` を含む場合はエスケープ)

### Keychain Access Group

ホストアプリと App Extension で同一の Keychain Access Group を共有し、ホストアプリで保存した認証情報を Extension が読み取る。

| 項目 | 値 |
|---|---|
| Access Group | `$(AppIdentifierPrefix)com.zumix.jirafs.shared` |
| Service (項目名) | `com.zumix.jirafs.<instanceName>` |
| Account | 認証方式に応じた識別子 (例: API Token なら email, PAT なら `pat`) |

両ターゲットの `entitlements` に以下を含める。

```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.zumix.jirafs.shared</string>
</array>
```

### ファイル名サニタイズ

- 添付ファイル名・コメント著者名などに含まれる `/`, `\`, `\0`, 制御文字 (0x00-0x1F), 先頭末尾の空白・ドットは `_` に置換する。
- `.` および `..` という名前のファイル/ディレクトリは `_` を末尾に追加して回避 (`._`, `.._`)。
- 同名衝突時は `name (2).ext`, `name (3).ext` のように連番サフィックスを付与する。

### URL スキーム

`Info.plist` の `FSMatchingURLSchemes` には `jira` と `https` を登録するが、`https` は他のシステムと競合する可能性があるため、ホストアプリ側で **`jira://` への正規化を推奨**する。Finder からのドラッグ & ドロップによる利便性のため `https` も許容する。


## 設定ファイル (config.json)

設定ファイルは **`~/Library/Application Support/jirafs/config.json`** に保存される。ホストアプリと Extension の両方が同じファイルを読み書きするため、Sandbox 共有のために App Group ではなく User Domain の Application Support を使用する (Keychain 認証情報のみ Access Group 経由で共有)。

```json
{
  "version": 1,
  "instances": [
    {
      "name": "my-cloud",
      "type": "cloud",
      "url": "https://mycompany.atlassian.net",
      "auth": {
        "method": "api_token",
        "email": "user@example.com"
      },
      "diskCache": true,
      "htmlView": false
    },
    {
      "name": "my-server",
      "type": "server",
      "url": "https://jira.internal.example.com",
      "auth": {
        "method": "pat"
      },
      "allowedProjectKeys": ["PROJ", "OPS"],   // 設定時は listProjects() 一括取得ではなく getProject(key:) 並列呼び出しで取得 (Server の大量プロジェクト対策)
      "diskCache": true,
      "htmlView": true
    }
  ],
  "cache": {
    "projects": 300,
    "issues": 600,
    "issueDetail": 600,
    "attachments": 600,
    "attachmentBinary": 1800
  },
  "pagination": {
    "maxResults": 1000
  }
}
```

## マウント方法

マウントは **CLI と ホストアプリ UI の両方**をサポートする。

### CLI (mount コマンド)

FSKit (macOS 15+) では `mount -F` で File System Extension 経由のマウントを行う。

```bash
# Cloud インスタンスをマウント (read-only)
mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs

# Server インスタンスをマウント (read-write)
mount -F -t jirafs -o rw jira://jira.internal.example.com ~/jirafs

# アンマウント
umount ~/jirafs
```

### ホストアプリ UI

ホストアプリの「マウント」ボタンから `FSFileSystemKit` の `FSMountManager` API 経由でマウントを実行する。マウントポイントが省略された場合は `/Volumes/jirafs-<instanceName>` を自動生成する。

## 開発フェーズ

### Phase 1 (MVP) — 読み取り専用 Issues ビュー

- [x] FSKit App Extension スキャフォールド
- [x] JIRA API クライアント (Cloud + Server) — `JiraRESTClient` (REST API v2/v3 共通実装、edition で切替)
- [x] 認証 (API Token + PAT) — `APITokenAuth` / `PATAuth`
- [x] プロジェクト一覧 → ディレクトリ
- [x] イシュー一覧 → ディレクトリ (ページネーション対応)
- [x] イシュー詳細 → ファイル群 (summary.txt, description.md, metadata.json)
- [x] コメント → ファイル群 (`NNN_author_YYYY-MM-DD.md`)
- [x] 添付ファイル → ファイル (遅延ダウンロード、Range リクエスト対応)
- [x] In-Memory キャッシュ (TTL ベース actor)
- [x] Keychain 認証情報管理 (Access Group 共有)
- [x] エラーハンドリング (`JiraAPIError` → POSIX 変換) ・ロギング (`os.Logger` subsystem `com.zumix.jirafs`)
- [x] ADF / wiki markup → Markdown レンダラ (主要ノード対応)
- [x] `RateLimiter` (429 + Retry-After / 5xx 指数バックオフ、最大 3 回)
- [x] 大量イシュー (数千件) のページネーション perf 検証 (`IssueDataSourcePaginationTests`)
- [ ] 実機 (Xcode 16.4+ / macOS 15.4+) での FSKit マウント検証

### Phase 2 — 書き込み対応

- [ ] イシュー作成 (createItem)
- [ ] フィールド更新 (write → JIRA API PUT)
- [ ] コメント追加
- [ ] ステータス遷移 (metadata.json の status 書き換え)

### Phase 3 — 拡張ビュー

- [ ] ボードビュー
- [ ] スプリントビュー
- [ ] エピックビュー
- [ ] JQL フィルタビュー
- [ ] OAuth 2.0 対応

## 既知の制約・検討事項

- FSKit は現在 `FSUnaryFileSystem` のみサポート
- **FSKit は macOS 15.4 SDK / Xcode 16.4+ が必須**。それ未満では拡張のビルド/動作不可 (フレームワーク `JiraAPI` / `JiraFSCore` とテストは macOS 14.0 を維持)
- JIRA API のレート制限によるスループット制約
- 大量イシュー (数万件) の場合、ページネーションと遅延読み込みが必要
- 添付ファイルの大きなバイナリデータはストリーミング対応が望ましい (ディスクキャッシュには AES-GCM base64 形式で保存; In-Memory キャッシュには保持しない)
- JIRA Cloud の ADF (Atlassian Document Format) → Markdown 変換は完全でない場合がある (主要ノードのみ対応、それ以外は raw fallback)
- Server 版の wiki markup → Markdown 変換の互換性 (見出し / リスト / リンク / 強調 / `{code}` / `{panel}` / `{quote}` のみ)
- JIRA Cloud v3 の `/search/jql` エンドポイントを使用 (2024年以降推奨の API)
- `searchIssues` (Server v2) は `GET /rest/api/2/search` を使用
