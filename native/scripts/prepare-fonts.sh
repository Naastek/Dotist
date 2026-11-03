#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
font_dir="${1:-$project_dir/.cache/native-migration/fonts}"
font_version=6c1dbe27dcf7d817d4b62cec033ba77fa8e2a5ec
mkdir -p "$font_dir"
staging="$(mktemp -d "$font_dir/.prepare-XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT

verify() {
  local file="$1" checksum="$2"
  if [[ -n "$checksum" ]]; then
    printf '%s  %s\n' "$checksum" "$file" | shasum -a 256 -c - >/dev/null
  fi
}

prepare() {
  local name="$1" checksum="$2" url="$3"
  if [[ -e "$font_dir/$name" ]]; then
    verify "$font_dir/$name" "$checksum"
  else
    curl --fail --location --silent --show-error "$url" --output "$staging/$name"
    verify "$staging/$name" "$checksum"
  fi
}

# Validate cached files and stage every missing font/license before publishing
# any download. Failed transfers or checksums never leave a final cache target.
while read -r name checksum path license_checksum license_url; do
  if [[ "$path" == https://* ]]; then
    font_url="$path"
  else
    font_url="https://raw.githubusercontent.com/google/fonts/$font_version/ofl/$path"
    license_url="https://raw.githubusercontent.com/google/fonts/$font_version/ofl/${path%%/*}/OFL.txt"
  fi
  prepare "$name.ttf" "$checksum" "$font_url"
  prepare "$name-OFL.txt" "$license_checksum" "$license_url"
done < "$project_dir/native/scripts/fonts.tsv"

publish() {
  local name="$1" checksum="$2"
  # Recheck before publication: never replace an existing target, including one
  # supplied by another preparation while this invocation was downloading.
  if [[ -e "$font_dir/$name" ]]; then
    verify "$font_dir/$name" "$checksum"
  else
    mv -n "$staging/$name" "$font_dir/$name"
    verify "$font_dir/$name" "$checksum"
  fi
}
while read -r name checksum path license_checksum license_url; do
  publish "$name.ttf" "$checksum"
  publish "$name-OFL.txt" "$license_checksum"
done < "$project_dir/native/scripts/fonts.tsv"
printf '%s\n' "$font_dir"
