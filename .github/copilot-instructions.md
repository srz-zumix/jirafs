## Project: jirafs

JIRA / Confluence のデータを macOS のファイルシステムとしてマウントするツール。
Apple FSKit (FSUnaryFileSystem) を使用した App Extension として実装（JIRA / Confluence それぞれ独立の拡張 + 単一のホストアプリ）。

### Tech Stack

- Swift 6.0, macOS 15.4+
- FSKit (FSUnaryFileSystem / FSVolume)
- JIRA REST API v2 (Server) / v3 (Cloud)
- Confluence REST API v1 (Data Center) / v2 (Cloud)
- SwiftUI (ホストアプリ)
- macOS Keychain (認証情報保存)

### Architecture

- `jirafs/` — ホストアプリ (設定 UI / メニューバー。Server/Mount モデル + AppStore)
- `jirafs-extension/` — JIRA FSKit App Extension
- `confluencefs-extension/` — Confluence FSKit App Extension
- `AtlassianCore/` — プロダクト非依存の共有ロジック (認証 / HTTP / RateLimiter / Keychain / 2 層キャッシュ / サニタイザ / ADF レンダラ)
- `JiraAPI/` — JIRA REST API クライアント・モデル (共有フレームワーク)
- `JiraFSCore/` — JIRA 用パス解決・データソース・本文変換 (共有フレームワーク)
- `ConfluenceAPI/` — Confluence REST API クライアント・モデル (共有フレームワーク)
- `ConfluenceFSCore/` — Confluence 用パス解決・データソース・本文変換 (共有フレームワーク)

### Key Conventions

- FSKit の reply handler パターンに従う (completion handler ベース)
- 内部 API は async/await で実装し、FSKit 境界で変換
- エラーは POSIXError に変換して返却
- ログは os.Logger で出力 (subsystem: `com.zumix.jirafs`)。HTTP エラーのレスポンスボディは `privacy: .private`、URL / ステータスコードのみ `.public`
- 認証情報は Keychain に保存、平文保存禁止。クレデンシャルは Server 単位で共有 (JIRA / Confluence 共通)
- **接続 URL は `https://` 必須**。ServerEditorView が非 HTTPS URL を拒否する (Save / Verify を無効化)
- ファイル名はサニタイズ必須 (パストラバーサル防止)
- API レスポンスは Codable モデルにデコード
- キャッシュは TTL ベース (In-Memory + オプションで AES-GCM 暗号化ディスク)
- 設定はホストアプリの `AppStore` (appstore.json) が source of truth。保存時に各拡張のサンドボックスに `config.json` を派生
- **フィルタ設定をキャッシュキーに反映**する (対象データごとに方針が異なる):
  - *フィルタ済み・ディレクトリ単位のフェッチ* (`restrictedRootPageIDs` / `restrictedChildPageIDs` など): `includeRestricted` / `includeArchived` などのフラグ値または allowedKeys のフィンガープリントをキャッシュキーに組み込む。これによりフラグ変更がマウント再読み込みで即反映される
  - *全スペース/プロジェクトのリスト*: 未フィルタでキャッシュし読み出し時にフィルタする。キャッシュキーにフラグを含めない (フィルタ変更でキャッシュを捨てない)
- **Confluence 制限フィルタ** (`includeRestricted: false` がデフォルト): Cloud は `restrictedRootPageIDs(spaceKey:status:)` / `restrictedChildPageIDs(pageId:status:)` でディレクトリ単位に制限 ID を取得 (全スペーススキャン禁止)。DC は list expand で inline 取得。単一フライトで並列重複呼び出しを防ぐ (`pendingRestrictedIDsFetch`)
- **新しいオプションを Mount / ConfluenceConfiguration.InstanceEntry に追加する手順**: `Mount` struct → `ConfluenceConfiguration.InstanceEntry` → `AppConfig.deriveConfluence` → `ConfluenceFileSystem.lookupInstance` タプル → `PageDataSource` init の順でスタック全体を通す。`includeArchived` / `includeRestricted` の実装を参照すること

### File System Layout

JIRA (`jirafs-extension` / `JiraFSCore`):

```
/projects/{KEY}/issues/{ISSUE-KEY}/
  ├── summary.txt        # 1行テキスト
  ├── description.md     # Markdown 変換済み
  ├── metadata.json      # 構造化メタデータ
  ├── comments/           # コメントファイル群
  └── attachments/        # 添付ファイル
```

Confluence (`confluencefs-extension` / `ConfluenceFSCore`):

```
/spaces/{KEY}/
  ├── .space.json        # スペースメタデータ
  └── pages/{Title}/      # ルートページ (子ページは {Title}/{Title}/ とネスト)
      ├── page.md         # 本文を Markdown 変換 (フロントマター付き)
      ├── .metadata.json  # 構造化ページメタデータ
      ├── .labels.txt     # 1行1ラベル
      ├── .comments/       # コメント (NNN_author_date.md)
      └── .attachments/    # 添付ファイル
```

Cloud のみ `pages/folders/{Title}/` フォルダ、`.archived/` ディレクトリ (アーカイブ済みページ一覧) が現れる。

### Coding Rules

- コーディング中の TEMP ディレクトリは .gitignore された `tmp/` を使用
- フォルダ命名は Swift 慣例: `Tests/` `Documentation/` `AtlassianCore/` `JiraAPI/` `JiraFSCore/` `ConfluenceAPI/` `ConfluenceFSCore/` は PascalCase、製品名そのものの `jirafs/` `jirafs-extension/` `confluencefs-extension/` は lowercase
- 新規 Swift ソースを追加したら `xcodegen generate` を実行 (`project.yml` がソース・オブ・トゥルース、`jirafs.xcodeproj` は gitignore 済)
- ビルド・テストは Xcode 16.4+ / `DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer` 必須
- `xcodebuild` で `CODE_SIGNING_ALLOWED=NO` を付与するのは CI / unit test / 署名不要ビルドに限定する。FSKit Extension を実際に mount・検証するビルドや release 用ビルドでは署名が必要なので、`Documentation/INSTRUCTIONS.md` と release workflow の手順に従う
- ホスト/拡張は `MACOSX_DEPLOYMENT_TARGET=15.4`、共有フレームワーク (`AtlassianCore` / `JiraAPI` / `JiraFSCore` / `ConfluenceAPI` / `ConfluenceFSCore`) / Tests は `14.0` を維持
- Swift 6 strict concurrency 準拠。FSKit reply handler を `Task` でキャプチャするときは `SendableBox(reply)` でラップ
- `actor` 内の `while` ループで mutable var をクロージャに渡す前に `let` で不変コピーを取る
- `*/Info.plist` の `CFBundleShortVersionString` / `CFBundleVersion` は `.github/workflows/release-drafter.yml` が自動更新するため、Agent は変更しないこと

### CI / GitHub Actions

- PR で `.github/workflows/build.yml` が走る (macos-15 / Xcode 16.4)
- ビルド対象判定は `srz-zumix/gh-pr-ls-files` で `Documentation/**` `**/*.md` `LICENSE` を exclude し変更ファイル数で分岐
- `build-result` ジョブ (status check job) は `if: failure() || cancelled()` で `build` が失敗/キャンセル時のみ実行・fail (skip 時は GitHub の skip-satisfies-required により required check を満たす) → Rulesets の required check に指定
- Workflow の third-party action は SHA で pin (`pinact run` で更新)、`actions/*` のみタグ可 (`.pinact.yaml`)
- Workflow 編集後は `zizmor` で security 監査して findings 0 を確認
- 既存 workflow: `build.yml` / `labeler.yml` / `release.yml` / `release-drafter.yml` / `zizmor.yml`

### Specs & Instructions

- 技術仕様: Documentation/SPEC.md
- 開発手順: Documentation/INSTRUCTIONS.md
