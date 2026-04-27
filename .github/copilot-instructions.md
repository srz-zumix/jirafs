## Project: jirafs

JIRA のデータを macOS のファイルシステムとしてマウントするツール。
Apple FSKit (FSUnaryFileSystem) を使用した App Extension として実装。

### Tech Stack

- Swift 6.0, macOS 15.4+
- FSKit (FSUnaryFileSystem / FSVolume)
- JIRA REST API v2 (Server) / v3 (Cloud)
- SwiftUI (ホストアプリ)
- macOS Keychain (認証情報保存)

### Architecture

- `jirafs/` — ホストアプリ (設定 UI)
- `jirafs-extension/` — FSKit App Extension (ファイルシステム実装)
- `JiraAPI/` — JIRA REST API クライアント (共有フレームワーク)
- `JiraFSCore/` — パス解決・キャッシュ・変換ロジック (共有フレームワーク)

### Key Conventions

- FSKit の reply handler パターンに従う (completion handler ベース)
- 内部 API は async/await で実装し、FSKit 境界で変換
- エラーは POSIXError に変換して返却
- ログは os.Logger で出力 (subsystem: `com.zumix.jirafs`)
- 認証情報は Keychain に保存、平文保存禁止
- ファイル名はサニタイズ必須 (パストラバーサル防止)
- JIRA API レスポンスは Codable モデルにデコード
- キャッシュは TTL ベース (In-Memory)

### File System Layout

```
/projects/{KEY}/issues/{ISSUE-KEY}/
  ├── summary.txt        # 1行テキスト
  ├── description.md     # Markdown 変換済み
  ├── metadata.json      # 構造化メタデータ
  ├── comments/           # コメントファイル群
  └── attachments/        # 添付ファイル
```

### Coding Rules

- コーディング中の TEMP ディレクトリは .gitignore された `tmp/` を使用
- フォルダ命名は Swift 慣例: `Tests/` `Documentation/` `JiraAPI/` `JiraFSCore/` は PascalCase、製品名そのものの `jirafs/` `jirafs-extension/` は lowercase
- 新規 Swift ソースを追加したら `xcodegen generate` を実行 (`project.yml` がソース・オブ・トゥルース、`jirafs.xcodeproj` は gitignore 済)
- ビルド・テストは Xcode 16.4+ / `DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer` 必須
- `xcodebuild` は常に `CODE_SIGNING_ALLOWED=NO` を付与 (FSKit entitlement のため)
- ホスト/拡張は `MACOSX_DEPLOYMENT_TARGET=15.4`、`JiraAPI` / `JiraFSCore` / Tests は `14.0` を維持
- Swift 6 strict concurrency 準拠。FSKit reply handler を `Task` でキャプチャするときは `SendableBox(reply)` でラップ
- `actor` 内の `while` ループで mutable var をクロージャに渡す前に `let` で不変コピーを取る

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
