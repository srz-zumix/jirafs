# jirafs 開発手順書

## 前提条件

- macOS 15.4 以降
- Xcode 16.0 以降
- Swift 6.0
- Apple Developer Program メンバーシップ (FSKit entitlement 取得のため)

## プロジェクトセットアップ

### 1. Xcode プロジェクト作成

```text
jirafs/
├── jirafs.xcodeproj
├── jirafs/                          # ホストアプリ (設定 UI)
│   ├── jirafsApp.swift
│   ├── ContentView.swift
│   ├── Assets.xcassets/
│   ├── Info.plist
│   └── jirafs.entitlements
├── jirafs-extension/                # FSKit App Extension
│   ├── JiraFSExtension.swift        # UnaryFileSystemExtension 準拠
│   ├── JiraFileSystem.swift         # FSUnaryFileSystem サブクラス
│   ├── JiraVolume.swift             # FSVolume サブクラス
│   ├── JiraVolume+Operations.swift  # FSVolume.Operations 実装
│   ├── JiraVolume+ReadWrite.swift   # FSVolume.ReadWriteOperations 実装
│   ├── JiraVolume+OpenClose.swift   # FSVolume.OpenCloseOperations 実装
│   ├── JiraFSItem.swift             # FSItem サブクラス
│   ├── Info.plist
│   └── jirafs-extension.entitlements
├── JiraAPI/                         # JIRA API クライアント (共有フレームワーク)
│   ├── JiraClient.swift             # API クライアント本体
│   ├── JiraCloudClient.swift        # Cloud 用実装 (REST API v3)
│   ├── JiraServerClient.swift       # Server 用実装 (REST API v2)
│   ├── AuthProvider.swift           # 認証プロバイダ プロトコル
│   ├── APITokenAuth.swift           # API Token 認証
│   ├── PATAuth.swift                # Personal Access Token 認証
│   ├── OAuthProvider.swift          # OAuth 2.0 認証 (Phase 3)
│   ├── Models/
│   │   ├── JiraProject.swift
│   │   ├── JiraIssue.swift
│   │   ├── JiraComment.swift
│   │   ├── JiraAttachment.swift
│   │   ├── JiraUser.swift
│   │   └── JiraSearchResult.swift
│   ├── KeychainManager.swift        # Keychain アクセス
│   └── RateLimiter.swift            # レート制限管理
├── JiraFSCore/                      # 共有ロジック
│   ├── CacheManager.swift           # キャッシュ管理
│   ├── PathResolver.swift           # パス ↔ JIRA リソース変換
│   ├── ContentRenderer.swift        # ADF/Wiki → Markdown 変換
│   ├── FileNameSanitizer.swift      # ファイル名サニタイズ
│   └── Configuration.swift          # 設定管理
├── Tests/
│   ├── JiraAPITests/
│   ├── JiraFSCoreTests/
│   └── IntegrationTests/
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

### Step 1: FSKit スキャフォールド

1. Xcode プロジェクト作成 (macOS App)
2. File System Extension ターゲット追加
3. `JiraFSExtension` に `UnaryFileSystemExtension` を実装
4. `JiraFileSystem` で `FSUnaryFileSystem` をサブクラス化
5. `JiraVolume` で `FSVolume` をサブクラス化
6. ビルド・動作確認 (空のファイルシステム)

### Step 2: JIRA API クライアント

1. `JiraClient` プロトコル定義
2. データモデル定義 (`JiraProject`, `JiraIssue`, etc.)
3. `JiraCloudClient` 実装 (REST API v3)
4. `JiraServerClient` 実装 (REST API v2)
5. 認証プロバイダ実装 (`APITokenAuth`, `PATAuth`)
6. `KeychainManager` 実装
7. ユニットテスト

### Step 3: パスの解決とアイテム管理

1. `PathResolver` 実装 (パス文字列 ↔ `JiraFSItem.Kind` 変換)
2. `JiraFSItem` 実装
3. `lookupItem` 実装
4. `enumerateDirectory` 実装
5. `getAttributes` 実装

### Step 4: ファイル内容の読み取り

1. `ContentRenderer` 実装
   - Markdown 出力には [`apple/swift-markdown`](https://github.com/apple/swift-markdown) を依存追加
   - ADF (Cloud) パーサは自作、Wiki Markup (Server) パーサも自作
   - 変換失敗時は raw をそのまま出力 (`<!-- jirafs: raw fallback -->` ヘッダ付与)
2. `FSVolume.ReadWriteOperations.read()` 実装
3. `FSVolume.OpenCloseOperations` 実装
4. 各ファイル種別のデータ生成 (summary.txt, description.md, metadata.json, comments)

### Step 5: 添付ファイル対応

1. 添付ファイル一覧取得
2. 添付ファイル遅延ダウンロード
3. ストリーミング読み取り

### Step 6: キャッシュ

1. `CacheManager` 実装
2. TTL ベースキャッシュ
3. キャッシュ無効化 (`synchronize`)

### Step 7: ホストアプリ UI

1. JIRA インスタンス設定画面
2. 認証情報入力・保存
3. 拡張機能有効化ガイド

### Step 8: テスト・品質

1. ユニットテスト完備
2. モック JIRA サーバーによる統合テスト
3. 実際の JIRA インスタンスでの E2E テスト
4. パフォーマンステスト (大量イシュー)

## ビルド & テスト

```bash
# ビルド
xcodebuild -scheme jirafs -configuration Debug build

# テスト
xcodebuild -scheme jirafs -configuration Debug test

# アーカイブ
xcodebuild -scheme jirafs -configuration Release archive
```

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
