# jirafs Makefile
# 使い方: make <target>
#
#   make build      ビルド（署名付き）
#   make install    ビルド → /Applications/ にインストール
#   make register   fskitd 再起動 → 拡張を pluginkit 再登録
#   make reinstall  install + register を一括実行（入れ替え時の標準手順）
#   make open       ホストアプリを起動
#   make mount      設定ファイルをコピーしてマウント（INSTANCE/PATH を指定）
#   make unmount    アンマウント（PATH を指定）
#   make test       ユニットテスト
#   make generate   xcodegen でプロジェクト再生成
#   make clean      DerivedData を削除
#   make log        fskitd / 拡張のログをストリーム表示

# ──────────────────────────────────────────
# 設定（必要に応じて上書き可能）
# ──────────────────────────────────────────
DEVELOPER_DIR  ?= /Applications/Xcode-16.4.0.app/Contents/Developer
SCHEME         ?= jirafs
CONFIGURATION  ?= Debug
DERIVED_DATA   ?= build/DerivedData
APP_PATH        = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/jirafs.app
APPEX_PATH      = /Applications/jirafs.app/Contents/Extensions/jirafs-extension.appex

# マウント用（make mount INSTANCE=hoge.atlassian.net PATH=~/jirafs/hoge
INSTANCE       ?=
PATH_ARG       ?= ~/jirafs

XCODEBUILD = DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
	-project jirafs.xcodeproj \
	-scheme $(SCHEME) \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	-allowProvisioningUpdates

.PHONY: build install register reinstall open mount unmount remount fix-fskitd test generate clean log help

help: ## Display this help screen
	@grep -E '^[a-zA-Z][a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sed -e 's/^GNUmakefile://' | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ──────────────────────────────────────────
# ビルド
# ──────────────────────────────────────────
build: ## 署名付きビルド（-allowProvisioningUpdates）
	$(XCODEBUILD) build 2>&1 \
		| grep -E "error:|warning: |BUILD (SUCCEEDED|FAILED)" \
		| grep -v appintentsmetadataprocessor

# ──────────────────────────────────────────
# インストール（ビルド後 /Applications/ へコピー）
# ──────────────────────────────────────────
install: build ## ビルド → /Applications/jirafs.app にインストール
	sudo rm -rf /Applications/jirafs.app
	sudo cp -R "$(APP_PATH)" /Applications/
	@echo "✓ Installed /Applications/jirafs.app"

# ──────────────────────────────────────────
# fskitd 再起動 + 拡張再登録
# （install 後や入れ替え後は必ず実行）
# ──────────────────────────────────────────
register: ## fskitd を停止し拡張を pluginkit 再登録（install 後に必ず実行）
	@echo "Stopping fskitd..."
	-sudo kill $$(pgrep fskitd) 2>/dev/null; sleep 2
	sudo pluginkit -a "$(APPEX_PATH)"
	@echo "✓ Extension registered"

# ──────────────────────────────────────────
# 入れ替え標準手順（install + register）
# ──────────────────────────────────────────
reinstall: install register ## install + register を一括実行（入れ替え時の標準手順）

# ──────────────────────────────────────────
# アプリ起動
# ──────────────────────────────────────────
open: ## ホストアプリ（/Applications/jirafs.app）を起動
	open /Applications/jirafs.app

# ──────────────────────────────────────────
# マウント
# 使い方: make mount INSTANCE=hoge.atlassian.net PATH_ARG=~/jirafs/hoge
# ──────────────────────────────────────────
mount: ## マウント（例: make mount INSTANCE=hoge.atlassian.net PATH_ARG=~/jirafs/hoge）
	@if [ -z "$(INSTANCE)" ]; then \
		echo "ERROR: INSTANCE が未指定です。例: make mount INSTANCE=hoge.atlassian.net PATH_ARG=~/jirafs/hoge"; \
		exit 1; \
	fi
	mkdir -p "$(PATH_ARG)"
	@if sudo /sbin/mount -F -t jirafs -o ro "jira://$(INSTANCE)" "$(PATH_ARG)" 2>/tmp/jirafs_mount_err; then \
		echo "✓ Mounted jira://$(INSTANCE) → $(PATH_ARG)"; \
	elif grep -qE "extensionKit|error 2|not found" /tmp/jirafs_mount_err 2>/dev/null; then \
		echo "⚠ extensionKit error — restarting fskitd and retrying..."; \
		sudo kill $$(pgrep fskitd) 2>/dev/null; sleep 3; \
		sudo /sbin/mount -F -t jirafs -o ro "jira://$(INSTANCE)" "$(PATH_ARG)" && \
			echo "✓ Mounted jira://$(INSTANCE) → $(PATH_ARG) (after retry)" || \
			{ echo "✗ Mount failed after retry"; cat /tmp/jirafs_mount_err; exit 1; }; \
	else \
		cat /tmp/jirafs_mount_err; exit 1; \
	fi
	@mount | grep jirafs

# ──────────────────────────────────────────
# アンマウント
# 使い方: make unmount PATH_ARG=~/jirafs/hoge
# ──────────────────────────────────────────
unmount: ## アンマウント（例: make unmount PATH_ARG=~/jirafs/hoge）
	sudo /usr/sbin/diskutil unmount force "$(PATH_ARG)"
	@echo "✓ Unmounted $(PATH_ARG)"

remount: ## アンマウント→再マウント（extensionKit エラー回復用）
	@if [ -z "$(INSTANCE)" ]; then \
		echo "ERROR: INSTANCE が未指定です。例: make remount INSTANCE=hoge.atlassian.net PATH_ARG=~/jirafs/hoge"; \
		exit 1; \
	fi
	-sudo /usr/sbin/diskutil unmount force "$(PATH_ARG)" 2>/dev/null; true
	$(MAKE) mount INSTANCE=$(INSTANCE) PATH_ARG=$(PATH_ARG)

fix-fskitd: ## fskitd を再起動して extensionKit エラーを解消
	@echo "Killing fskitd..."
	-sudo kill $$(pgrep fskitd) 2>/dev/null; true
	@echo "Waiting for fskitd to restart..."
	@sleep 3
	@pgrep fskitd > /dev/null && echo "✓ fskitd restarted (PID: $$(pgrep fskitd))" || echo "⚠ fskitd not running (will start on demand)"

# ──────────────────────────────────────────
# テスト
# ──────────────────────────────────────────
test: ## ユニットテスト（JiraAPITests + JiraFSCoreTests）
	$(XCODEBUILD) test 2>&1 \
		| grep -E "error:|Test Suite|FAILED|passed|BUILD (SUCCEEDED|FAILED)" \
		| grep -v appintentsmetadataprocessor

# ──────────────────────────────────────────
# xcodegen
# ──────────────────────────────────────────
generate: ## xcodegen で project.yml から jirafs.xcodeproj を再生成
	xcodegen generate
	@echo "✓ jirafs.xcodeproj regenerated"

# ──────────────────────────────────────────
# クリーン
# ──────────────────────────────────────────
clean: ## DerivedData を削除
	rm -rf "$(DERIVED_DATA)"
	@echo "✓ DerivedData cleaned"

# ──────────────────────────────────────────
# ログ（リアルタイム）
# ──────────────────────────────────────────
log: ## fskitd / 拡張のログをリアルタイムストリーム表示
	log stream \
		--predicate 'subsystem CONTAINS "com.zumix.jirafs" OR process CONTAINS "fskitd"' \
		--level debug
