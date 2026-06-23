#!/usr/bin/env bash
# setup-github-runner.sh
# 在 Mac (ARM64) 上安装 GitHub Actions 自托管 Runner，注册到 qianliout/demo-app
#
# 用法: bash deploy/scripts/setup-github-runner.sh

set -euo pipefail

REPO="qianliout/demo-app"
RUNNER_DIR="$HOME/actions-runner"

# ---------- 检查 gh ----------
# 确保 gh 在 PATH 中
export PATH="/tmp/gh_extract/gh_2.95.0_macOS_arm64/bin:$PATH"
if ! command -v gh &>/dev/null; then
  echo "❌ gh 未安装"
  exit 1
fi
if ! gh auth status &>/dev/null; then
  echo "❌ gh 未登录"
  exit 1
fi

echo ">>> 获取 Runner 注册 token ..."
RUNNER_TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" --method POST -q .token)
if [ -z "$RUNNER_TOKEN" ]; then
  echo "❌ 获取 token 失败"
  exit 1
fi

echo ">>> 获取最新 Runner 版本 ..."
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
echo "   版本: v${RUNNER_VERSION}"

# ---------- 下载 Runner ----------
RUNNER_PKG="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PKG}"

if [ ! -d "$RUNNER_DIR" ]; then
  mkdir -p "$RUNNER_DIR"
fi

echo ">>> 下载 Runner 到 ${RUNNER_DIR} ..."
curl -fsSL -o /tmp/${RUNNER_PKG} "$RUNNER_URL"
tar xzf /tmp/${RUNNER_PKG} -C "$RUNNER_DIR"
rm -f /tmp/${RUNNER_PKG}
echo "   ✅ 下载完成"

# ---------- 配置 Runner ----------
cd "$RUNNER_DIR"

echo ">>> 配置 Runner（标签: mac-arm64,self-hosted）..."
./config.sh \
  --url "https://github.com/${REPO}" \
  --token "$RUNNER_TOKEN" \
  --name "mac-arm64-runner" \
  --labels "mac-arm64,self-hosted" \
  --work "_work" \
  --unattended \
  --replace

# ---------- 安装为后台服务 ----------
echo ">>> 安装 launchd 服务（开机自启）..."
./svc.sh install
./svc.sh start

echo ""
echo "✅ Runner 已安装并启动"
echo ""
echo "常用管理命令:"
echo "  cd ${RUNNER_DIR}"
echo "  ./svc.sh status     # 查看状态"
echo "  ./svc.sh stop       # 停止"
echo "  ./svc.sh start      # 启动"
echo ""
echo "现在去 GitHub Actions 页面，重新运行失败的 workflow"
