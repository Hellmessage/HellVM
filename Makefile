# HellVM —— 所有构建产物输出到 build/
.PHONY: all build run cli test clean

CONFIG ?= release

all: build

# 构建主 App(.app bundle + ad-hoc 签名)
build:
	@bash scripts/bundle.sh

# 构建 CLI
cli:
	@swift build -c $(CONFIG) --product hellvm
	@mkdir -p build
	@cp "$$(swift build -c $(CONFIG) --show-bin-path)/hellvm" build/hellvm
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
