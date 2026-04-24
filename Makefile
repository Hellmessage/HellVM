# HellVM —— 所有构建产物输出到 build/
#
# 零环境可构建: 空白 Mac 上 `make build` 一条命令跑通,
# 新增外部依赖时请同步更新 scripts/install-deps.sh / scripts/build-qemu.sh。
#
# 用 `make help` 查看所有可用 target。

# ==== 配置 ========================================================
CONFIG          ?= release

# ==== 产物名 ======================================================
APP_NAME        := HellVM.app
CLI_NAME        := hellvm
DBG_NAME        := hvmdbg
PROBE_NAME      := iosurface-probe

# ==== 构建路径 ====================================================
BUILD_DIR       := build
APP_OUT         := $(BUILD_DIR)/$(APP_NAME)
CLI_OUT         := $(BUILD_DIR)/$(CLI_NAME)
DBG_OUT         := $(BUILD_DIR)/$(DBG_NAME)
PROBE_OUT       := $(BUILD_DIR)/$(PROBE_NAME)

# ==== 源文件 (用于 incremental 判断) ==============================
# 任一 swift 源变更 -> 触发 swift build 重跑 (swift 自身也会做增量)
SWIFT_SOURCES   := $(shell find Sources -name '*.swift' -type f 2>/dev/null) Package.swift
PROBE_SRC       := tools/iosurface-probe.c

# ==== 安装路径 (可通过 env 覆盖) ==================================
# 例: USER_BIN_DIR=~/bin make install
USER_APP_DIR    ?= $(HOME)/Applications
USER_BIN_DIR    ?= $(HOME)/.local/bin
SYSTEM_APP_DIR  ?= /Applications
SYSTEM_BIN_DIR  ?= /usr/local/bin

# ==== .PHONY ======================================================
.PHONY: all help
.PHONY: build app hvmdbg cli probe
.PHONY: run test
.PHONY: clean distclean
.PHONY: install install-system uninstall uninstall-system

# ==== 复用宏 ======================================================
# swift 产物 -> build/ 拷贝。
# 用 ditto 而非 cp: 部分 macOS 版本 cp 会丢 code signature 元数据,
# AMFI 校验失败会直接 SIGKILL。
define swift_product
	@swift build -c $(CONFIG) --product $(1)
	@mkdir -p $(BUILD_DIR)
	@ditto "$$(swift build -c $(CONFIG) --show-bin-path)/$(1)" "$(BUILD_DIR)/$(1)"
	@echo "==> $(BUILD_DIR)/$(1)"
endef

# root 权限检查 (install-system / uninstall-system 用)
define require_root
	@if [ "$$(id -u)" != "0" ]; then \
	  echo "!! $(1) 需 root 权限, 请用 'sudo make $(1)'"; \
	  exit 1; \
	fi
endef

# ==== 默认 target =================================================

all: build  ## 默认 = build

##@ 构建

build: app $(DBG_OUT)  ## 构建主 App + hvmdbg 调试工具

# 主 App: bundle.sh 内部自处理 up-to-date 逻辑, 保持 PHONY
app:  ## 构建主 App (.app bundle + ad-hoc 签名)
	@bash scripts/bundle.sh

# 文件 target: 源文件未变则跳过。swift build 自身也有增量。
$(DBG_OUT): $(SWIFT_SOURCES)
	$(call swift_product,$(DBG_NAME))

$(CLI_OUT): $(SWIFT_SOURCES)
	$(call swift_product,$(CLI_NAME))

# P4 Sprint 2 端到端验证工具: 连 iosurface socket, dump 一帧 PPM
$(PROBE_OUT): $(PROBE_SRC)
	@mkdir -p $(BUILD_DIR)
	@clang -O2 -Wall -o $@ $<
	@echo "==> $@"

# alias: 允许 `make hvmdbg` / `make cli` / `make probe` 直接调用
hvmdbg: $(DBG_OUT)    ## 构建 hvmdbg (端到端诊断/操作 guest 的调试探针)
cli:    $(CLI_OUT)    ## 构建 hellvm CLI
probe:  $(PROBE_OUT)  ## 构建 iosurface-probe (连 iosurface socket, dump 一帧 PPM)

##@ 运行 / 测试

run: build  ## 启动 App
	@open $(APP_OUT)

test:  ## 运行测试 (需完整 Xcode.app 的 Testing 框架, CLT 环境不够)
	@swift test || { \
	  echo ""; \
	  echo "提示: 若提示 'no such module Testing',说明当前是 Command Line Tools 环境。"; \
	  echo "      需安装完整 Xcode.app,或者在 Xcode.app 的 toolchain 下运行测试。"; \
	  exit 1; \
	}

##@ 清理

clean:  ## 清理构建产物 (保留 build/ 下的用户文件, 比如 ISO)
	@rm -rf $(APP_OUT) $(CLI_OUT) $(DBG_OUT) $(PROBE_OUT)
	@rm -rf .build
	@echo "==> 已清理 $(APP_OUT) $(CLI_OUT) $(DBG_OUT) $(PROBE_OUT) .build/"

distclean: clean  ## 深度清理 (含 Vendor/, 下次 make build 会重编 QEMU)
	@rm -rf Vendor
	@echo "==> 已清理 Vendor/"

##@ 安装 / 卸载
# 用 ditto 拷贝 .app 与 CLI, cp -R 在某些 macOS 版本会丢 code signature
# 元数据, 被 AMFI 校验失败后 SIGKILL。
#
# install           —— 用户级, 无需 sudo, 自动 build + cli
# install-system    —— 系统级, 需 sudo; 不自动 build, 避免 root 污染 .build/Vendor
# uninstall         —— 对称卸载用户级
# uninstall-system  —— 对称卸载系统级, 需 sudo

install: build $(CLI_OUT)  ## 用户级安装 (默认 ~/Applications 与 ~/.local/bin, 无需 sudo)
	@mkdir -p "$(USER_APP_DIR)" "$(USER_BIN_DIR)"
	@rm -rf "$(USER_APP_DIR)/$(APP_NAME)"
	@ditto "$(APP_OUT)" "$(USER_APP_DIR)/$(APP_NAME)"
	@echo "==> $(USER_APP_DIR)/$(APP_NAME)"
	@rm -f "$(USER_BIN_DIR)/$(CLI_NAME)"
	@ditto "$(CLI_OUT)" "$(USER_BIN_DIR)/$(CLI_NAME)"
	@echo "==> $(USER_BIN_DIR)/$(CLI_NAME)"
	@# 若 USER_BIN_DIR 不在 PATH 里, 提示用户加一行
	@case ":$$PATH:" in \
	  *":$(USER_BIN_DIR):"*) ;; \
	  *) echo ""; \
	     echo "提示: $(USER_BIN_DIR) 不在 PATH 里, hellvm 不能直接调用."; \
	     echo "      把下面一行加到 ~/.zshrc 或 ~/.bashrc 后 source:"; \
	     echo "        export PATH=\"$(USER_BIN_DIR):\$$PATH\"" ;; \
	esac

install-system:  ## 系统级安装 (需 sudo, 先以普通用户跑 `make build cli`)
	$(call require_root,install-system)
	@test -d "$(APP_OUT)" || { echo "!! 未找到 $(APP_OUT), 请先以普通用户跑 'make build'"; exit 1; }
	@test -x "$(CLI_OUT)" || { echo "!! 未找到 $(CLI_OUT), 请先以普通用户跑 'make cli'"; exit 1; }
	@mkdir -p "$(SYSTEM_APP_DIR)" "$(SYSTEM_BIN_DIR)"
	@rm -rf "$(SYSTEM_APP_DIR)/$(APP_NAME)"
	@ditto "$(APP_OUT)" "$(SYSTEM_APP_DIR)/$(APP_NAME)"
	@echo "==> $(SYSTEM_APP_DIR)/$(APP_NAME)"
	@rm -f "$(SYSTEM_BIN_DIR)/$(CLI_NAME)"
	@ditto "$(CLI_OUT)" "$(SYSTEM_BIN_DIR)/$(CLI_NAME)"
	@echo "==> $(SYSTEM_BIN_DIR)/$(CLI_NAME)"

uninstall:  ## 用户级卸载
	@rm -rf "$(USER_APP_DIR)/$(APP_NAME)"
	@rm -f  "$(USER_BIN_DIR)/$(CLI_NAME)"
	@echo "==> 已卸载 $(USER_APP_DIR)/$(APP_NAME)"
	@echo "==> 已卸载 $(USER_BIN_DIR)/$(CLI_NAME)"

uninstall-system:  ## 系统级卸载 (需 sudo)
	$(call require_root,uninstall-system)
	@rm -rf "$(SYSTEM_APP_DIR)/$(APP_NAME)"
	@rm -f  "$(SYSTEM_BIN_DIR)/$(CLI_NAME)"
	@echo "==> 已卸载 $(SYSTEM_APP_DIR)/$(APP_NAME)"
	@echo "==> 已卸载 $(SYSTEM_BIN_DIR)/$(CLI_NAME)"

##@ 帮助

help:  ## 显示此帮助
	@awk 'BEGIN { FS = ":.*?## "; printf "\nHellVM Makefile —— 可用 target:\n" } \
	     /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	     /^[a-zA-Z_][a-zA-Z0-9_-]*:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	     END { printf "\n" }' $(MAKEFILE_LIST)
