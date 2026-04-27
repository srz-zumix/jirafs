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

### Specs & Instructions

- 技術仕様: docs/SPEC.md
- 開発手順: docs/INSTRUCTIONS.md
