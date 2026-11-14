#!/bin/bash
#
# diagnose.sh —— 一键体检：权限、私有 API、置顶是否真的生效
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/dist/cclose-mac.app"
BIN="${APP}/Contents/MacOS/cclose-mac"

if [ -x "${BIN}" ]; then
  exec "${BIN}" --diagnose
elif [ -x "$(pwd)/.build/release/cclose-mac" ]; then
  exec "$(pwd)/.build/release/cclose-mac" --diagnose
else
  echo "❌ 还没编译。先运行 ./scripts/make_app.sh"
  exit 1
fi
