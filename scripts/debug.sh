#!/usr/bin/env bash
# 带日志启动：每个输入事件的处理结论直接打印在终端里
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$PWD/dist/cclose-mac.app/Contents/MacOS/cclose-mac"
if [ ! -x "$BIN" ]; then
  echo "没找到已打包的可执行文件：$BIN"
  echo "先运行 ./scripts/make_app.sh"
  exit 1
fi

pkill -f "cclose-mac.app/Contents/MacOS/cclose-mac" >/dev/null 2>&1 || true
sleep 0.3

echo "日志实时打印在下面。把鼠标放到标题栏上，按住左键 3 秒看输出；Ctrl+C 退出。"
echo

exec "$BIN" --debug
