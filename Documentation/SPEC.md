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

> **注**: `.jirafs/` ディレクトリはマウント内に表示されるが、設定の source of truth (`appstore.json`) はホストアプリの `~/Library/Application Support/jirafs/appstore.json` に保存され、各 Extension はそこから派生した `config.json` を自身のサンドボックスコンテナから読む (詳細は後述の「設定ファイル」)。マウント内の `.jirafs/config.json` は読み取り専用ビュー (Phase 1 では空オブジェクトを返すスタブ)。

## 動的検索ビュー (`search/`) — 将来構想

> **ステータス**: 設計のみ確定。実装は未着手 (Phase 2 以降)。本節は採用方針 (B/C ハイブリッド) を記録するもので、`FSNodeKind` やボリューム操作の実装はまだ存在しない。

### 背景と課題

マウント時に JQL / CQL を 1 つ固定する方式 (`mount -o jql=...`) には次の制約がある。

1. **クエリを変更できない** — 別クエリを使うには再マウントが必要。
2. **動的クエリを表現しづらい** — 1 マウント = 1 クエリでは、複数・即席のクエリを同時に扱えない。

「クエリをパスに載せる」案 (パス = クエリ) はパス制約と衝突するため不採用とした。

- `/` がパス区切りと衝突する (`created >= 2024/01/01`, `project IN (A/B)` 等)。
- 1 パスコンポーネントは **255 バイト上限**。複雑なクエリが収まらない。
- **APFS は既定で case-insensitive** のため、大小のみ異なるクエリが同一パスに衝突しうる。
- 演算子 (`=` `~` `<` `>` `()` `"`) がシェルメタ文字でクォート必須となり、可読パスという唯一の利点が失われる。

→ 結論: **クエリは「パス」ではなく「ファイルの内容」として表現する**。パス名には「ユーザー / AI が付ける安全な識別子」だけを使い、クエリ本文は内部の `query` ファイルに逃がす。これにより文字種・長さ・大小・シェル安全性の問題をすべて回避できる。

### 採用方針: B/C ハイブリッド (コントロールファイル方式)

マウント内に「クエリ名前空間」 `search/` を置く。クエリの指定・変更はファイルへの書き込みで表現し、結果は canonical な issue / page ディレクトリへの **シンボリックリンク** で返す (実体を二重に持たずキャッシュを共有する。Phase 2 の `filters/` ビュー方針と一致)。

```
/jirafs/
└── search/
    ├── query           # B: 使い捨ての即席クエリ。echo '...' > query で更新
    ├── results/        # B: query 反映後の結果 (symlink 群)
    │   ├── PROJ1-1/ → ../../projects/PROJ1/issues/PROJ1-1
    │   └── ...
    ├── status.json     # B: 実行状態 (件数・実行時刻・鮮度・エラー・truncated)
    └── <name>/         # C: mkdir で作る名前付き保存クエリ
        ├── query.jql   #    クエリ本文 (任意の文字 OK。/ " 改行 長文すべて可)
        ├── results/    #    再評価後の symlink 群
        └── status.json
```

- **B (即席クエリ)**: `search/` 直下の `query` / `results/` / `status.json`。`echo 'project=FOO AND status=Open' > query` で更新し、`ls results/` で結果を得る。使い捨て用途。
- **C (保存クエリ)**: `mkdir search/<name>` で名前付きビューを作成し、内部の `query.jql` (JIRA) / `query.cql` (Confluence) を書き換えると再評価される。定常的なビューを複数保持・命名でき、`ls search/` で一覧できる。
- **read-only との両立**: 全体の read-only ポリシーは維持し、**書き込みを許可するのは `query` / `query.jql` / `query.cql` とディレクトリ作成のみ**に限定する。これらは **ローカル状態のみを変更し、リモート (JIRA / Confluence) を一切変更しない** ため、「リモートを mutate しない」という安全性の中核は崩れない。それ以外への書き込みは従来どおり拒否する。

### 決めるべきセマンティクス (実装時に確定)

| 項目 | 方針案 |
|---|---|
| 列挙の有限性 | 任意クエリは無限。`ls search/` には保存クエリ (C) と即席 (B) のみ出す。任意クエリのワンショット解決を許す場合は `lookupItem` 専用とし、列挙には載せない |
| 再評価トリガ | `query` への write 完了時に再評価。加えて `results/` 列挙時の TTL 失効でバックグラウンドリフレッシュ (既存の stale-while-revalidate を流用) |
| 鮮度の可視化 | `status.json` に `fetchedAt` / `stale` / `count` / `truncated` / `generation` を持たせ、AI / ツールが「反映済みか」「古いか」「途中までか」を判定できるようにする |
| 結果上限 | 大量ヒット時に全 symlink を作ると重い。`maxResults` と `truncated: true` を設け、必要なら `results.pageN/` でページ分割 |
| パス安全性 | C の `<name>` はユーザー / AI が付ける識別子なので [FileNameSanitizer](../AtlassianCore/FileNameSanitizer.swift) を適用 (パストラバーサル防止)。クエリ本文はファイル内容なのでサニタイズ不要 |
| クエリ種別 | JIRA は JQL (`query.jql`)、Confluence は CQL (`query.cql`)。`search/` 直下の即席 `query` はマウント対象プロダクトの言語に従う |

### status.json の例

```json
{
  "query": "project = PROJ AND status = Open",
  "count": 42,
  "truncated": false,
  "maxResults": 100,
  "fetchedAt": "2024-01-15T12:00:00Z",
  "stale": false,
  "generation": 3,
  "error": null
}
```

### 補足: パス = クエリ案の限定採用

パス = クエリ方式は、記号を含まない単純なキー指定 (例: `search/PROJ-123`) に限れば `lookupItem` での解決が可能であり、ショートカットとして任意で併設し得る。ただし複雑クエリは B/C に委ね、`search/` 直下に記号付きの可変パスを列挙することはしない。

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
- **ディスパッチ**: `JiraFSCore/ContentRenderer.swift` が値の型を見て ADF (object) / wiki markup (string) を振り分ける
- **ADF パーサ**: `AtlassianCore/ADFRenderer.swift` (JIRA / Confluence で共有)。Atlassian Document Format の主要ノード (paragraph, heading, list, codeBlock, mention, link, table, mediaSingle 等) をマッピング
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

**メモリ保護 (OOM/DoS ガード)**: 添付ファイルは一括バッファリングせず、サイズに応じて 2 通りに振り分ける。判定には一覧取得時のメタデータ (`size` / `fileSize`) を使い、本体ダウンロード前に決定する。

- **小サイズ (`size <= maxInlineAttachmentBytes`)**: 一度だけ全体ダウンロードして**メモリにキャッシュ**し、以降の読み取りはメモリ上のスライスで応答する (再ダウンロードなし)。キャッシュは合計上限付きで LRU 退避する。
- **大サイズ / サイズ不明**: `read(offset:length:)` の要求窓だけを HTTP Range リクエストで取得する (キャッシュしない)。これにより数 GB の添付があっても Extension プロセスがファイル全体をメモリに展開せず、OOM を防ぐ。
- Range を無視して `200` で本体全体を返すサーバの場合、本体が `maxInlineAttachmentBytes` 以内なら同様にメモリキャッシュする (超過時はキャッシュせず要求窓のみ応答)。

添付本体は**ディスクに書き出さない** (平文の一時ファイルを残さない)。`maxInlineAttachmentBytes` の既定値は **16 MiB** (`IssueDataSource` / `PageDataSource` の init 引数で上書き可能)。

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
| API Token (scoped) | ✅ (Confluence のみ) | ❌ | email + token |
| Personal Access Token (PAT) | ❌ | ✅ | token |
| Anonymous (匿名) | ✅ | ✅ | なし |

認証情報は macOS Keychain に保存する。Anonymous は認証情報を保存せず、`Authorization` ヘッダを付けずにリクエストする (公開された JIRA / Confluence サイト向け)。HTTPS 必須は Anonymous でも維持される。

#### API Token (scoped) — `api.atlassian.com` ゲートウェイ

Atlassian の **スコープ付き API トークン** (id.atlassian.com の "Create API token with scopes") は
従来のトークンと同じ HTTP Basic (`email:token`) だが、**サイトホストでは 401 になる**。
リクエスト先を API ゲートウェイに変える必要がある。

| | ベース URL | 例 |
|---|---|---|
| 従来のトークン | `https://{site}.atlassian.net` | `…/wiki/api/v2/pages` |
| スコープ付きトークン | `https://api.atlassian.com/ex/confluence/{cloudId}` | `…/ex/confluence/{cloudId}/wiki/api/v2/pages` |

- `cloudId` はサイトの認証不要エンドポイント `GET {siteURL}/_edge/tenant_info` から取得し、
  `ConfluenceRESTClient` がインスタンスごとに一度だけ解決してキャッシュする。
- 添付ファイルの `downloadLink` はルート相対 (`/download/attachments/…`) なので、
  ゲートウェイ利用時は `/ex/confluence/{cloudId}` のコンテキストパスも前置する。
  同一オリジンチェックはゲートウェイのベース URL に対して行う。
- Rovo MCP に渡すのは**ブラウザ URL** なので、`RovoWhiteboardSource.siteBaseURL` には
  ゲートウェイではなくサイト URL (`config.baseURL`) をそのまま渡す。
- JIRA 側 (`https://api.atlassian.com/ex/jira/{cloudId}`) は未実装。認証情報は Server 単位で
  共有されるため、`ServerEditorView` はスコープ付きトークン + JIRA 接続の組み合わせを保存させず、
  `AppConfig.deriveJira` も該当マウントを除外する。

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
- 指数バックオフ + リトライを実装 (最大 3 回)
- サーバー指定の `Retry-After` は **最大 60 秒にクランプ** (`RateLimiter.maxRetryAfter`)。悪意あるサーバーが巨大値を返してもアプリを長時間停止させられない

## FSKit 実装詳細

### FSUnaryFileSystem (JiraFileSystem)

`FSUnaryFileSystemOperations` プロトコルに準拠。

| メソッド | 実装内容 |
|---|---|
| `loadResource(resource:options:replyHandler:)` | `jira://` URL のホスト名で `config.json` の対応インスタンスを選択し JiraVolume を生成（一致なしは先頭にフォールバック） |
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

### バックグラウンド自動更新 (ポーリング)

FSKit のボリュームは受動的で、Finder (カーネル) はディレクトリの `mtime` が変わらない限り再列挙しない。そのため「フォルダを開いたまま待っているだけ」では、JIRA / Confluence 側で新規作成された issue / page は表示されない (誰も `enumerateDirectory` を呼ばないため stale-while-revalidate のトリガーも発火しない)。

これを解決するため、各ボリュームはマウント時に**定期ポーリングループ**を起動する。

- 一度でも列挙された (= ユーザーが開いた) プロジェクト / スペース・ページ一覧を対象に、一定間隔で一覧をバックグラウンド再取得する。
- 再取得後にディレクトリの `cachedMTime` を更新し、Finder の kqueue ウォッチャを発火させて自動再列挙させる。これにより新規 issue / page が「待つだけ」で表示される。
- 初期化 (ハンドラ配線・キャッシュウォームアップ・ポーリング起動) は `FSVolume.mount()` ではなく **`activate()`** で行う。fskitd は `FSUnaryFileSystem` のボリュームを `mount()` 経由で駆動しないことがあるため、`OSAllocatedUnfairLock<Bool>` の once-guard で一度だけ実行する。
- ループのタスクは `makeTask` で追跡され、`unmount` 時の `cancelAllTasks()` で確実に停止する。

#### ポーリング間隔の設定 (`refreshInterval`)

ポーリング間隔は TTL とは独立した設定値 `CacheTTLConfig.refreshInterval` (秒) で制御する。

| 値 | 挙動 |
|---|---|
| `nil` / 負値 (オフ) | ポーリングを無効化 (待つだけでは更新されない。再アクセスが必要) |
| `0` (既定) | イシュー / ページ一覧 TTL を流用 (後方互換)。当該 TTL が `0` (キャッシュ無効) の場合はポーリングも無効化 |
| 正値 | その秒数でポーリング |

間隔は **下限 1 秒・上限 1 日 (86,400 秒)** にクランプされる (それ未満は 1 秒に丸めて API 過負荷を防止、非有限値や巨大値は無効化/上限で `Task.sleep` のオーバーフローを防止)。

ホストアプリの Preferences → Cache タブ「Auto-Refresh Interval」で JIRA / Confluence 別に設定でき、トグルでオフにもできる。設定変更は再マウントで反映される。

### キャッシュ無効化

- `synchronize()` 呼び出し時に L1・L2 を全クリア
- ディレクトリ列挙時に TTL 超過分をバックグラウンドリフレッシュ
- ファイルクローズ時に `JiraFSItem.cachedData` を解放 (レンダリング済みコンテンツの再生成を保証)

## セキュリティ

- 認証情報は macOS Keychain に保存 (ファイルや環境変数に平文保存しない)
- **HTTPS 必須** — ホストアプリの Server Editor が `https://` 以外のスキームを拒否する (Save / Verify を無効化、警告バナーを表示)
- HTTPS 通信必須 (URLSession による TLS 証明書検証あり、`NSAllowsArbitraryLoads` 未設定)
- App Sandbox 対応
- FSKit entitlement (`com.apple.developer.fskit.fsmodule`)
- JIRA / Confluence API レスポンスのサニタイズ (パストラバーサル防止: ファイル名に `..` や `/` を含む場合はエスケープ)
- **ログの機密性** — HTTP エラー時のレスポンスボディは `privacy: .private` で記録し、ステータスコード / URL のみ `privacy: .public` に残す (業務データの unified log 漏洩を防止)

### ディスクキャッシュの暗号化

ディスクキャッシュ (L2) は API レスポンスのコピーを平文でディスクに残さないため AES-GCM で暗号化する。鍵管理は以下の方針とする。

- **マスター鍵 (256bit) は共有 Keychain Access Group に保存**する (data-protection Keychain, `kSecAttrAccessibleAfterFirstUnlock`)。認証情報と同じ仕組みで、ホストアプリと FSKit Extension の双方が読み書きできる。**鍵をディスク (`.cache.key` 等の平文ファイル) に保存しない。**
- 実際の暗号化鍵とファイル名 HMAC 鍵は、マスター鍵から **HKDF-SHA256 で用途別に導出**する (鍵の使い回しを避ける)。
- ファイル名は `HMAC-SHA256(filenameKey, cacheKey)` の切り詰め。予測可能な `cacheKey` からファイル名を逆引きできない。
- 鍵が一時的に取得できない場合は **メモリのみのキャッシュにフォールバック**し、平文鍵を書き出すことは決してしない。
- 旧バージョンが残した平文 `.cache.key` ファイルは初期化時に削除し、復号できない旧形式の `.cache` ファイルは eviction で掃除する。

> **脅威モデルの注意**: この暗号化は「API レスポンスを平文でディスクに残さない」ことを目的とする。ディスク上のキャッシュディレクトリや Keychain を読める主体 (同一ユーザー権限のプロセス、Full Disk Access を持つツール、バックアップ、ユーザー権限を奪取したマルウェア等) に対する防御境界ではない。Extension のサンドボックスコンテナ内に置かれることは、他のサンドボックスアプリによる偶発的アクセスを減らす程度であり、強い防御境界とはみなさない。

### Keychain Access Group

ホストアプリと App Extension で同一の Keychain Access Group を共有し、ホストアプリで保存した認証情報を Extension が読み取る。

| 項目 | 値 |
|---|---|
| Access Group | `$(AppIdentifierPrefix)com.zumix.jirafs.shared` |
| Service (項目名) | `com.zumix.jirafs.<instanceName>` |
| Account | 認証方式に応じた識別子 (例: API Token / API Token (scoped) なら email, PAT なら `pat`)。Anonymous は Keychain を使用しない |
| Service (ディスクキャッシュ鍵) | `com.zumix.jirafs.cachekey.<SHA256(product\|instanceName) 先頭16B hex>` / Account `cache_encryption_key` |

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

`Info.plist` の `FSSupportedSchemes` には `jira` のみを登録する。マウントコマンドは `jira://<host>` 形式で発行する。


## 設定ファイル (AppStore と派生 config.json)

設定の source of truth は **ホストアプリ**が保持する `AppStore` で、**`~/Library/Application Support/jirafs/appstore.json`** に保存される。`AppStore` は以下の 2 要素を持つ。

- **Server**: 再利用可能な接続情報 + 共有クレデンシャル。1 つの Server で JIRA / Confluence の両方の接続先を持て、認証情報 (Keychain) は Server 単位で共有する。
- **Mount**: Server とプロダクト (`jira` / `confluence`) をマウントポイントに束ねた単位。フィルタ (`allowedKeys`)、`diskCache`、`htmlView`、`includeArchived` (Confluence のみ)、`includeRestricted` (Confluence のみ)、`autoMount` などのオプションを持つ。

ホストアプリは `AppStore` を保存するたびに、各 FSKit Extension が読む **派生 `config.json` を自動生成**する。Extension はサンドボックス化されているため、App Group を使わず各 Extension のサンドボックスコンテナ内に config.json を書き込む (ホストアプリは非サンドボックスのため直接書き込める)。

| ファイル | 役割 |
| --- | --- |
| `~/Library/Application Support/jirafs/appstore.json` | source of truth (Server + Mount) |
| `~/Library/Containers/com.zumix.jirafs.fskit/Data/Library/Application Support/jirafs/config.json` | JIRA 拡張用の派生設定 |
| `~/Library/Containers/com.zumix.jirafs.confluencefs.fskit/Data/Library/Application Support/confluencefs/config.json` | Confluence 拡張用の派生設定 |

派生された JIRA 用 `config.json` のスキーマ (`JiraFSCore.Configuration`):

```json
{
  "version": 1,
  "instances": [
    {
      "mountID": "…",
      "serverID": "…",
      "name": "my-cloud",
      "type": "cloud",
      "url": "https://mycompany.atlassian.net",
      "auth": {
        "method": "api_token",
        "email": "user@example.com"
      },
      "mountPath": "~/jirafs/my-cloud",
      "diskCache": true,
      "htmlView": false,
      "autoMount": false
    },
    {
      "mountID": "…",
      "serverID": "…",
      "name": "my-server",
      "type": "server",
      "url": "https://jira.internal.example.com",
      "auth": {
        "method": "pat"
      },
      "mountPath": "~/jirafs/my-server",
      "allowedProjectKeys": ["PROJ", "OPS"],   // 設定時は listProjects() 一括取得ではなく getProject(key:) 並列呼び出しで取得 (Server の大量プロジェクト対策)
      "diskCache": true,
      "htmlView": true,
      "autoMount": false
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
- [x] 認証 (API Token + PAT + Anonymous) — `APITokenAuth` / `PATAuth` / `NoneAuth`
- [x] プロジェクト一覧 → ディレクトリ
- [x] イシュー一覧 → ディレクトリ (ページネーション対応)
- [x] イシュー詳細 → ファイル群 (summary.txt, description.md, metadata.json)
- [x] コメント → ファイル群 (`NNN_author_YYYY-MM-DD.md`)
- [x] 添付ファイル → ファイル (遅延ダウンロード、Range リクエスト対応)
- [x] In-Memory キャッシュ (TTL ベース actor)
- [x] Keychain 認証情報管理 (Access Group 共有)
- [x] エラーハンドリング (`JiraAPIError` → POSIX 変換) ・ロギング (`os.Logger` subsystem `com.zumix.jirafs`)
- [x] ADF / wiki markup → Markdown レンダラ (主要ノード対応)
- [x] `RateLimiter` (429 + Retry-After / 5xx 指数バックオフ、最大 3 回、Retry-After 上限 60s クランプ)
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
- 添付ファイルの大きなバイナリは HTTP Range でストリーミングし、小サイズのみメモリにキャッシュする (ディスクには書き出さない)。`CacheManager` の L2 ディスクキャッシュ (AES-GCM) は API レスポンス用で、添付本体は保持しない
- JIRA Cloud の ADF (Atlassian Document Format) → Markdown 変換は完全でない場合がある (主要ノードのみ対応、それ以外は raw fallback)
- Server 版の wiki markup → Markdown 変換の互換性 (見出し / リスト / リンク / 強調 / `{code}` / `{panel}` / `{quote}` のみ)
- JIRA Cloud v3 の `/search/jql` エンドポイントを使用 (2024年以降推奨の API)
- `searchIssues` (Server v2) は `GET /rest/api/2/search` を使用

## Confluence 対応

JIRA と同じ FSKit 基盤の上に、Confluence のページツリーをファイルシステムとして
マウントする機能を提供する。JIRA 用拡張 (`jirafs-extension`) とは独立した別の
App Extension (`confluencefs-extension`) として実装し、ホストアプリ (`jirafs`) が
両方を埋め込む。

### 共有フレームワーク構成

Confluence 対応にあたり、認証・HTTP・キャッシュ・Keychain・ファイル名サニタイズ等の
プロダクト非依存ロジックを `AtlassianCore` フレームワークに抽出した。

| フレームワーク | 役割 | デプロイ |
| --- | --- | --- |
| `AtlassianCore` | 認証 (`AuthProvider` / `APITokenAuth` / `PATAuth` / `NoneAuth`)、`HTTPTransport`、`RateLimiter`、`KeychainManager`、`CacheManager`、`FileNameSanitizer`、`ADFRenderer`、`AtlassianError` | 14.0 |
| `ConfluenceAPI` | Confluence REST クライアント (`ConfluenceRESTClient`)、モデル、`ConfluenceEdition` | 14.0 |
| `ConfluenceFSCore` | パス解決・キャッシュ連携・本文変換 (`ConfluencePathResolver` / `PageDataSource` / `PageFileBuilder` / `StorageFormatRenderer` / `ConfluenceConfiguration`) | 14.0 |
| `confluencefs-extension` | FSKit App Extension (`ConfluenceFileSystem` / `ConfluenceVolume`) | 15.4 |

### バンドル ID

App Extension のバンドル ID は親アプリ (`com.zumix.jirafs`) の prefix が必須。

- JIRA 拡張: `com.zumix.jirafs.fskit`
- Confluence 拡張: `com.zumix.jirafs.confluencefs.fskit`

### 認証 / エディション

| エディション | API | 認証 |
| --- | --- | --- |
| Cloud | `/wiki/api/v2/` (カーソルページネーション) | API Token (email + token, Basic) / API Token (scoped) / Anonymous |
| Data Center | `/rest/api/` (start/limit ページネーション) | PAT (Bearer) / Anonymous |

Keychain は JIRA と同じ共有アクセスグループ
(`$(AppIdentifierPrefix)com.zumix.jirafs.shared`) を使用する。Anonymous (匿名) は
認証情報を保存せず、`Authorization` ヘッダなしでリクエストするため、公開された
Confluence スペース / ページを認証なしでマウントできる。HTTPS 必須は維持される。

### ディレクトリ構造

子ページは親ページのディレクトリ配下に再帰的にネストする。

```
/spaces/{SPACEKEY}/
├── .space.json                    # スペースのメタデータ
└── pages/
    ├── {Page Title}.html          # htmlView:true のときのみ。フォルダの兄弟
    └── {Page Title}/
        ├── page.md                # # タイトル + 本文 (storage/ADF → Markdown)
        ├── .metadata.json         # 構造化メタデータ
        ├── .labels.txt            # ラベル一覧
        ├── .comments/
        │   └── NNN_author_date.md
        ├── .attachments/
        ├── {Folder Title}/        # Cloud のみ。フォルダ (再帰)
        ├── {Whiteboard Title}/    # Cloud のみ。ホワイトボード
        │   ├── .metadata.json     # ホワイトボードのメタデータ (webURL 含む)
        │   ├── whiteboard.md      # rovoWhiteboards:true のときのみ。キャンバスのテキスト化
        │   ├── whiteboard.json    # rovoWhiteboards:true のときのみ。MCP レスポンス生データ
        │   ├── whiteboard.svg     # rovoWhiteboards:true のときのみ。キャンバスの近似描画
        │   └── ...                # 配下のページ / フォルダ / ホワイトボード (再帰)
        ├── {Child Page Title}.html
        └── {Child Page Title}/    # 子ページ (再帰)
            └── ...
```

ルート直下には `spaces/` のほか、`AGENTS.md` (エージェント向けガイド)、
`.confluencefs/config.json`、`.metadata_never_index` を配置する。

#### フォルダ / ホワイトボード (Cloud のみ)

Cloud の v2 `direct-children` API (`pages/{id}` / `folders/{id}` /
`whiteboards/{id}`) で取得したフォルダ・ホワイトボードを、ページと同じ階層に
ディレクトリとして表示する。ホワイトボードのキャンバス内容は REST API で取得
できないため、`.metadata.json` (id / title / spaceId / parentId / authorId /
createdAt / webURL) のみを公開し、実体は `webURL` からブラウザで開く。
ホワイトボードもフォルダと同様にページ・フォルダ・ホワイトボードを内包できる。
名前が衝突する場合は同一ディレクトリ内でページ → フォルダ → ホワイトボードの
順に重複解決 (`FileNameSanitizer.deduplicate`) する。Data Center には
フォルダ / ホワイトボードの概念がないため常に空。

#### ホワイトボードのキャンバス取得 (Rovo MCP / 実験的)

`rovoWhiteboards: true` のマウントに限り、ホワイトボードディレクトリに
`whiteboard.md` (Markdown 化) / `whiteboard.json` (レスポンス生データ) /
`whiteboard.svg` (キャンバスの近似描画) を追加
する。3 ファイルは同一のキャッシュエントリを共有するため API 呼び出しは 1 回。
内容は Atlassian Rovo MCP サーバ
(`https://mcp.atlassian.com/v1/mcp`) の Teamwork Graph 系ツールから取得する。

- `AtlassianCore.MCPClient` が JSON-RPC 2.0 over Streamable HTTP を話す
  (`initialize` → `notifications/initialized` → `tools/list` / `tools/call`)。
  レスポンスは JSON / SSE の両方を受理し、`Mcp-Session-Id` を保持する
- 認証は `AuthProvider` に委譲。Rovo MCP の API トークン認証を使うため
  **Cloud + `apiToken` のマウントのみ有効**。それ以外は起動時に無効化してログを残す
- ツールは beta のため、`ConfluenceAPI.RovoWhiteboardSource` がマウントごとに
  一度 `tools/list` を実行し、`getTeamworkGraphObject(cloudId:objects:)` /
  `getTeamworkGraphContext(cloudId:objectIdentifier:objectType:detailLevel:)`
  を明示的に束縛する。未知のツールは `inputSchema` から URL/ARI を受け取る
  プロパティを推定してフォールバックする。候補は順に試し、成功したものを固定する
- `cloudId` はサイトの `_edge/tenant_info` (認証不要) から取得してキャッシュする
- `getTeamworkGraphContext` の `objectType` は `ConfluenceWhiteboard`
- **`tools/list` の中身はトークンのスコープとエンドポイントで変わる**。
  `/v1/mcp` は Confluence アプリの scoped トークンなら Teamwork Graph 系 3 ツール、
  Rovo アプリの scoped トークンなら 45 ツールを返す。
  **`/v2/mcp` は別系統のサーバ**で 17 ツール (`discover` / `execute` /
  `getConfluenceContent` など) を返し、`fetchAtlassian` は存在しない。
  `discover` は約 219 オペレーションのカタログを検索し、`execute` が
  名前指定でそれを実行する二段構え。したがって「このツールは存在しない」と
  判断する前に、どのエンドポイント・どのアプリのトークンかを確認すること
- v2 の `getConfluenceContent` は `content_format` に `svg` / `png` を取り、
  ホワイトボードの公式エクスポートを返す (`png` は
  `api.media.atlassian.com` の presigned URL で、認証なしで取得できる)。
  jirafs はこれを使わず自前描画する — MCP + Rovo v2 トークン + 組織設定に
  依存させないため。画像が取れない点は公式エクスポートも同じ
- ホワイトボードの `_links.webui` は相対パスなので `{baseURL}/wiki{webui}` に
  絶対化して渡す
- `getTeamworkGraphObject` は URL を解決できないとき **HTTP 200 + `objects: []`
  + `errors[]`** を返す (`isError` は立たない)。`resolutionFailure(in:)` で
  この形を失敗と見なし、ARI
  (`ari:cloud:confluence:{cloudId}:whiteboard/{id}`) で再試行し、それも駄目なら
  次のツールにフォールバックする。成功したロケータ形式はピン留めする
- 前提条件が 2 つあり、どちらも Atlassian 側の設定で、満たさないと `tools/call`
  だけが 403 で失敗する (`tools/list` までは成功する)
  - 組織が API トークンによる MCP 接続を許可していること
    (`You don't have permission to connect via API token.`)
  - スコープ付き API トークンであること。スコープ無しの旧トークンは不可
    (`Teamwork Graph tools require a modern API token (API token with scopes).`)
    → サーバの認証方式を **API Token (scoped)** にする。REST 呼び出しは
    `api.atlassian.com` ゲートウェイ経由になる (「認証方式」節を参照)
- いずれも `MCPError.accessDenied` としてマウント単位でスティッキーにキャッシュし
  (リトライ嵐の防止)、`EACCES` を返す
- Rovo MCP はサイト単位で 500〜1000 calls/hour のレート制限があり、GA 後は
  Rovo クレジット課金になるため、キャッシュ TTL は `pageDetail` と 1 時間の
  大きい方を採用する (`PageDataSource.whiteboardContentMinimumTTL`)
- レスポンスは生のままキャッシュし、`whiteboard.json` にはそのまま出力する。
  `whiteboard.md` は生成時に
  `WhiteboardCanvasRenderer` で Markdown 化する。JSON は 3 重にネストしており
  (MCP エンベロープ → `raw.bodyValue` の `WHITEBOARD_DOC_FORMAT` 文字列 →
  各ノードの `text` は ADF 文字列)、ノードをキャンバス座標の
  上→下・左→右順に並べて箇条書きにする。テキストを持たないノードは
  種別と個数を末尾に要約する。ベータ仕様のため形が変わったら
  `nil` を返して生レスポンスをそのまま出力する
- `whiteboard.svg` は `WhiteboardSVGRenderer` がキャンバスを SVG に近似描画する。
  ノードを `zIndex` 順に描き、全ノードの外接矩形 + 余白を `viewBox` にする
  - `geometry.position` はノードの**中心**座標 (左上ではない)。`geometry` が
    無いノードは `legacyGeometry` を見る
  - `sticky` / `text` / `shape` → 角丸矩形 + 中央寄せテキスト。折り返し幅は
    CJK を 1.0em、それ以外を 0.55em として概算する
  - `drawing` → `points` (`"0"` / `"1"` キーの**絶対**座標) を各セグメント中点を
    通る二次ベジェで平滑化して描く (直線結びだと Confluence よりカクカクして見える)。
    このノードは `legacyGeometry` しか持たないため外接矩形も points から求める
  - `connector` → `presentation: dynamic` は Confluence では直角ルーティングなので、
    `sourceAnchor` / `targetAnchor` の法線方向に 24 単位のスタブを伸ばして
    角丸 (r=8) のエルボーを描く。`endCap` / `startCap` が `arrow` のときだけ
    矢印マーカーを付け、`strokeStyle: dashed` は破線にする
  - コネクタの `start` / `end` は形状を動かすと**古い値のまま残る**キャッシュなので、
    トップレベル `edges` の `sourceNode` / `targetNode` からノードを引いて
    アンカー位置を再計算する (引けないときだけ `start` / `end` にフォールバック)
  - `image` → 実体は Atlassian Media Services にあり、Confluence の API トークン
    (scoped / unscoped どちらも) では取得できない。破線のプレースホルダに
    mimeType / `nativeSize` / `fileId` 先頭 8 桁をラベルとして描く
    (枠の高さに収まらない行は落とす)。取得不能の根拠は
    [媒体取得が不可能な理由](#媒体取得が不可能な理由) を参照
  - 色トークン `palette.{light|dark}.{hue}.{shade}` は公開値が無いため HSL で
    近似する (厳密な一致ではない)
  - 描画できない形のときは `nil` を返し、タイトルのみのプレースホルダ SVG を出力する

#### 媒体取得が不可能な理由

ホワイトボードの `image` ノードが持つのは Media Services の `fileId` だけで、
ダウンロード URL は含まれない。実測した結果:

- `https://api.atlassian.com/ex/confluence/{cloudId}` ゲートウェイは
  **スコープ不足のパスも存在しないパスも区別なく 401
  `"Unauthorized; scope does not match"`** で返す。この 401 単体は
  「スコープが足りない」証拠にも「エンドポイントが無い」証拠にもならない
- そこで **Confluence の read 系スコープを全て付与したトークン**で再検証した。
  スコープ追加が効いていることは `pages/{id}/footer-comments` が
  401 → 200 に変わったことで確認済み。その状態でも
  `/wiki/rest/api/media/token` は GET / POST (`collectionNames` 有無、
  `contentId` 有無) の全形式で 401 のまま。
  **read 権限を最大化しても media 経路は開かない**
- サイトホスト直叩き + unscoped API トークンでは `/wiki/rest/api/media/token` が
  **404** (エンドポイント自体が存在しない)
- `https://api.media.atlassian.com/file/{fileId}` は media トークン必須で 401
- ホワイトボードの画像は添付として登録されていない
  (`readonly:content.attachment:confluence` 付きでも v1
  `content/{whiteboardId}/child/attachment` は 200 で空、
  v2 `attachments` の一覧にも `fileId` は現れない)
- Rovo MCP 経由も不可。`initialize` の `capabilities` は `resources: {}` を広告するが、
  `resources/list` / `resources/templates/list` / `prompts/list` はいずれも
  `-32601 Method not found` を返す (広告だけで未実装)。**Rovo アプリの scoped
  トークンで 45 ツールが見える状態でも同じ**。`fetchAtlassian` は名前に反して
  URL フェッチャーではなく ARI 指定の取得ツールで、whiteboard ARI は
  `Cannot find a page with id` (v2 pages API を叩いているだけ)、
  media ARI は **`Unsupported product: media`** を返す。
  `searchAtlassian` の結果にも media/image の ARI は現れない
- **決定打: Atlassian 自身のレンダラも画像を読めない。**
  MCP v2 (`https://mcp.atlassian.com/v2/mcp`) の
  `getConfluenceContent(content_format:)` はホワイトボードの公式エクスポートを返すが、
  - `svg` の `<image>` は `href` を持たず `data-file-id` だけの**空要素**
    (jirafs のプレースホルダと同じ構造)
  - `png` はサーバサイドでラスタライズした 1920x1080 の実画像を返し、付箋 /
    コネクタ / 手書きインクは完全に描画されるのに、**画像ノードの位置だけ
    `Failed to load / Try again` が焼き込まれる**

  したがって「API トークンでは取れない」ではなく
  **Atlassian のバックエンド自体がホワイトボード画像を再取得できない**のが実態。
  クライアント側の工夫では解決しない

#### 将来 API が更新されたときの再検証手順

上記は 2026-08 時点の実測。Atlassian 側が直せば状況は変わりうるので、
再調査するなら**この 1 点だけ**を見ればよい。

```
POST https://mcp.atlassian.com/v2/mcp   (Basic auth: email:Rovo スコープトークン)
  tools/call getConfluenceContent
    { cloudId, content_id: <whiteboardId>, content_format: "png" }
  → data.body.value の presigned URL を認証なしで GET
```

**得られた PNG の画像ノード位置に `Failed to load` が出なくなっていたら、
Atlassian 側が修復されたということ。** そのときだけ、以下を順に再確認する。

1. `content_format: "svg"` の `<image>` に `href` が入るようになったか
   → 入れば `WhiteboardSVGRenderer.imageElement` をリンク描画に変更できる
2. v2 `whiteboards/{id}/attachments` が 200 を返すようになったか
   → 返れば REST だけで完結し、MCP 依存なしで画像を取得できる
3. `/wiki/rest/api/media/token` が開いたか
   → 開けば `api.media.atlassian.com/file/{fileId}` を直接叩ける

**注意点** (調査時に踏んだ罠):

- ゲートウェイの 401 `"scope does not match"` は**存在しないパスでも同じ**。
  スコープ不足の証拠として使うなら、必ず
  「存在しないパス」と「スコープを足せば通ると分かっている既知のパス」の
  両方を対照群に入れること
- MCP の `tools/list` は**エンドポイントとトークンのアプリ種別で中身が変わる**。
  「そのツールは無い」と判断する前に前提を確認する
- MCP の SSE レスポンスには `: keepalive` 行が混ざる。`data: ` を剥がすだけでなく
  `^:` 行も落とさないとパースに失敗する
- `execute` の `inputs` は camelCase (`contentId`)、primary tool の
  `getConfluenceContent` は snake_case (`content_id`) と流儀が違う
- presigned URL の `token` クエリは**それ自体がクレデンシャル**。
  ログや issue に貼らない
- Rovo の `search` / `searchAtlassian` は**閲覧制限ページの本文もそのまま返す**。
  調査スクリプトでフリーテキスト検索を使うと事故るので ID 直指定にする

### 本文変換

- Cloud storage 形式 (XHTML) → `StorageFormatRenderer` で Markdown 変換
  (主要タグのみ対応、非対応は raw fallback マーカー付きで原文を保持)
- Cloud `atlas_doc_format` (ADF) → `AtlassianCore.ADFRenderer` で Markdown 変換
- `htmlView:true` の場合、各ページの兄弟として `{Title}.html` を生成
  (storage は原 XHTML を、それ以外は Markdown を `<pre>` に埋め込む)

### 設定ファイル

Confluence 用設定は JIRA とは別の config.json に保存する。

- パス: `~/Library/Containers/com.zumix.jirafs.confluencefs.fskit/Data/Library/Application Support/confluencefs/config.json`
- スキーマ: `ConfluenceConfiguration` (`instances` の各要素は
  `name` / `type` (cloud/dataCenter) / `url` / `auth` / `mountPath` /
  `allowedSpaceKeys` / `diskCache` / `htmlView` / `includeArchived` / `includeRestricted`)

#### 主要オプション

| オプション | 型 | デフォルト | 説明 |
|---|---|---|---|
| `allowedSpaceKeys` | `[String]?` | `null` (全スペース) | 表示するスペースキーの許可リスト (大文字小文字不問) |
| `diskCache` | `Bool` | `true` | AES-GCM 暗号化ディスクキャッシュを有効にする |
| `htmlView` | `Bool` | `false` | 各ページの兄弟として `{Title}.html` ファイルを生成する |
| `includeArchived` | `Bool` | `false` | アーカイブ済みページをディレクトリ一覧に含める |
| `includeRestricted` | `Bool` | `false` | ユーザー/グループ閲覧制限・編集制限があるページをディレクトリ一覧に含める。`false` (デフォルト) の場合、read または update 操作に 1 件以上のユーザー/グループ制限が設定されているページは非表示になる |
| `rovoWhiteboards` | `Bool` | `false` | **実験的**。ホワイトボードディレクトリに `whiteboard.md` / `whiteboard.json` / `whiteboard.svg` (Rovo MCP 経由のキャンバス取得) を追加する。Cloud + API Token 認証のマウントでのみ有効 (実際に `tools/call` が通るのは scoped トークンのみ) |

### マウント

```bash
# Cloud インスタンスをマウント (read-only)
/sbin/mount -F -t confluencefs -o ro 'confluence://example.atlassian.net' ~/confluencefs/myinstance

# アンマウント
diskutil unmount force ~/confluencefs/myinstance
```

ホストアプリ (`jirafs`) の UI から JIRA / Confluence のインスタンスを
それぞれ追加・編集・マウント・アンマウントできる。

### 既知の制約 (Confluence)

- read-only のみ (ページ編集は未対応)
- ルート直下 (親を持たない) のフォルダ / ホワイトボードを列挙する API が Cloud v2
  に存在しないため、これらはページ / フォルダ / ホワイトボード配下にあるものだけを表示する
- ホワイトボードの描画内容 (キャンバス) は REST API 非公開のため取得できない
- storage 形式 → Markdown 変換は主要タグのみ対応 (非対応タグは raw fallback)
- 大規模スペース (数千ページ) ではページツリーの遅延読み込みに依存
- `includeRestricted: false` (デフォルト) の Cloud での動作:
  - ルートページ一覧表示時: スペースのルートページのみを対象に v1 API で制限情報を取得 (`/wiki/rest/api/space/{key}/content/page?depth=root&expand=restrictions...`)
  - 子ページ一覧表示時: その親ページの直接の子ページのみを対象に取得 (`/wiki/rest/api/content/{id}/child/page?expand=restrictions...`)
  - 取得結果はページ一覧と同じ TTL でキャッシュされるため、2 回目以降は API 呼び出しなし
  - Data Center は list API の `expand=restrictions...` でインラインに制限情報を取得するため追加 API 呼び出しなし
