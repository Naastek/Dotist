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
if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
  printf '%s\n' 'Rust 未安装：请提供项目本地 Rust 工具链，或使用已有的 cargo 和 rustc。' >&2
  exit 1
fi
if [ "$#" -gt 1 ]; then
  printf '用法：%s [target-triple]\n' "$0" >&2
  exit 1
fi
target=${1:-$(rustc -vV | sed -n 's/^host: //p')}
if [ -z "$target" ]; then
  printf '%s\n' '无法确定 Rust host target triple。' >&2
  exit 1
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$project_root/.cache/tauri-target}"
cargo build --release --target "$target" --manifest-path crates/dotist-core/Cargo.toml --bin dotist-mcp
mkdir -p src-tauri/binaries
cp "$CARGO_TARGET_DIR/$target/release/dotist-mcp" "src-tauri/binaries/dotist-mcp-$target"
printf 'Sidecar：%s\n' "$project_root/src-tauri/binaries/dotist-mcp-$target"
