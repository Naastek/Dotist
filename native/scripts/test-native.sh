#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
mkdir -p .cache/native-consolidation/clang .cache/native-consolidation/swift-modules
export CLANG_MODULE_CACHE_PATH="$project_dir/.cache/native-consolidation/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.cache/native-consolidation/swift-modules"
bash native/scripts/prepare-sparkle.sh >/dev/null
export DOTIST_SPARKLE_XCFRAMEWORK='../.cache/native-migration/deps/Sparkle-2.9.6/Sparkle.xcframework'
swift test --disable-sandbox --build-system native --package-path native --scratch-path "$project_dir/.cache/native-consolidation/swift-build" "$@"
