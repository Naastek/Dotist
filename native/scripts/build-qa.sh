#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
cache_dir="$project_dir/.cache/native-migration"
scratch_dir="$project_dir/.cache/native-consolidation/swift-build"
sdk_path="${DOTIST_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
profile="${DOTIST_NATIVE_PROFILE:-release}"
if [[ "$profile" != release && "$profile" != debug ]]; then echo 'DOTIST_NATIVE_PROFILE must be release or debug' >&2; exit 1; fi
minimum="$(python3 -c 'import json; print(json.load(open("native/app.json"))["minimumMacOS"])')"
mkdir -p "$cache_dir/fonts" "$scratch_dir" "$project_dir/.cache/native-consolidation/clang" "$project_dir/.cache/native-consolidation/swift-modules"
export CLANG_MODULE_CACHE_PATH="$project_dir/.cache/native-consolidation/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.cache/native-consolidation/swift-modules"
font_version=6c1dbe27dcf7d817d4b62cec033ba77fa8e2a5ec
while read -r name checksum path license_checksum license_url; do
  file="$cache_dir/fonts/$name.ttf"
  if [[ "$path" == https://* ]]; then
    font_url="$path"
  else
    font_url="https://raw.githubusercontent.com/google/fonts/$font_version/ofl/$path"
    license_url="https://raw.githubusercontent.com/google/fonts/$font_version/ofl/${path%%/*}/OFL.txt"
  fi
  if [[ ! -f "$file" ]]; then curl --fail --location --silent --show-error "$font_url" --output "$file"; fi
  printf '%s  %s\n' "$checksum" "$file" | shasum -a 256 -c - >/dev/null
  license="$cache_dir/fonts/$name-OFL.txt"
  if [[ ! -f "$license" ]]; then curl --fail --location --silent --show-error "$license_url" --output "$license"; fi
  if [[ -n "$license_checksum" ]]; then printf '%s  %s\n' "$license_checksum" "$license" | shasum -a 256 -c - >/dev/null; fi
done < native/scripts/fonts.tsv
sparkle_framework="$(bash native/scripts/prepare-sparkle.sh)"
export DOTIST_SPARKLE_XCFRAMEWORK='../.cache/native-migration/deps/Sparkle-2.9.6/Sparkle.xcframework'
swift build --disable-sandbox --build-system native --triple "arm64-apple-macosx$minimum" --sdk "$sdk_path" --configuration "$profile" --package-path native --scratch-path "$scratch_dir" --disable-automatic-resolution
product="$scratch_dir/arm64-apple-macosx/$profile"
qa_dir="$(mktemp -d "$cache_dir/qa-build-XXXXXXXX")"
app="$qa_dir/Dotist-Native-QA.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts" "$app/Contents/Resources/Licenses" "$app/Contents/Frameworks" "$qa_dir/data"
ditto "$sparkle_framework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$cache_dir/deps/Sparkle-2.9.6/LICENSE" "$app/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
cp "$product/DotistNative" "$app/Contents/MacOS/dotist"
cp native/Sources/DotistApp/Resources/*.json "$app/Contents/Resources/"
cp native/Assets/menubar.png "$app/Contents/Resources/menubar.png"
cp native/Assets/icon.icns "$app/Contents/Resources/icon.icns"
while read -r name checksum path license_checksum license_url; do
  cp "$cache_dir/fonts/$name.ttf" "$app/Contents/Resources/Fonts/"
  cp "$cache_dir/fonts/$name-OFL.txt" "$app/Contents/Resources/Licenses/"
done < native/scripts/fonts.tsv
for dependency in "$scratch_dir"/checkouts/*; do
  for license in "$dependency"/LICENSE "$dependency"/LICENSE.txt "$dependency"/LICENSE.md "$dependency"/NOTICE "$dependency"/NOTICE.txt; do
    if [[ -f "$license" ]]; then cp "$license" "$app/Contents/Resources/Licenses/$(basename "$dependency")-$(basename "$license")"; fi
  done
done
python3 - "$app" "$qa_dir" <<'PY'
import json, plistlib, sys
from pathlib import Path
app, qa = map(Path, sys.argv[1:])
config = json.loads(Path('native/app.json').read_text())
info = {'CFBundleExecutable':'dotist','CFBundleIdentifier':'dev.codex.dotist-native-qa','CFBundleName':'Dotist Native QA','CFBundlePackageType':'APPL','CFBundleIconFile':'icon','CFBundleShortVersionString':config['version'],'CFBundleVersion':'1','LSMinimumSystemVersion':config['minimumMacOS'],'NSHighResolutionCapable':True,'DotistNative':True}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
settings = {'theme':'light','language':'zh-CN','show_menubar':False,'toggle_shortcut':'','quick_add_shortcut':'','settings_shortcut':'','views_shortcut':'','auto_check_updates':False,'auto_install_updates':False,'auto_collapse':False,'idle_fade':False,'mcp_enabled':True}
(qa/'data/settings.json').write_text(json.dumps(settings, ensure_ascii=False, indent=2))
PY
xcrun swift-stdlib-tool --copy --scan-executable "$app/Contents/MacOS/dotist" --platform macosx --destination "$app/Contents/Frameworks"
codesign --force --deep --sign - "$app"
printf 'QA application: %s\nQA data: %s\n' "$app" "$qa_dir/data"
printf 'Run: open -n --env DOTIST_DATA_DIR=%q %q\n' "$qa_dir/data" "$app"
