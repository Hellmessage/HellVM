# HellVM —— 所有构建产物输出到 build/
.PHONY: all build run cli test clean probe

CONFIG ?= release

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
