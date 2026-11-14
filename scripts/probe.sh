#!/usr/bin/env bash
# 手势探针：定位「手势没反应」到底卡在哪一层
#   A. 权限 / 事件 tap 能不能建起来
#   B. 鼠标位置上的标题栏判定走到了哪一步
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$PWD/dist/cclose-mac.app/Contents/MacOS/cclose-mac"
if [ ! -x "$BIN" ]; then
  echo "没找到已打包的可执行文件：$BIN"
  echo "先运行 ./scripts/make_app.sh"
  exit 1
fi

# 跑探针前先把正在跑的实例停掉，避免两份 tap 互相干扰
pkill -f "cclose-mac.app/Contents/MacOS/cclose-mac" >/dev/null 2>&1 || true
sleep 0.3

exec "$BIN" --probe "$@"
