#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'Usage: native/scripts/test-updater.sh <isolated QA.app> [existing signing-key directory]' >&2
  exit 2
fi
if [[ -x "$project_dir/.toolchain/cargo/bin/cargo" ]]; then
  export RUSTUP_HOME="$project_dir/.toolchain/rustup" CARGO_HOME="$project_dir/.toolchain/cargo"
  export PATH="$project_dir/.toolchain/cargo/bin:$PATH"
fi
run_dir="$(mktemp -d "$project_dir/.cache/native-migration/update-tests-XXXXXXXX")"
mkdir -p "$run_dir/update-server/www"
python3 -u native/UITests/update-fixture-server.py "$run_dir/update-server" > "$run_dir/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  echo "Update test results retained: $run_dir"
}
trap cleanup EXIT
for attempt in {1..100}; do
  [[ -f "$run_dir/update-server/port.txt" ]] && break
  kill -0 "$server_pid"
  sleep 0.1
done
xcodebuild build-for-testing -project native/UITests/DotistUI.xcodeproj -scheme DotistUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$run_dir/DerivedData" CODE_SIGNING_ALLOWED=NO > "$run_dir/build.log" 2>&1
codesign --force --deep --sign - "$run_dir/DerivedData/Build/Products/Debug/DotistUITests-Runner.app"
CARGO_TARGET_DIR="$project_dir/.cache/native-migration/release-tools-target" cargo build --locked --release --manifest-path native/release-tools/Cargo.toml
python3 native/UITests/prepare-update-fixtures.py "$1" "$run_dir" "${@:2}" > "$run_dir/fixtures.log" 2>&1
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
