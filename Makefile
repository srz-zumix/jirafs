# jirafs Makefile
# 使い方: make <target>
#
#   make build          ビルド（署名付き）
#   make install        ビルド → /Applications/ にインストール（USE_BREW=1 で Homebrew 経由）
#   make register       fskitd 再起動 → 拡張を pluginkit 再登録
#   make reinstall      install + register を一括実行（入れ替え時の標準手順）
#   make open           ホストアプリを起動
#   make mount          設定ファイルをコピーしてマウント（INSTANCE/PATH を指定）
#   make mount-confluence  Confluence をマウント（INSTANCE/PATH を指定）
#   make unmount        アンマウント（PATH を指定）
#   make test           ユニットテスト
#   make generate       xcodegen でプロジェクト再生成
#   make clean          DerivedData を削除
#   make log            fskitd / 拡張のログをストリーム表示

# ──────────────────────────────────────────
# 設定（必要に応じて上書き可能）
# ──────────────────────────────────────────
DEVELOPER_DIR  ?= /Applications/Xcode-16.4.0.app/Contents/Developer
SCHEME         ?= jirafs
CONFIGURATION  ?= Debug
DERIVED_DATA   ?= build/DerivedData
APP_PATH        = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/jirafs.app
APPEX_PATH      = /Applications/jirafs.app/Contents/Extensions/jirafs-extension.appex
CONF_APPEX_PATH = /Applications/jirafs.app/Contents/Extensions/confluencefs-extension.appex

# USE_BREW=1 で Homebrew 経由インストール、0（デフォルト）でローカルビルド
USE_BREW       ?= 0
HOMEBREW_TAP   ?= srz-zumix/tap
HOMEBREW_CASK  ?= jirafs

# マウント用（make mount INSTANCE=hoge.atlassian.net PATH=~/jirafs/hoge
INSTANCE       ?=
PATH_ARG       ?= $(HOME)/jirafs

XCODEBUILD = DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
	-project jirafs.xcodeproj \
	-scheme $(SCHEME) \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	-allowProvisioningUpdates

.PHONY: build install _install_local _install_brew register reinstall open mount mount-confluence unmount remount fix-fskitd test generate clean log help

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
# インストール（ビルド後 /Applications/ へコピー、または Homebrew 経由）
# ──────────────────────────────────────────
_install_local: build
	sudo rm -rf /Applications/jirafs.app
	sudo cp -R "$(APP_PATH)" /Applications/
	@echo "✓ Installed /Applications/jirafs.app (local build)"

_install_brew:
	@if brew list --cask $(HOMEBREW_CASK) &>/dev/null; then \
		brew upgrade --cask --force $(HOMEBREW_TAP)/$(HOMEBREW_CASK); \
	else \
		brew install --cask --force $(HOMEBREW_TAP)/$(HOMEBREW_CASK); \
	fi

install: _install_$(if $(filter 1,$(USE_BREW)),brew,local) ## ビルド → /Applications/jirafs.app にインストール（USE_BREW=1 で Homebrew 経由）

# ──────────────────────────────────────────
# fskitd 再起動 + 拡張再登録
# （install 後や入れ替え後は必ず実行）
# ──────────────────────────────────────────
register: ## fskitd を停止し拡張を pluginkit 再登録（install 後に必ず実行）
	@echo "Stopping fskitd..."
	-sudo kill $$(pgrep fskitd) 2>/dev/null; sleep 2
	sudo pluginkit -a "$(APPEX_PATH)"
	sudo pluginkit -a "$(CONF_APPEX_PATH)"
	sudo pluginkit -e use -i com.zumix.jirafs.fskit
	sudo pluginkit -e use -i com.zumix.jirafs.confluencefs.fskit
	@echo "✓ Extensions registered and enabled"

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
# Confluence マウント
# 使い方: make mount-confluence INSTANCE=hoge.atlassian.net PATH_ARG=~/confluencefs/hoge
# ──────────────────────────────────────────
mount-confluence: ## Confluence をマウント（例: make mount-confluence INSTANCE=hoge.atlassian.net PATH_ARG=~/confluencefs/hoge）
	@if [ -z "$(INSTANCE)" ]; then \
		echo "ERROR: INSTANCE が未指定です。例: make mount-confluence INSTANCE=hoge.atlassian.net PATH_ARG=~/confluencefs/hoge"; \
		exit 1; \
	fi
	mkdir -p "$(PATH_ARG)"
	@if sudo /sbin/mount -F -t confluencefs -o ro "confluence://$(INSTANCE)" "$(PATH_ARG)" 2>/tmp/confluencefs_mount_err; then \
		echo "✓ Mounted confluence://$(INSTANCE) → $(PATH_ARG)"; \
	elif grep -qE "extensionKit|error 2|not found" /tmp/confluencefs_mount_err 2>/dev/null; then \
		echo "⚠ extensionKit error — restarting fskitd and retrying..."; \
		sudo kill $$(pgrep fskitd) 2>/dev/null; sleep 3; \
		sudo /sbin/mount -F -t confluencefs -o ro "confluence://$(INSTANCE)" "$(PATH_ARG)" && \
			echo "✓ Mounted confluence://$(INSTANCE) → $(PATH_ARG) (after retry)" || \
			{ echo "✗ Mount failed after retry"; cat /tmp/confluencefs_mount_err; exit 1; }; \
	else \
		cat /tmp/confluencefs_mount_err; exit 1; \
	fi
	@mount | grep confluencefs
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
	@# xcodegen は LSMultipleInstancesProhibited を削除してしまうため復元する
	@plutil -replace LSMultipleInstancesProhibited -bool YES jirafs/Info.plist
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
