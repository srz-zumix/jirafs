# jirafs 開発手順書

## 前提条件

- macOS 15.4 以降 (実機マウント検証時)
- macOS 14.0 以降 (フレームワーク・テストビルドのみ)
- **Xcode 16.4 以降 (必須)** — FSKit SDK が同梱されたバージョンを使用する。`DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer` などで切り替える。
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
├── jirafs/                          # ホストアプリ (設定 UI / メニューバー)
│   ├── JiraFSApp.swift                # SwiftUI App エントリ (メニューバー + Preferences)
│   ├── ContentView.swift              # サーバー / マウント一覧
│   ├── ServerStore.swift              # AppStore / Server / Mount / MountProduct モデル (source of truth)
│   ├── ServerEditorView.swift         # Server (接続 + 共有クレデンシャル) の CRUD + Keychain 保存
│   ├── MountEditorView.swift          # Mount (Server × Product → マウントポイント) の CRUD
│   ├── AppStoreModel.swift            # AppStore を包む ObservableObject (永続化 + config 派生)
│   ├── AppConfig.swift                # appstore.json ロード/セーブ + 拡張ごとの config.json 派生
│   ├── MountControlView.swift         # mount/unmount 操作・コマンド生成・設定ガイド
│   ├── MountStatusMonitor.swift       # マウント状態の定期監視 (メニューバー反映)
│   ├── MountPrivileged.swift          # 管理者権限での mount/unmount 実行
│   ├── LaunchAtLoginManager.swift     # ログイン時自動起動
│   ├── PreferencesView.swift          # 環境設定画面
│   ├── Info.plist
│   └── jirafs.entitlements
├── AtlassianCore/                   # プロダクト非依存の共有ロジック (Framework)
│   ├── AuthProvider.swift             # 認証プロトコル
│   ├── APITokenAuth.swift             # API Token (Cloud) Basic auth
│   ├── PATAuth.swift                  # PAT (Server / Data Center) Bearer
│   ├── KeychainManager.swift          # Access Group 共有
│   ├── HTTPTransport.swift            # テスト可能な HTTP 抽象
│   ├── RateLimiter.swift              # 429 / 5xx 指数バックオフ
│   ├── CacheManager.swift            # In-Memory + AES-GCM ディスクの 2 層キャッシュ actor
│   ├── FileNameSanitizer.swift        # パストラバーサル防止 + 重複回避
│   ├── ADFRenderer.swift              # Atlassian Document Format → Markdown
│   ├── JSONValue.swift                # 任意 JSON 値の Codable 表現
│   ├── AtlassianError.swift           # 共通エラー型
│   ├── AtlassianLog.swift             # os.Logger ラッパ
│   └── SendableBox.swift              # 非 Sendable 値を Task に渡すためのラッパ
├── JiraAPI/                         # JIRA REST API クライアント (Framework)
│   ├── JiraClient.swift               # クライアントプロトコル + JiraInstanceConfig + JiraEdition
│   ├── JiraRESTClient.swift           # Cloud (v3) / Server (v2) 共通実装
│   ├── Models.swift                   # JiraProject / JiraIssue / JiraComment / JiraAttachment / JiraUser
│   ├── AtlassianCompat.swift          # AtlassianCore への typealias (JiraAPIError 等の互換名)
│   └── Logging.swift
├── JiraFSCore/                      # JIRA 用 FS ロジック (Framework)
│   ├── Configuration.swift            # JIRA 用 config.json スキーマ
│   ├── PathResolver.swift             # FSNodeKind と パスの変換
│   ├── IssueDataSource.swift          # JiraClient + CacheManager 統合
│   ├── ContentRenderer.swift          # description/comment → Markdown (ADF は AtlassianCore.ADFRenderer に委譲、wiki markup は自前)
│   └── IssueFileBuilder.swift         # summary.txt / description.md / metadata.json / comments 生成
├── jirafs-extension/                # JIRA FSKit App Extension
│   ├── JiraFSExtension.swift          # UnaryFileSystemExtension エントリ
│   ├── JiraFileSystem.swift           # FSUnaryFileSystem サブクラス
│   ├── JiraFileSystem+ServerURL.m     # jira:// URL からホスト名を取得 (Obj-C)
│   ├── JiraVolume.swift               # FSVolume サブクラス (アイテムテーブル保持)
│   ├── JiraVolume+Operations.swift    # FSVolume.Operations + PathConfOperations
│   ├── JiraVolume+ReadWrite.swift     # FSVolume.ReadWriteOperations
│   ├── JiraVolume+OpenClose.swift     # FSVolume.OpenCloseOperations + payload ロード
│   ├── JiraFSItem.swift               # FSItem サブクラス (Kind ベース)
│   ├── FSKitError.swift               # JiraAPIError → POSIX 変換
│   ├── AGENTS.md                      # 拡張実装のエージェント向けガイド
│   ├── Info.plist
│   └── jirafs-extension.entitlements
├── ConfluenceAPI/                   # Confluence REST API クライアント (Framework)
│   ├── ConfluenceClient.swift         # クライアントプロトコル + ConfluenceEdition
│   ├── ConfluenceRESTClient.swift     # Cloud (v2) / Data Center (v1) 共通実装
│   ├── ConfluenceModels.swift         # ドメインモデル
│   └── ConfluenceWireModels.swift     # API レスポンスのデコードモデル
├── ConfluenceFSCore/                # Confluence 用 FS ロジック (Framework)
│   ├── ConfluenceConfiguration.swift  # Confluence 用 config.json スキーマ
│   ├── ConfluencePathResolver.swift   # ページツリー ↔ パスの変換
│   ├── PageDataSource.swift           # ConfluenceClient + CacheManager 統合
│   ├── PageFileBuilder.swift          # page.md / .metadata.json / .labels.txt / comments 生成
│   ├── ConfluenceContentRenderer.swift # 本文 → Markdown (storage / ADF)
│   └── StorageFormatRenderer.swift    # storage 形式 (XHTML) → Markdown
├── confluencefs-extension/          # Confluence FSKit App Extension
│   ├── ConfluenceFSExtension.swift    # UnaryFileSystemExtension エントリ
│   ├── ConfluenceFileSystem.swift     # FSUnaryFileSystem サブクラス
│   ├── ConfluenceFileSystem+ServerURL.m # confluence:// URL からホスト名を取得 (Obj-C)
│   ├── ConfluenceVolume.swift         # FSVolume サブクラス
│   ├── ConfluenceVolume+Operations.swift
│   ├── ConfluenceVolume+ReadWrite.swift
│   ├── ConfluenceVolume+OpenClose.swift
│   ├── ConfluenceFSItem.swift         # FSItem サブクラス
│   ├── FSKitError.swift               # AtlassianError → POSIX 変換
│   ├── AGENTS.md
│   ├── Info.plist
│   └── confluencefs-extension.entitlements
├── Tests/
│   ├── JiraAPITests/                  # JIRA Auth / JiraRESTClient (URLProtocol stub)
│   ├── JiraFSCoreTests/               # FileNameSanitizer / PathResolver / ContentRenderer / CacheManager / IssueDataSourcePagination
│   ├── ConfluenceAPITests/            # ConfluenceRESTClient (URLProtocol stub)
│   └── ConfluenceFSCoreTests/         # PathResolver / PageFileBuilder / StorageFormatRenderer 等
└── Documentation/
    ├── SPEC.md
    └── INSTRUCTIONS.md
```

### 2. Xcode ターゲット構成

#### ホストアプリ (`jirafs`)

- **Platform**: macOS
- **Type**: SwiftUI App
- **用途**: 接続設定 UI、認証情報管理、拡張機能の有効化ガイド
- **Entitlements**:
  - `com.apple.security.keychain-access-groups`
  - `com.apple.security.network.client`
- **備考**: ホストアプリは **sandbox 化しない**。`com.apple.security.app-sandbox` は現在の `jirafs/jirafs.entitlements` には含めず、特権的なマウント処理を阻害するため再追加しないこと。

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
    <key>FSSupportedSchemes</key>
    <array>
        <string>jira</string>
    </array>
</dict>
```
> `loadResource` は `JiraFileSystem+ServerURL.m` 経由で `jira://` URL のホスト名を取得し、`config.json` の中から `url.host` が一致するインスタンスを選択する（一致なしの場合は先頭インスタンスにフォールバック）。複数インスタンスを並行利用する場合は、それぞれ異なるホスト名の `jira://` URL でマウントする。

#### Keychain Access Group (両ターゲット共通)

```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.zumix.jirafs.shared</string>
</array>
```

ホストアプリで保存した認証情報を Extension が読み取るため、ホストアプリと Extension の両方の entitlements に同一の Access Group を指定する。

### 3. 共有フレームワーク

Embedded Framework としてホストアプリと各 Extension で共有する。

| フレームワーク | 役割 | 利用先 |
| --- | --- | --- |
| `AtlassianCore` | 認証 / HTTP / レート制限 / Keychain / 2 層キャッシュ / ファイル名サニタイズ / ADF レンダラ等のプロダクト非依存ロジック | 全ターゲット |
| `JiraAPI` | JIRA REST クライアント・モデル | jirafs / jirafs-extension |
| `JiraFSCore` | JIRA 用パス解決・データソース・本文変換 | jirafs / jirafs-extension |
| `ConfluenceAPI` | Confluence REST クライアント・モデル | jirafs / confluencefs-extension |
| `ConfluenceFSCore` | Confluence 用パス解決・データソース・本文変換 | jirafs / confluencefs-extension |

## 開発ステップ (Phase 1)

Phase 1 (MVP) の実装ステップとはどこまで進んだかを記録する。

### ✅ Step 1: FSKit スキャフォールド

- [x] XcodeGen で `project.yml` 作成 (7 プロダクトターゲット + 4 テストターゲット)
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
- [x] `IssueDataSource.attachmentData` でキャッシュ (TTL 1800s、小サイズのみ)
- [x] 大バイナリのストリーミング: `maxInlineAttachmentBytes` (既定 16 MiB) 超または不明サイズは Range で要求窓のみ取得しキャッシュしない (OOM/DoS ガード)

### ✅ Step 6: キャッシュ

- [x] `CacheManager` actor 実装
- [x] TTL ベースキャッシュ
- [x] `synchronize` で全クリア

### ✅ Step 7: ホストアプリ UI

- [x] Server (接続 + 共有クレデンシャル) / Mount (Server × Product → マウントポイント) の設定画面 (NavigationSplitView)
- [x] 認証情報入力・保存 (`KeychainManager`)
- [x] `AppStore` を source of truth とし、拡張ごとの `config.json` を自動派生
- [x] メニューバー常駐 + マウント状態監視 (`MountStatusMonitor`)
- [x] 管理者権限での mount/unmount 実行 (`MountPrivileged`) ・コマンド生成・拡張機能設定へのディープリンク

### ✅ Step 8: テスト・品質

- [x] ユニットテスト (`JiraAPITests` / `JiraFSCoreTests` / `ConfluenceAPITests` / `ConfluenceFSCoreTests`)
- [x] `URLProtocol` スタブで Cloud/Server クライアント検証
- [x] パフォーマンステスト (大量イシューでのページネーション — `IssueDataSourcePaginationTests`)
- [ ] 実 JIRA / Confluence インスタンスでの E2E テスト (Xcode 16.4+ / macOS 15.4+ 必要)

## ビルド & テスト

Xcode 16.4 以降を選択していることを確認する。

```bash
# Xcode バージョン確認
DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer xcodebuild -version
```

### プロジェクト生成

`project.yml` を編集したら **毎回** 実行する（`jirafs.xcodeproj` は .gitignore 済）。

```bash
xcodegen generate
```

### ビルド

FSKit 拡張を **実際に mount / runtime 検証するビルドではコード署名が必須** であり、この用途では `CODE_SIGNING_ALLOWED=NO` は使用しない。
一方、CI やローカルでの **フレームワーク層のコンパイル確認・テスト実行** では、署名不要のため `CODE_SIGNING_ALLOWED=NO` を使う構成がある。
実機動作確認用のビルドでは、`-allowProvisioningUpdates` を使い、Automatic Signing で証明書を自動取得する。

```bash
DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer \
  xcodebuild -project jirafs.xcodeproj \
             -scheme jirafs \
             -configuration Debug \
             -derivedDataPath build/DerivedData \
             -allowProvisioningUpdates \
             build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

### テスト

フレームワーク層（`AtlassianCore` / `JiraAPI` / `JiraFSCore` / `ConfluenceAPI` / `ConfluenceFSCore`）のテストは macOS 14.0 以降で実行可能。

```bash
DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer \
  xcodebuild -project jirafs.xcodeproj \
             -scheme jirafs \
             -configuration Debug \
             -derivedDataPath build/DerivedData \
             -allowProvisioningUpdates \
             test 2>&1 | grep -E "error:|Test Suite|FAILED|PASSED"
```

> 拡張本体 (`jirafs-extension` / `confluencefs-extension`) と `jirafs` ホストアプリは macOS 15.4 が必要 (FSKit 依存)。
> 共有フレームワーク (`AtlassianCore` / `JiraAPI` / `JiraFSCore` / `ConfluenceAPI` / `ConfluenceFSCore`) とテストは macOS 14.0 を維持し、Xcode 16.4 + macOS 14 以降のホストでテスト実行できる。

## インストールとマウント手順

### インストール

ビルド後、`/Applications/` にコピーする。

```bash
sudo cp -R build/DerivedData/Build/Products/Debug/jirafs.app /Applications/
```

### FSKit 拡張の登録

インストール後 **初回** または **アプリを入れ替えた後** に必ず実行する。

```bash
# 1. fskitd を再起動（古い拡張を掴んでいる場合はこれをしないとマウント失敗）
FSKITD_PID=$(sudo launchctl list 2>/dev/null | awk '/fskitd/{print $1}')
[ -n "$FSKITD_PID" ] && [ "$FSKITD_PID" != "-" ] && sudo kill -9 "$FSKITD_PID"

# 2. 5 秒待つ（fskitd が自動再起動するまで）
sleep 5

# 3. 拡張を登録（JIRA / Confluence の両方）
sudo pluginkit -a /Applications/jirafs.app/Contents/Extensions/jirafs-extension.appex
sudo pluginkit -a /Applications/jirafs.app/Contents/Extensions/confluencefs-extension.appex
```

登録確認:

```bash
pluginkit -m -A -i com.zumix.jirafs.fskit
pluginkit -m -A -i com.zumix.jirafs.confluencefs.fskit
```

### ホストアプリの起動と設定

1. `/Applications/jirafs.app` を起動
2. **Server** を追加（URL / Edition / 認証情報。JIRA と Confluence でクレデンシャルを共有可能）
3. **Mount** を追加（Server × Product → マウントポイント + フィルタ / オプション）
4. 認証情報は Keychain に保存され、拡張ごとの `config.json` が自動生成される

### マウント

マウントには `sudo` が必要。`mount -F` は FSKit (fskitd) 経由でのマウントを意味する。

```bash
# マウントポイント作成（初回のみ）
mkdir -p ~/jirafs

# マウント（read-only）
sudo /sbin/mount -F -t jirafs -o ro jira://<host> ~/jirafs

# 例: Atlassian Cloud
sudo /sbin/mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs

# 例: JIRA Server
sudo /sbin/mount -F -t jirafs -o ro jira://jira.example.com ~/jirafs
```

マウント確認:

```bash
mount | grep jirafs
ls ~/jirafs/projects/
```

### アンマウント

```bash
# 通常
sudo /sbin/umount ~/jirafs

# 強制（ビジー状態の場合）
sudo /usr/sbin/diskutil unmount force ~/jirafs
```

## ホストアプリの Mount ボタンを使う場合

UI から Mount / Unmount を操作できる。  
`do shell script … with administrator privileges` で macOS 標準のパスワードダイアログが表示され、root 権限で上記の `mount` コマンドが実行される。

失敗した場合はエラー欄に表示されるコマンドを手動で実行できる。

### 動作モード

| オプション | ボリューム能力 | Phase 1 の書き込み |
|---|---|---|
| `-o ro` | `readOnly = true` | カーネルが拒否 (`EROFS`) |
| `-o rw` | `readOnly = false` | メソッドが `ENOTSUP` を返す (Phase 2 で拡充) |

## コーディング規約

- Swift 6.0 準拠 (Strict Concurrency)
- `Sendable` 準拠を徹底
- `async/await` ベースの内部 API → FSKit の reply handler に橋渡し
- OSLog (Logger) によるログ出力。**HTTP エラーのレスポンスボディは `privacy: .private`**、URL / ステータスコードのみ `privacy: .public`
- エラーは POSIX エラーコードに変換して返却
- API クライアントは `protocol` ベースでテスタブルに
- **接続 URL は `https://` 必須** — ServerEditorView が非 HTTPS URL を拒否する。`http://` を受け入れると Basic / Bearer トークンが平文で送信されるため
- `RateLimiter` の `maxRetryAfter` (デフォルト 60s) を超える Retry-After は上限値にクランプする
- **`OSAllocatedUnfairLock` にクロージャを直接入れて `withLock { $0 }` で読み出さない** — 素のクロージャを generic な `withLock` から読み出すと毎回 reabstraction thunk が 1 層ずつ被さって保存値に書き戻され、読み出すたびにクロージャが深くなる。背景リフレッシュのように何千回も読み出すと数千層に達し、次の呼び出し (os_log を含む) がスタックを巻き戻す際にオーバーフローして `SIGBUS` (KERN_PROTECTION_FAILURE in stack guard) でクラッシュする。クロージャは `final class` の box に包んで保存し (`ListingRefreshedHandlerBox` / `IssueKeysRefreshedHandlerBox` 参照)、読み出しは参照ポインタを返すだけにすること。`withLock { $0?(arg) }` のようにロック内で呼ぶのも同様に蓄積するため不可

## トラブルシューティング

### `Resource busy` / `Operation not permitted` (code 69) でマウント失敗

fskitd が古いバージョンの拡張を掴んでいる。以下の手順で再登録する。

```bash
FSKITD_PID=$(sudo launchctl list 2>/dev/null | awk '/fskitd/{print $1}')
[ -n "$FSKITD_PID" ] && [ "$FSKITD_PID" != "-" ] && sudo kill -9 "$FSKITD_PID"
sleep 5
sudo pluginkit -a /Applications/jirafs.app/Contents/Extensions/jirafs-extension.appex
```

> アプリを `/Applications/` に再インストールするたびに、この手順が必要。

### `CODE_SIGNING_ALLOWED=NO` でビルドした拡張がマウントできない

FSKit 拡張は署名なしでは fskitd に拒否される。必ず `-allowProvisioningUpdates` で署名付きビルドを使うこと。

### ホストアプリが「管理者のユーザー名またはパスワードが違います」で失敗する

ホストアプリに `app-sandbox` entitlement が付与されていると `NSAppleScript with administrator privileges` が OS レベルでブロックされる。`project.yml` から `com.apple.security.app-sandbox: true` を削除して再ビルドすること。

### FSKit 拡張が認識されない

```bash
# 拡張の登録状態を確認
pluginkit -m -A -i com.zumix.jirafs.fskit

# 再登録
sudo pluginkit -a /Applications/jirafs.app/Contents/Extensions/jirafs-extension.appex
```

### ログ確認

```bash
# fskitd / 拡張のログをリアルタイム表示
log stream --predicate 'subsystem CONTAINS "com.zumix.jirafs" OR process CONTAINS "fskitd"' --level debug

# 過去 10 分のログ
log show --predicate 'subsystem CONTAINS "com.zumix.jirafs" OR process CONTAINS "fskitd"' \
  --last 10m --style compact | tail -50
```

### JIRA API エラー

- 認証情報が正しいか Keychain で確認
- API のレート制限に達していないか確認
- JIRA インスタンスのバージョンに応じた API バージョンを使用しているか確認（Cloud: v3 / Server: v2）

### 拡張が `SIGBUS` (KERN_PROTECTION_FAILURE in stack guard) でクラッシュする

- クラッシュレポートで同一の reabstraction thunk (`thunk for @escaping ... (Kind) -> ()`) が何千層も再帰し、最深部が os_log のスタックなら、`OSAllocatedUnfairLock` 内のクロージャを `withLock { $0 }` で繰り返し読み出して thunk が蓄積した可能性が高い。コーディング規約の box パターン (`ListingRefreshedHandlerBox` / `IssueKeysRefreshedHandlerBox`) で保存しているか確認する
- 修正後は **Clean Build (DerivedData 削除) → 署名ビルド → 再インストール** を必ず行う。古い `.appex` が残っていると修正前のバイナリで再現し続ける
