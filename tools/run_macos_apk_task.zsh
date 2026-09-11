#!/bin/zsh
# Dispatches macOS APK tasks through the repository-pinned Apple Silicon Node
# toolchain. Intel macOS intentionally fails instead of falling back to Node
# from PATH, because that would invalidate the Runtime's reproducible build.
set -eu

if [[ $# -ne 1 ]]; then
  print -u2 'Usage: run_macos_apk_task.zsh <prepare-runtime|collect-apk>'
  exit 64
fi

if [[ "$(uname -m)" != 'arm64' ]]; then
  print -u2 '当前仓库仅提供 macOS Apple Silicon 的固定 Node Runtime，无法在 Intel Mac 上打包 APK。'
  exit 1
fi

script_root=${0:A:h}
workspace_root=${script_root:h}
runtime_root="$workspace_root/packages/mg_read_node_runtime"
node_root="$runtime_root/tools/node-v24.16.0-darwin-arm64"
node="$node_root/bin/node"
npm_cli="$node_root/lib/node_modules/npm/bin/npm-cli.js"

export PATH="$node_root/bin:$PATH"

case "$1" in
  prepare-runtime)
    cd "$runtime_root"
    exec "$node" "$npm_cli" run build
    ;;
  collect-apk)
    exec "$node" "$workspace_root/tools/collect_release_apk.mjs"
    ;;
  *)
    print -u2 "未知 macOS APK 任务：$1"
    exit 64
    ;;
esac
