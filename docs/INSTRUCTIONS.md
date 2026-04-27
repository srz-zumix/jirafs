# jirafs 開発手順書

## 前提条件

- macOS 15.4 以降 (実機マウント検証時)
- macOS 14.0 以降 (フレームワーク・テストビルドのみ)
- **Xcode 16.4 以降 (必須)** — FSKit SDK が同梱されたバージョンを使用する。`DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer` などで切り替える。
- Swift 6.0
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — `project.yml` から `jirafs.xcodeproj` を生成
- Apple Developer Program メンバーシップ (FSKit entitlement 取得のため、実機動作時)

## プロジェクトセットアップ

### 1. プロジェクト構成

プロジェクトは **XcodeGen** で `project.yml` から生成する (`jirafs.xcodeproj` は .gitignore 済)。

```bash
brew install xcodegen
xcodegen generate    # project.yml → jirafs.xcodeproj
```

```text
jirafs/
├── project.yml                       # XcodeGen プロジェクト定義
├── jirafs.xcodeproj                  # 生成物、gitignore
├── jirafs/                          # ホストアプリ (設定 UI)
│   ├── JiraFSApp.swift                # SwiftUI App エントリ
│   ├── ContentView.swift              # インスタンス一覧
│   ├── InstanceEditorView.swift       # インスタンス CRUD + Keychain 保存
│   ├── MountControlView.swift         # mount コマンド生成・設定ガイド
│   └── AppConfig.swift                # config.json ロード/セーブ
├── jirafs-extension/                # FSKit App Extension
│   ├── JiraFSExtension.swift          # UnaryFileSystemExtension エントリ
│   ├── JiraFileSystem.swift           # FSUnaryFileSystem サブクラス
│   ├── JiraVolume.swift               # FSVolume サブクラス (アイテムテーブル保持)
│   ├── JiraVolume+Operations.swift    # FSVolume.Operations
│   ├── JiraVolume+ReadWrite.swift     # FSVolume.ReadWriteOperations
│   ├── JiraVolume+OpenClose.swift     # FSVolume.OpenCloseOperations + payload ロード
│   ├── JiraFSItem.swift               # FSItem サブクラス (Kind ベース)
│   ├── FSKitError.swift               # JiraAPIError → POSIX 変換
│   └── SendableBox.swift              # 非 Sendable 値を Task に渡すためのラッパ
├── JiraAPI/                         # JIRA REST API クライアント (Framework)
│   ├── JiraClient.swift               # クライアントプロトコル + JiraInstanceConfig + JiraEdition
│   ├── JiraRESTClient.swift           # Cloud (v3) / Server (v2) 共通実装
│   ├── JiraHTTPTransport.swift        # テスト可能な HTTP 抽象
│   ├── AuthProvider.swift             # 認証プロトコル
│   ├── APITokenAuth.swift             # API Token (Cloud) Basic auth
│   ├── PATAuth.swift                  # PAT (Server) Bearer
│   ├── KeychainManager.swift          # Access Group 共有
│   ├── RateLimiter.swift              # 429 / 5xx 指数バックオフ
│   ├── Models.swift                   # JiraProject / JiraIssue / JiraComment / JiraAttachment / JiraUser / JSONValue
│   ├── JiraAPIError.swift
│   └── Logging.swift
├── JiraFSCore/                      # 共有ロジック (Framework)
│   ├── Configuration.swift            # config.json スキーマ
│   ├── PathResolver.swift             # FSNodeKind と パスの変換
│   ├── CacheManager.swift             # TTL actor キャッシュ
│   ├── IssueDataSource.swift          # JiraClient + CacheManager 統合
│   ├── ContentRenderer.swift          # ADF / wiki markup → Markdown
│   ├── IssueFileBuilder.swift         # summary.txt / description.md / metadata.json / comments 生成
│   └── FileNameSanitizer.swift        # パストラバーサル防止 + 衰名衰避
├── Tests/
│   ├── JiraAPITests/                  # AuthTests / JiraRESTClientTests (URLProtocol stub)
│   └── JiraFSCoreTests/               # FileNameSanitizer / PathResolver / ContentRenderer / CacheManager
└── docs/
    ├── SPEC.md
    └── INSTRUCTIONS.md
```

### 2. Xcode ターゲット構成

#### ホストアプリ (`jirafs`)

- **Platform**: macOS
- **Type**: SwiftUI App
- **用途**: 接続設定 UI、認証情報管理、拡張機能の有効化ガイド
- **Entitlements**:
  - `com.apple.security.app-sandbox`
  - `com.apple.security.keychain-access-groups`
  - `com.apple.security.network.client`

#### App Extension (`jirafs-extension`)

- **Platform**: macOS
- **Type**: File System Extension (FSKit)
- **Entitlements**:
  - `com.apple.developer.fskit.fsmodule`
  - `com.apple.security.network.client`
  - `com.apple.security.keychain-access-groups`

#### Info.plist (Extension)

```xml
<key>EXAppExtensionAttributes</key>
<dict>
    <key>EXExtensionPointIdentifier</key>
    <string>com.apple.fskit.fsmodule</string>
    <key>FSShortName</key>
    <string>jirafs</string>
    <key>FSSupportsURLMounting</key>
    <true/>
    <key>FSMatchingURLSchemes</key>
    <array>
        <string>jira</string>
        <string>https</string>
    </array>
</dict>
```

> `https` スキームは他システムと競合しうるため、ホストアプリ側で `jira://` へ正規化することを推奨。
>
> **Phase 1 注意**: FSKit 15.4 SDK に URL ベース `FSResource` サブクラスが未公開のため、`loadResource` は渡された URL を使わずホストアプリの `config.json` の先頭インスタンスを使用する。複数インスタンス選択は将来拡張予定。

#### Keychain Access Group (両ターゲット共通)

```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.zumix.jirafs.shared</string>
</array>
```

ホストアプリで保存した認証情報を Extension が読み取るため、ホストアプリと Extension の両方の entitlements に同一の Access Group を指定する。

### 3. 共有フレームワーク

`JiraAPI` と `JiraFSCore` は Embedded Framework としてホストアプリと Extension の両方で共有。

## 開発ステップ (Phase 1)

Phase 1 (MVP) の実装ステップとはどこまで進んだかを記録する。

### ✅ Step 1: FSKit スキャフォールド

- [x] XcodeGen で `project.yml` 作成 (4 ターゲット + 2 テスト)
- [x] `JiraFSExtension` に `UnaryFileSystemExtension` を実装
- [x] `JiraFileSystem` で `FSUnaryFileSystem` をサブクラス化
- [x] `JiraVolume` で `FSVolume` をサブクラス化 (Operations / PathConfOperations / OpenCloseOperations / ReadWriteOperations)
- [x] Xcode 16.4 / FSKit SDK 同梱でビルド成功

### ✅ Step 2: JIRA API クライアント

- [x] `JiraClient` プロトコル定義
- [x] データモデル定義 (`Models.swift` に集約: JiraProject / JiraIssue / JiraIssueFields / JiraComment / JiraAttachment / JiraUser / JiraIssueLink / JiraSearchResult / JSONValue)
- [x] `JiraRESTClient` 実装 (Cloud v3 / Server v2 は `JiraEdition` で切替、本体は 1 実装)
- [x] 認証プロバイダ (`APITokenAuth`, `PATAuth`)
- [x] `KeychainManager` 実装 (Access Group 共有)
- [x] `RateLimiter` 実装 (429 / 5xx 指数バックオフ、最大 3 回)
- [x] `JiraHTTPTransport` プロトコルで URLSession を抽象化しスタブ可能に
- [x] ユニットテスト (`JiraAPITests`: 5 件 pass)

### ✅ Step 3: パスの解決とアイテム管理

- [x] `PathResolver` 実装 (FSNodeKind とパスの双方向変換)
- [x] `JiraFSItem` 実装 (Kind ごとに決定的 ID)
- [x] `lookupItem` / `enumerateDirectory` / `getAttributes` (スケルトン、コンパイル検証は Xcode 16.4+ 待ち)
- [x] `IssueDataSource` で `JiraClient + CacheManager` を統合し Volume から使いやすく

### ✅ Step 4: ファイル内容の読み取り

- [x] `ContentRenderer` 実装
  - ADF (Cloud) パーサ: paragraph / heading / bulletList / orderedList / codeBlock / blockquote / panel / rule / table / mediaSingle / mediaGroup / media / mention / emoji + marks (strong / em / code / strike / link)
  - Wiki Markup (Server) パーサ: 見出し (h1〜h6) / `{code}` / `{quote}` / `{panel}` / 強調 / リンク / 番号リスト
  - 変換不能な型は raw + `<!-- jirafs: raw fallback -->`
- [x] `IssueFileBuilder` (summary.txt / description.md / metadata.json / project meta / comment body)
- [x] `FSVolume.OpenCloseOperations.open` 時に payload をロードし `cachedData` に保持
- [x] `FSVolume.ReadWriteOperations.read` で `cachedData` をスライスして返却 (書き込みは `EROFS`)

### ✅ Step 5: 添付ファイル対応

- [x] `listAttachments` エンドポイント (`fields=attachment` を個別デコード)
- [x] `downloadAttachment` (Range リクエスト対応)
- [x] `IssueDataSource.attachmentData` でキャッシュ (TTL 1800s)
- [ ] 大バイナリの真のストリーミング (現状は一括ダウンロード)

### ✅ Step 6: キャッシュ

- [x] `CacheManager` actor 実装
- [x] TTL ベースキャッシュ
- [x] `synchronize` で全クリア

### ✅ Step 7: ホストアプリ UI

- [x] JIRA インスタンス設定画面 (NavigationSplitView)
- [x] 認証情報入力・保存 (`KeychainManager`)
- [x] mount コマンド生成・拡張機能設定へのディープリンク

### ✅ Step 8: テスト・品質

- [x] ユニットテスト (現在 25 件 pass)
- [x] `URLProtocol` スタブで Cloud/Server クライアント検証
- [ ] 実 JIRA インスタンスでの E2E テスト (Xcode 16.4+ 必要)
- [ ] パフォーマンステスト (大量イシュー)

## ビルド & テスト

Xcode 16.4 以降を選択していることを確認する (`xcode-select -p` または `DEVELOPER_DIR=...`)。

```bash
# プロジェクト生成 (project.yml を編集した後は毎回実行)
xcodegen generate

# ビルド (FSKit entitlement のため CODE_SIGNING_ALLOWED=NO を付与)
DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer \
  xcodebuild -project jirafs.xcodeproj -scheme jirafs -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO build

# テスト (JiraAPITests + JiraFSCoreTests, deployment target 14.0)
DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer \
  xcodebuild -project jirafs.xcodeproj -scheme jirafs -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO test

# アーカイブ (開発者署名あり)
xcodebuild -scheme jirafs -configuration Release archive
```

> 拡張本体 (`jirafs-extension`) と `jirafs` ホストアプリは macOS 15.4 が必要 (FSKit 依存)。`JiraAPI` / `JiraFSCore` / テストは macOS 14.0 を維持し、Xcode 16.4 + macOS 14 以降のホストでテスト実行できる。

## マウント手順

マウントは **CLI / ホストアプリ UI** のいずれかを選択できる。いずれも **1 マウント = 1 JIRA スペース** を前提とする。

```bash
# 1. ホストアプリをビルド・実行して認証情報を保存
# 2. システム設定で jirafs 拡張を有効化
#    設定 > 一般 > ログイン項目と拡張機能 > ファイルシステム拡張機能

### A. CLI でマウント
mkdir ~/jirafs
mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs   # read-only
# または
mount -F -t jirafs -o rw jira://mycompany.atlassian.net ~/jirafs   # read-write

### B. ホストアプリ UI でマウント
# ホストアプリでインスタンスを選択し「マウント」ボタンを押下。
# デフォルトで /Volumes/jirafs-<instanceName> にマウントされる。

# 使用
ls ~/jirafs/projects/
cat ~/jirafs/projects/PROJ/issues/PROJ-1/summary.txt
cat ~/jirafs/projects/PROJ/issues/PROJ-1/description.md

# アンマウント
umount ~/jirafs
```

### 動作モード

| オプション | ボリューム能力 | Phase 1 の書き込み |
|---|---|---|
| `-o ro` | `readOnly = true` | カーネルが拒否 (`EROFS`) |
| `-o rw` | `readOnly = false` | メソッドが `ENOTSUP` を返す (Phase 2 で拡充) |

## コーディング規約

- Swift 6.0 準拠 (Strict Concurrency)
- `Sendable` 準拠を徹底
- `async/await` ベースの内部 API → FSKit の reply handler に橋渡し
- OSLog (Logger) によるログ出力
- エラーは POSIX エラーコードに変換して返却
- API クライアントは `protocol` ベースでテスタブルに

## トラブルシューティング

### FSKit 拡張が認識されない

- システム設定で拡張機能が有効になっているか確認
- SIP (System Integrity Protection) が有効な場合、開発者署名が必要
- `systemextensionsctl list` で拡張の状態確認

### マウントが失敗する

- `mount -F -t jirafs` の `-t` に指定する名前が `Info.plist` の `FSShortName` と一致しているか確認
- macOS 15+ では `-F` オプション (FSKit 経由) が必要。従来の `mount -t` だけでは認識されない
- JIRA URL が正しいか確認 (`jira://` への正規化推奨)
- ネットワーク接続を確認
- Console.app でログ確認 (subsystem: `com.zumix.jirafs`)

### JIRA API エラー

- 認証情報が正しいか Keychain で確認
- API のレート制限に達していないか確認
- JIRA インスタンスのバージョンに応じた API バージョンを使用しているか確認
