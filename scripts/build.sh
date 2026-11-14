#!/bin/bash
#
# build.sh —— 编译 cclose-mac
# 用法: ./scripts/build.sh            （release，默认）
#       ./scripts/build.sh debug      （debug，调试用）
#
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-release}"

echo "==> 检查工具链"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "❌ 未找到 Command Line Tools，请先执行： xcode-select --install"
  exit 1
fi
swift --version

echo ""
echo "==> swift build -c ${MODE}"
swift build -c "${MODE}"

BIN="$(pwd)/.build/${MODE}/cclose-mac"
echo ""
echo "✅ 编译完成: ${BIN}"
echo "   直接试跑（前台输出诊断）: ${BIN} --diagnose"
echo "   打包成 .app（推荐）      : ./scripts/make_app.sh"
