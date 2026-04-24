# HellVM —— 所有构建产物输出到 build/
.PHONY: all build run cli test clean probe \
        install install-system uninstall uninstall-system

CONFIG ?= release

# 安装路径 —— 可通过 env 覆盖 (e.g. USER_BIN_DIR=~/bin make install)
USER_APP_DIR    ?= $(HOME)/Applications
USER_BIN_DIR    ?= $(HOME)/.local/bin
SYSTEM_APP_DIR  ?= /Applications
SYSTEM_BIN_DIR  ?= /usr/local/bin

APP_NAME := HellVM.app
CLI_NAME := hellvm
APP_SRC  := build/$(APP_NAME)
CLI_SRC  := build/$(CLI_NAME)

all: build

# 构建主 App(.app bundle + ad-hoc 签名)
build:
	@bash scripts/bundle.sh

# P4 Sprint 2 端到端验证工具:连 iosurface socket, dump 一帧 PPM
probe:
	@mkdir -p build
	@clang -O2 -Wall -o build/iosurface-probe tools/iosurface-probe.c
	@echo "==> build/iosurface-probe"

# 构建 CLI
# 注意:必须用 ditto 而非 cp,cp 在部分 macOS 版本会丢 code signature 元数据,
# AMFI 校验失败会直接 SIGKILL 进程(Taskgated Invalid Signature)
cli:
	@swift build -c $(CONFIG) --product hellvm
	@mkdir -p build
	@ditto "$$(swift build -c $(CONFIG) --show-bin-path)/hellvm" build/hellvm
	@echo "==> build/hellvm"

# 启动 App
run: build
	@open build/HellVM.app

# 运行测试(CLT 环境缺 Testing 框架;装了 Xcode.app 后会自动可用)
test:
	@swift test || { \
		echo ""; \
		echo "提示: 若提示 'no such module Testing',说明当前是 Command Line Tools 环境。"; \
		echo "      需安装完整 Xcode.app,或者在 Xcode.app 的 toolchain 下运行测试。"; \
		exit 1; \
	}

# 清理(只删构建产物,保留 build/ 下的其他用户文件,比如 ISO)
clean:
	@rm -rf build/HellVM.app build/hellvm
	@rm -rf .build
	@echo "==> 已清理 build/HellVM.app build/hellvm .build/"

# 深度清理(含 Vendor/qemu,下次 make build 要重编 QEMU)
distclean: clean
	@rm -rf Vendor
	@echo "==> 已清理 Vendor/ (下次 make build 会重新编译 QEMU)"

# ---------------- 安装 / 卸载 ----------------
# 用 ditto 拷贝 .app 与 CLI, cp -R 在某些 macOS 版本会丢 code signature
# 元数据, 被 AMFI 校验失败后 SIGKILL。
#
# install           —— 当前用户目录, 无需 sudo, 自动 build + cli
# install-system    —— 系统全局, 需 sudo; 不自动 build, 避免 root 身份跑 build 污染 .build/Vendor
# uninstall         —— 对称卸载用户级
# uninstall-system  —— 对称卸载系统级, 需 sudo

# 用户级安装: 默认路径, 不需要 sudo
install: build cli
	@mkdir -p "$(USER_APP_DIR)" "$(USER_BIN_DIR)"
	@rm -rf "$(USER_APP_DIR)/$(APP_NAME)"
	@ditto "$(APP_SRC)" "$(USER_APP_DIR)/$(APP_NAME)"
	@echo "==> $(USER_APP_DIR)/$(APP_NAME)"
	@rm -f "$(USER_BIN_DIR)/$(CLI_NAME)"
	@ditto "$(CLI_SRC)" "$(USER_BIN_DIR)/$(CLI_NAME)"
	@echo "==> $(USER_BIN_DIR)/$(CLI_NAME)"
	@# 若 USER_BIN_DIR 不在 PATH 里, 提示用户加一行
	@case ":$$PATH:" in \
	  *":$(USER_BIN_DIR):"*) ;; \
	  *) echo ""; \
	     echo "提示: $(USER_BIN_DIR) 不在 PATH 里, hellvm 不能直接调用."; \
	     echo "      把下面一行加到 ~/.zshrc 或 ~/.bashrc 后 source:"; \
	     echo "        export PATH=\"$(USER_BIN_DIR):\$$PATH\"" ;; \
	esac

# 系统级安装: 全局可见, 需 sudo
# 不依赖 build/cli —— sudo 下跑 swift build 会让 .build/Vendor 变成 root-owned, 污染仓库.
# 要求用户先以普通身份跑 'make build cli', 再 sudo make install-system.
install-system:
	@if [ "$$(id -u)" != "0" ]; then \
	  echo "!! install-system 需 root 权限, 请用 'sudo make install-system'"; \
	  exit 1; \
	fi
	@test -d "$(APP_SRC)" || { echo "!! 未找到 $(APP_SRC), 请先以普通用户跑 'make build'"; exit 1; }
	@test -x "$(CLI_SRC)" || { echo "!! 未找到 $(CLI_SRC), 请先以普通用户跑 'make cli'"; exit 1; }
	@mkdir -p "$(SYSTEM_APP_DIR)" "$(SYSTEM_BIN_DIR)"
	@rm -rf "$(SYSTEM_APP_DIR)/$(APP_NAME)"
	@ditto "$(APP_SRC)" "$(SYSTEM_APP_DIR)/$(APP_NAME)"
	@echo "==> $(SYSTEM_APP_DIR)/$(APP_NAME)"
	@rm -f "$(SYSTEM_BIN_DIR)/$(CLI_NAME)"
	@ditto "$(CLI_SRC)" "$(SYSTEM_BIN_DIR)/$(CLI_NAME)"
	@echo "==> $(SYSTEM_BIN_DIR)/$(CLI_NAME)"

# 用户级卸载
uninstall:
	@rm -rf "$(USER_APP_DIR)/$(APP_NAME)"
	@rm -f  "$(USER_BIN_DIR)/$(CLI_NAME)"
	@echo "==> 已卸载 $(USER_APP_DIR)/$(APP_NAME)"
	@echo "==> 已卸载 $(USER_BIN_DIR)/$(CLI_NAME)"

# 系统级卸载, 需 sudo
uninstall-system:
	@if [ "$$(id -u)" != "0" ]; then \
	  echo "!! uninstall-system 需 root 权限, 请用 'sudo make uninstall-system'"; \
	  exit 1; \
	fi
	@rm -rf "$(SYSTEM_APP_DIR)/$(APP_NAME)"
	@rm -f  "$(SYSTEM_BIN_DIR)/$(CLI_NAME)"
	@echo "==> 已卸载 $(SYSTEM_APP_DIR)/$(APP_NAME)"
	@echo "==> 已卸载 $(SYSTEM_BIN_DIR)/$(CLI_NAME)"
