#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
cache_dir="$project_dir/.cache/native-migration"
qa_app=""
version=""
build_version=""

usage() {
  cat <<'USAGE'
Usage: native/scripts/build-local.sh [--qa-app PATH] [--version X.Y.Z] [--build X.Y.Z]

Package a native Dotist.app under .cache/native-migration without installing it.
Without --qa-app, build-qa.sh first builds a fresh isolated QA application.
The version defaults to native/app.json; the numeric build defaults to
that version. DotistBuildLabel records a separate native-local build timestamp.
This candidate uses ad hoc signing and the native signed GitHub update feed.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qa-app|--version|--build)
      if [[ $# -lt 2 || -z "$2" ]]; then usage >&2; exit 2; fi
      case "$1" in
        --qa-app) qa_app="$2" ;;
        --version) version="$2" ;;
        --build) build_version="$2" ;;
      esac
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -z "$version" ]]; then
  version="$(python3 -c 'import json; print(json.load(open("native/app.json"))["version"])')"
fi
build_version="${build_version:-$version}"
python3 - "$version" "$build_version" <<'PY'
import re, sys
for label, value in zip(("version", "build"), sys.argv[1:]):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise SystemExit(f"{label} must be a numeric X.Y.Z value")
PY

mkdir -p "$cache_dir"
if [[ -z "$qa_app" ]]; then
  build_log="$(mktemp "$cache_dir/local-build-XXXXXXXX.log")"
  bash native/scripts/build-qa.sh 2>&1 | tee "$build_log"
  qa_app="$(sed -n 's/^QA application: //p' "$build_log" | tail -n 1)"
fi

qa_app="$(python3 - "$qa_app" <<'PY'
import json, plistlib, sys
from pathlib import Path
app = Path(sys.argv[1]).resolve()
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
if info.get("CFBundleIdentifier") != "dev.codex.dotist-native-qa":
    raise SystemExit("Expected an isolated native QA bundle")
if info.get("LSMinimumSystemVersion") != json.loads(Path('native/app.json').read_text())['minimumMacOS']:
    raise SystemExit("QA minimum macOS does not match native/app.json; rebuild the QA application")
import hashlib
for row in Path('native/scripts/fonts.tsv').read_text().splitlines():
    name, checksum, *source = row.split()
    font = app / 'Contents/Resources/Fonts' / (name + '.ttf')
    license = app / 'Contents/Resources/Licenses' / (name + '-OFL.txt')
    if not font.is_file() or hashlib.sha256(font.read_bytes()).hexdigest() != checksum:
        raise SystemExit(f'Missing or invalid packaged font: {name}; rebuild the QA application')
    if not license.is_file() or (len(source) > 1 and hashlib.sha256(license.read_bytes()).hexdigest() != source[1]):
        raise SystemExit(f'Missing or invalid packaged font license: {name}; rebuild the QA application')
for relative in ("Contents/MacOS/dotist", "Contents/Resources/locales.json",
                 "Contents/Resources/native-locales.json", "Contents/Resources/icon.icns",
                 "Contents/Frameworks/Sparkle.framework"):
    if not (app / relative).exists():
        raise SystemExit(f"Missing QA bundle resource: {relative}")
print(app)
PY
)"
codesign --verify --deep --strict "$qa_app"

# An explicitly supplied QA app can predate the path-safe build flags. Refuse
# obvious home-directory paths without printing their contents. This is a
# narrow safeguard, not a comprehensive personal-data scan of the bundle.
python3 - "$qa_app/Contents/MacOS/dotist" "$project_dir" <<'PY'
import re, sys
from pathlib import Path
binary = Path(sys.argv[1]).read_bytes()
if re.search(rb'/(?:Users|home)/[^/\x00\r\n]+/', binary) or sys.argv[2].encode() in binary:
    raise SystemExit('QA executable contains a local build or home-directory path; rebuild it before packaging')
PY

candidate_dir="$(mktemp -d "$cache_dir/native-local-XXXXXXXX")"
app="$candidate_dir/Dotist.app"
ditto "$qa_app" "$app"
python3 - "$app" "$version" "$build_version" <<'PY'
import datetime, plistlib, sys
sys.path.insert(0, "native/scripts")
from importlib import import_module
update_config = import_module("update-config").update_config
from pathlib import Path
app = Path(sys.argv[1])
path = app / "Contents/Info.plist"
with path.open("rb") as source:
    info = plistlib.load(source)
# A QA app may have a signed localhost Sparkle feed. Never promote that feed.
info = {key: value for key, value in info.items() if not key.startswith(("SU", "DotistQA"))}
info.update({
    "CFBundleIdentifier": "com.dotist.app",
    "CFBundleName": "Dotist",
    "CFBundleDisplayName": "Dotist",
    "CFBundleExecutable": "dotist",
    "CFBundleIconFile": "icon.icns",
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundleVersion": sys.argv[3],
    "DotistBuildLabel": "native-local-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
})
info.update(update_config())
with path.open("wb") as output:
    plistlib.dump(info, output)
PY
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
printf 'Local application: %s\nVersion: %s (build %s)\n' "$app" "$version" "$build_version"
printf 'This candidate is not installed. Its normal launch uses the existing Dotist data directory.\n'
printf 'Validate with isolated DOTIST_DATA_DIR before installing. Native updates use the signed GitHub appcast.\n'
