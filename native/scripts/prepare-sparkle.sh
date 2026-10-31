#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cache_dir="$project_dir/.cache/native-migration/deps"
archive="$cache_dir/Sparkle-2.9.6.zip"
framework="$cache_dir/Sparkle-2.9.6/Sparkle.xcframework"
mkdir -p "$cache_dir"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --silent --show-error \
    'https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip' \
    --output "$archive"
fi
printf '%s  %s\n' '8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606' "$archive" | shasum -a 256 -c - >/dev/null
if [[ ! -d "$framework" ]]; then
  unpack="$(mktemp -d "$cache_dir/sparkle-unpack-XXXXXXXX")"
  ditto -x -k "$archive" "$unpack"
  test -d "$unpack/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  mv "$unpack" "$cache_dir/Sparkle-2.9.6"
fi
printf '%s\n' "$framework"
