#!/usr/bin/env bash
# setup-github-secrets.sh
# 将 Docker Hub 凭据和 kubeconfig 写入 GitHub Actions Secrets
#
# 需要的环境变量:
#   DOCKERHUB_USERNAME  Docker Hub 用户名
#   DOCKERHUB_TOKEN     Docker Hub Access Token
#   KUBE_CONFIG         kubectl config view --raw | base64 的输出
#
# 用法:
#   export DOCKERHUB_USERNAME=xxx
#   export DOCKERHUB_TOKEN=yyy
#   export KUBE_CONFIG=$(kubectl config view --raw | base64)
#   bash deploy/scripts/setup-github-secrets.sh

set -euo pipefail

REPO="qianliout/demo-app"

# ---------- 检查 gh ----------
if ! command -v gh &>/dev/null; then
  echo "❌ gh 未安装，先执行: brew install gh && gh auth login"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "❌ gh 未登录，先执行: gh auth login"
  exit 1
fi

# ---------- 检查环境变量 ----------
missing=()
for var in DOCKERHUB_USERNAME DOCKERHUB_TOKEN KUBE_CONFIG; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ 以下环境变量未设置: ${missing[*]}"
  echo ""
  echo "设置方法:"
  echo "  export DOCKERHUB_USERNAME=你的DockerHub用户名"
  echo "  export DOCKERHUB_TOKEN=你的DockerHubAccessToken"
  echo "  export KUBE_CONFIG=\$(kubectl config view --raw | base64)"
  exit 1
fi

# ---------- 写入 Secrets ----------
echo ">>> 写入 GitHub Secrets 到仓库 $REPO ..."

gh secret set DOCKERHUB_USERNAME -b"${DOCKERHUB_USERNAME}" -R "$REPO"
echo "  ✅ DOCKERHUB_USERNAME"

gh secret set DOCKERHUB_TOKEN -b"${DOCKERHUB_TOKEN}" -R "$REPO"
echo "  ✅ DOCKERHUB_TOKEN"

gh secret set KUBE_CONFIG -b"${KUBE_CONFIG}" -R "$REPO"
echo "  ✅ KUBE_CONFIG"

# ---------- 验证 ----------
echo ""
echo ">>> 当前仓库 Secrets 列表:"
gh secret list -R "$REPO"
