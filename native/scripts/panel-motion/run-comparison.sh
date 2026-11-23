#!/bin/bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo '用法为 run-comparison.sh 对照包.app 候选包.app 新输出目录 每批轮数 刷新率' >&2
  exit 2
fi

baseline="$1"
candidate="$2"
output="$3"
rounds="$4"
hz="$5"
script_dir="$(cd "$(dirname "$0")" && pwd)"

for bundle in "$baseline" "$candidate"; do
  codesign --verify --deep --strict "$bundle"
done
mkdir -m 700 "$output"
shasum -a 256 "$baseline/Contents/MacOS/dotist" "$candidate/Contents/MacOS/dotist" > "$output/builds.sha256"
xcrun swiftc -parse-as-library -O "$script_dir/Capture.swift" -o "$output/capture"
for batch in 1 2; do
  "$output/capture" "$baseline" "$output/a$batch" "$rounds" --mouse
  "$output/capture" "$candidate" "$output/b$batch" "$rounds" --mouse
done
python3 "$script_dir/compare.py" --hz "$hz" --check "$output"/{a1,b1,a2,b2}
