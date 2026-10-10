#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon_source="$project_root/Assets/AppIcon/AppIcon.png"
icon_output="$project_root/Assets/AppIcon/AppIcon.icns"

[ "$#" -eq 0 ] || { printf 'Usage: %s\n' "$0" >&2; exit 2; }
[ -f "$icon_source" ] || { printf 'Missing icon source: %s\n' "$icon_source" >&2; exit 1; }
image_info="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha "$icon_source")"
for field in pixelWidth pixelHeight; do
    value="$(printf '%s\n' "$image_info" | awk -v key="$field:" '$1 == key { print $2 }')"
    [ "$value" = 1024 ] || { printf 'AppIcon.png must be 1024 x 1024 pixels.\n' >&2; exit 1; }
done
printf '%s\n' "$image_info" | awk '$1 == "hasAlpha:" && $2 == "yes" { found = 1 } END { exit !found }' \
    || { printf 'AppIcon.png must preserve its transparent alpha channel.\n' >&2; exit 1; }

mkdir -p "$project_root/.tmp/app-icon-generation"
stage_dir="$(mktemp -d "$project_root/.tmp/app-icon-generation/run.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
iconset="$stage_dir/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    /usr/bin/sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$stage_dir/AppIcon.icns"
[ -s "$stage_dir/AppIcon.icns" ] || { printf 'Icon generation failed.\n' >&2; exit 1; }
mv "$stage_dir/AppIcon.icns" "$icon_output"
printf 'Generated %s\n' "$icon_output"
