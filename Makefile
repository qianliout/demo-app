APP_NAME    := demo-app
CMD_DIR     := cmd
OUTPUT_DIR  := bin
GO          := go

# 避免继承 shell 环境中的 CGO_ENABLED=1，导致在 macOS 上误触发 Linux cgo 交叉编译失败。
CGO_ENABLED := 0
GOOS        := linux
GOARCH      := arm64

OUTPUT := $(OUTPUT_DIR)/$(APP_NAME)

.PHONY: all build clean run help

all: build

## build: 编译 Go 二进制文件 (linux/arm64)
build:
	@mkdir -p $(OUTPUT_DIR)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) \
		$(GO) build -v -o $(OUTPUT) ./$(CMD_DIR)/
	@echo "✅ Build done: $(OUTPUT) ($(GOOS)/$(GOARCH))"

## build-amd64: 交叉编译为 amd64
build-amd64:
	$(MAKE) build GOARCH=amd64

## build-local: 在 Mac 本地编译（用于测试）
build-local:
	@mkdir -p $(OUTPUT_DIR)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=darwin GOARCH=arm64 \
		$(GO) build -v -o $(OUTPUT_DIR)/$(APP_NAME)-local ./$(CMD_DIR)/

## run: 本地编译并启动
run: build-local
	PORT=8080 ./$(OUTPUT_DIR)/$(APP_NAME)-local

## clean: 清理
clean:
	rm -rf $(OUTPUT_DIR)
