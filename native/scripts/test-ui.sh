#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
if [[ $# != 1 ]]; then
  echo 'Usage: native/scripts/test-ui.sh <fresh QA build directory>' >&2
  exit 2
fi
qa_dir="$(python3 - "$project_dir" "$1" <<'PY'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
qa = Path(sys.argv[2]).resolve(strict=True)
cache = (root / '.cache/native-migration').resolve()
if qa.parent != cache or not qa.name.startswith('qa-build-'):
    raise SystemExit('The UI test requires a fresh qa-build-* directory in .cache/native-migration')
app, data = qa / 'Dotist-Native-QA.app', qa / 'data'
if app.is_symlink() or data.is_symlink() or not data.is_dir() or (data / 'tasks.sqlite').exists():
    raise SystemExit('The QA application and data must be isolated, and the test database must not exist yet')
with (app / 'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
if info.get('CFBundleIdentifier') != 'dev.codex.dotist-native-qa':
    raise SystemExit('The application is not a Dotist QA bundle')
print(qa)
PY
)"
run_dir="$(mktemp -d "$project_dir/.cache/native-migration/ui-tests-XXXXXXXX")"
derived="$run_dir/DerivedData"
xcodebuild build-for-testing -project native/UITests/DotistUI.xcodeproj -scheme DotistUI \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO > "$run_dir/build.log" 2>&1 || { tail -n 80 "$run_dir/build.log"; exit 1; }
codesign --force --deep --sign - "$derived/Build/Products/Debug/DotistUITests-Runner.app"
xctestrun="$(python3 - "$derived/Build/Products" "$qa_dir" <<'PY'
import plistlib, sys
from pathlib import Path
products, qa = map(Path, sys.argv[1:])
files = list(products.glob('*.xctestrun'))
if len(files) != 1: raise SystemExit('Expected one generated xctestrun file')
with files[0].open('rb') as f: run = plistlib.load(f)
test = run['DotistUITests']
test['UITargetAppPath'] = str(qa / 'Dotist-Native-QA.app')
test.setdefault('UITargetAppEnvironmentVariables', {})['DOTIST_DATA_DIR'] = str(qa / 'data')
test.setdefault('EnvironmentVariables', {})['DOTIST_UI_DATA'] = str(qa / 'data')
path = products / 'Dotist-isolated.xctestrun'
with path.open('wb') as f: plistlib.dump(run, f)
print(path)
PY
)"
xcodebuild test-without-building -xctestrun "$xctestrun" -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$run_dir/results.xcresult" > "$run_dir/test.log" 2>&1 || { tail -n 100 "$run_dir/test.log"; exit 1; }
tail -n 25 "$run_dir/test.log"
printf 'UI test results: %s\nQA sample data: %s\n' "$run_dir/results.xcresult" "$qa_dir/data"
