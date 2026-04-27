# jirafs

JIRA のデータを macOS のファイルシステムとしてマウントするツール。
Apple [FSKit](https://developer.apple.com/documentation/FSKit) フレームワーク (FSUnaryFileSystem) を利用し、JIRA のプロジェクト・イシューを標準的なファイル操作でアクセス可能にします。

## 特徴

- JIRA Cloud / Server 両対応
- **1 マウント = 1 JIRA スペース** シンプルなマッピング
- イシューをディレクトリとして表現 (summary.txt, description.md, metadata.json, comments/, attachments/)
- 標準 UNIX ツール (`ls`, `cat`, `grep`, `find`) で JIRA データを操作
- read-only / read-write モードをマウント時に選択可 (Phase 1 では書き込みは `ENOTSUP` を返す)
- macOS Keychain (Access Group 共有) による安全な認証情報管理
- TTL ベースの In-Memory キャッシュ

## 対象環境

- macOS 15.4+ (Sequoia)
- Xcode 16.0+
- Swift 6.0

## ファイルシステムレイアウト

```
~/jirafs/
└── projects/
    └── PROJ/
        └── issues/
            └── PROJ-1/
                ├── summary.txt        # イシューのサマリー
                ├── description.md     # 説明 (Markdown)
                ├── metadata.json      # メタデータ (status, assignee 等)
                ├── comments/          # コメントファイル群
                └── attachments/       # 添付ファイル
```

## 使い方

マウントは CLI またはホストアプリ UI から行えます。

```bash
# マウントポイント作成
mkdir ~/jirafs

# マウント (read-only 推奨)
mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs

# JIRA データにアクセス
ls ~/jirafs/projects/
cat ~/jirafs/projects/PROJ/issues/PROJ-1/summary.txt

# アンマウント
umount ~/jirafs
```

> 複数の JIRA インスタンスを並行利用する場合は、それぞれ別のマウントポイントにマウントしてください。

## ドキュメント

- [技術仕様](Documentation/SPEC.md)
- [開発手順](Documentation/INSTRUCTIONS.md)

## ライセンス

[LICENSE](LICENSE) を参照
