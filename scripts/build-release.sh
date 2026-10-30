#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
if [ -x "$project_root/.toolchain/cargo/bin/cargo" ]; then
  export RUSTUP_HOME="$project_root/.toolchain/rustup"
  export CARGO_HOME="$project_root/.toolchain/cargo"
  PATH="$CARGO_HOME/bin:$PATH"
  export PATH
fi
if ! command -v cargo >/dev/null 2>&1; then
  printf '%s\n' 'Rust 未安装：请提供项目本地 Rust 工具链，或使用已有的 cargo。' >&2
  exit 1
fi
if [ ! -d node_modules ]; then
  printf '%s\n' '请先在项目目录运行 npm ci 安装依赖。' >&2
  exit 1
fi
export CARGO_TARGET_DIR="$project_root/.cache/tauri-target"
./scripts/prepare-sidecar.sh
npm run tauri -- build --bundles app
bundle="$CARGO_TARGET_DIR/release/bundle/macos/Dotist.app"
codesign --force --deep --sign - "$bundle"
printf '可运行的应用：%s\n' "$bundle"
