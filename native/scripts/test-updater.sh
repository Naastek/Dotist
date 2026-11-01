#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
if [[ $# != 1 ]]; then
  echo 'Usage: native/scripts/test-updater.sh <isolated QA.app>' >&2
  exit 2
fi
run_dir="$(mktemp -d "$project_dir/.cache/native-migration/update-tests-XXXXXXXX")"
mkdir -p "$run_dir/update-server/www"
python3 -u native/UITests/update-fixture-server.py "$run_dir/update-server" > "$run_dir/server.log" 2>&1 &
server_pid=$!
printf '%s\n' "$server_pid" > "$run_dir/server.pid"
cleanup() {
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  rm -f "$run_dir/test-signing.key"
  echo "Update test results retained: $run_dir"
}
trap cleanup EXIT
for attempt in {1..100}; do
  [[ -f "$run_dir/update-server/port.txt" ]] && break
  kill -0 "$server_pid"
  sleep 0.1
done
if [[ ! -s "$run_dir/update-server/port.txt" ]]; then
  cat "$run_dir/server.log" >&2
  echo 'The isolated update server did not become ready.' >&2
  exit 1
fi
xcodebuild build-for-testing -project native/UITests/DotistUI.xcodeproj -scheme DotistUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$run_dir/DerivedData" CODE_SIGNING_ALLOWED=NO > "$run_dir/build.log" 2>&1
codesign --force --deep --sign - "$run_dir/DerivedData/Build/Products/Debug/DotistUITests-Runner.app"
swift native/UITests/create-update-test-key.swift "$run_dir/test-signing.key" "$run_dir/test-signing-public.txt"
python3 native/UITests/prepare-update-fixtures.py "$1" "$run_dir" > "$run_dir/fixtures.log" 2>&1
rm "$run_dir/test-signing.key"
for name in check manual tampered automatic cancel skip; do
  case "$name" in
    check) method=testSignedUpdaterCheck ;;
    manual) method=testInstallSignedUpdate ;;
    tampered) method=testRejectTamperedUpdate ;;
    automatic) method=testAutomaticUpdateOnQuit ;;
    cancel) method=testDisableStagedAutomaticUpdate ;;
    skip) method=testSkipStagedUpdatePersistsAndAllowsManualCheck ;;
  esac
  xcodebuild test-without-building -xctestrun "$run_dir/update-$name/run.xctestrun" \
    -destination 'platform=macOS,arch=arm64' -only-testing:"DotistUITests/DotistUITests/$method" \
    -resultBundlePath "$run_dir/update-$name/results.xcresult" > "$run_dir/update-$name/test.log" 2>&1
done
