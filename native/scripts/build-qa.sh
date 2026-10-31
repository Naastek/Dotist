#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
cache_dir="$project_dir/.cache/native-migration"
sdk_path="${DOTIST_MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
profile="${DOTIST_NATIVE_PROFILE:-release}"
if [[ "$profile" != release && "$profile" != debug ]]; then echo 'DOTIST_NATIVE_PROFILE must be release or debug' >&2; exit 1; fi
if [[ ! -d "$sdk_path" ]]; then echo "SDK not found: $sdk_path" >&2; exit 1; fi
mkdir -p "$cache_dir/fonts" "$cache_dir/clang-module-cache" "$cache_dir/swift-module-cache"
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
if [[ "$profile" == release ]]; then cargo_flags+=(--release); fi
cargo build "${cargo_flags[@]}" --manifest-path crates/dotist-core/Cargo.toml --bin dotist-mcp
cargo build "${cargo_flags[@]}" --manifest-path crates/dotist-native/Cargo.toml --lib
font_version=6c1dbe27dcf7d817d4b62cec033ba77fa8e2a5ec
while read -r name checksum path; do
  file="$cache_dir/fonts/$name.ttf"
  if [[ ! -f "$file" ]]; then curl --fail --location --silent --show-error "https://raw.githubusercontent.com/google/fonts/$font_version/ofl/$path" --output "$file"; fi
  printf '%s  %s\n' "$checksum" "$file" | shasum -a 256 -c - >/dev/null
  license="$cache_dir/fonts/$name-OFL.txt"
  if [[ ! -f "$license" ]]; then curl --fail --location --silent --show-error "https://raw.githubusercontent.com/google/fonts/$font_version/ofl/${path%%/*}/OFL.txt" --output "$license"; fi
done < native/scripts/fonts.tsv
node --input-type=module -e 'import { dictionaries } from "./src/locales.ts"; import { writeFileSync } from "node:fs"; writeFileSync("native/Sources/DotistApp/Resources/locales.json", JSON.stringify(dictionaries));'
export DOTIST_RUST_LIB_DIR="$CARGO_TARGET_DIR/$profile"
sparkle_framework="$(bash native/scripts/prepare-sparkle.sh)"
export DOTIST_SPARKLE_XCFRAMEWORK='../.cache/native-migration/deps/Sparkle-2.9.6/Sparkle.xcframework'
swift build --build-system native --triple arm64-apple-macosx11.0 --sdk "$sdk_path" -Xswiftc -target -Xswiftc arm64-apple-macosx11.0 --configuration "$profile" --package-path native --scratch-path "$cache_dir/swift-qa-$profile"
product="$cache_dir/swift-qa-$profile/arm64-apple-macosx/$profile"
qa_dir="$(mktemp -d "$cache_dir/qa-build-XXXXXXXX")"
app="$qa_dir/Dotist-Native-QA.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts" "$app/Contents/Resources/Licenses" "$app/Contents/Frameworks" "$qa_dir/data"
ditto "$sparkle_framework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$cache_dir/deps/Sparkle-2.9.6/LICENSE" "$app/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
cp "$product/DotistNative" "$app/Contents/MacOS/dotist"
cp "$CARGO_TARGET_DIR/$profile/dotist-mcp" "$app/Contents/MacOS/dotist-mcp-real"
cat > "$app/Contents/MacOS/dotist-mcp" <<'WRAPPER'
#!/bin/sh
set -eu
binary_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
qa_dir=$(CDPATH= cd -- "$binary_dir/../../.." && pwd)
if [ "${DOTIST_DATA_DIR:-}" != "$qa_dir/data" ]; then
  echo "QA MCP requires DOTIST_DATA_DIR=$qa_dir/data" >&2
  exit 1
fi
exec "$binary_dir/dotist-mcp-real"
WRAPPER
chmod +x "$app/Contents/MacOS/dotist-mcp"
cp native/Sources/DotistApp/Resources/locales.json "$app/Contents/Resources/locales.json"
cp native/Sources/DotistApp/Resources/native-locales.json "$app/Contents/Resources/native-locales.json"
cp src-tauri/icons/tray/menubar@2x.png "$app/Contents/Resources/menubar.png"
cp src-tauri/icons/icon.icns "$app/Contents/Resources/icon.icns"
for font in "$cache_dir"/fonts/*.ttf; do cp "$font" "$app/Contents/Resources/Fonts/"; done
for license in "$cache_dir"/fonts/*-OFL.txt; do cp "$license" "$app/Contents/Resources/Licenses/"; done
python3 - "$app" "$qa_dir" <<'PY'
import json, plistlib, sys
from pathlib import Path
app, qa = map(Path, sys.argv[1:])
info = {'CFBundleExecutable':'dotist','CFBundleIdentifier':'dev.codex.dotist-native-qa','CFBundleName':'Dotist Native QA','CFBundlePackageType':'APPL','CFBundleIconFile':'icon','CFBundleShortVersionString':'0.1.2','CFBundleVersion':'1','LSMinimumSystemVersion':'11.0','NSHighResolutionCapable':True}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
settings = {'theme':'light','language':'zh-CN','show_menubar':False,'toggle_shortcut':'','quick_add_shortcut':'','settings_shortcut':'','views_shortcut':'','auto_check_updates':False,'auto_install_updates':False,'auto_collapse':False,'idle_fade':False}
(qa/'data/settings.json').write_text(json.dumps(settings, ensure_ascii=False, indent=2))
PY
xcrun swift-stdlib-tool --copy --scan-executable "$app/Contents/MacOS/dotist" --platform macosx --destination "$app/Contents/Frameworks"
codesign --force --deep --sign - "$app"
printf 'QA application: %s\nQA data: %s\n' "$app" "$qa_dir/data"
printf 'Run: open -n --env DOTIST_DATA_DIR=%q %q\n' "$qa_dir/data" "$app"
