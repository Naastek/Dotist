#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
cache_dir="$project_dir/.cache/native-migration"
sdk_path="${DOTIST_MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p "$cache_dir/clang-module-cache" "$cache_dir/swift-module-cache"
export MACOSX_DEPLOYMENT_TARGET=11.0
export CARGO_TARGET_DIR="$cache_dir/rust-target"
export CLANG_MODULE_CACHE_PATH="$cache_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/swift-module-cache"
if [[ -x "$project_dir/.toolchain/cargo/bin/cargo" ]]; then
  export RUSTUP_HOME="$project_dir/.toolchain/rustup" CARGO_HOME="$project_dir/.toolchain/cargo"
  export PATH="$project_dir/.toolchain/cargo/bin:$PATH"
fi
cargo_flags=(--locked)
if [[ "${DOTIST_CARGO_OFFLINE:-1}" == 1 ]]; then cargo_flags+=(--offline); fi
cargo build "${cargo_flags[@]}" --manifest-path crates/dotist-core/Cargo.toml --bin dotist-mcp
cargo build "${cargo_flags[@]}" --manifest-path crates/dotist-native/Cargo.toml --lib
export DOTIST_MCP_BINARY="$CARGO_TARGET_DIR/debug/dotist-mcp"
cargo test "${cargo_flags[@]}" --manifest-path crates/dotist-native/Cargo.toml --test bridge
export DOTIST_RUST_LIB_DIR="$CARGO_TARGET_DIR/debug"
bash native/scripts/prepare-sparkle.sh >/dev/null
export DOTIST_SPARKLE_XCFRAMEWORK='../.cache/native-migration/deps/Sparkle-2.9.6/Sparkle.xcframework'
swift test --build-system native --triple arm64-apple-macosx11.0 --sdk "$sdk_path" -Xswiftc -target -Xswiftc arm64-apple-macosx11.0 --package-path native --scratch-path "$cache_dir/swift-test"
