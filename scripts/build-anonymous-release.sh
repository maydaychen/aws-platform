#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="0.4.3"
build_number="28"
output_dir=""

usage() {
    printf 'Usage: %s [--version VERSION] [--build-number NUMBER] [--output-dir DIRECTORY]\n' "$0"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --version|--build-number|--output-dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
            case "$1" in
                --version) version="$2" ;;
                --build-number) build_number="$2" ;;
                --output-dir) output_dir="$2" ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage >&2; exit 2; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
if [ -z "$output_dir" ]; then
    output_dir="$project_root/.tmp/release/v$version"
fi

[ -d "$project_root/.build/checkouts" ] || {
    printf 'Error: missing .build/checkouts; run swift package --force-resolved-versions resolve first.\n' >&2
    exit 1
}

mkdir -p "$project_root/.tmp/anonymous-release"
stage_dir="$(mktemp -d "$project_root/.tmp/anonymous-release/run.XXXXXX")"
mount_dir=""

cleanup() {
    local code=$?
    set +e
    if [ -n "$mount_dir" ] && mount | grep -q "on $mount_dir "; then
        hdiutil detach "$mount_dir" >/dev/null 2>&1 || hdiutil detach -force "$mount_dir" >/dev/null 2>&1
    fi
    rm -rf "$stage_dir"
    exit "$code"
}
trap cleanup EXIT HUP INT TERM

build_dir="$stage_dir/build"
"$project_root/scripts/build-universal.sh" \
    --architecture universal \
    --version "$version" \
    --build-number "$build_number" \
    --output-dir "$build_dir"

app_path="$build_dir/AWSPlatform.app"
python3 "$project_root/scripts/anonymous_release_check.py" "$app_path"

zip_name="AWSPlatform-$version-universal.zip"
dmg_name="AWSPlatform-$version-universal.dmg"
zip_stage="$stage_dir/$zip_name"
dmg_stage="$stage_dir/$dmg_name"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$app_path" "$zip_stage"
/usr/bin/unzip -t -q "$zip_stage"
mkdir -p "$stage_dir/zip-verify"
/usr/bin/ditto -x -k "$zip_stage" "$stage_dir/zip-verify"
python3 "$project_root/scripts/anonymous_release_check.py" "$stage_dir/zip-verify/AWSPlatform.app"

dmg_src="$stage_dir/dmg-source"
mkdir -p "$dmg_src"
COPYFILE_DISABLE=1 /usr/bin/ditto "$app_path" "$dmg_src/AWSPlatform.app"
ln -s /Applications "$dmg_src/Applications"
find "$dmg_src" \( -name '._*' -o -name '.DS_Store' \) -delete
hdiutil create -volname "AWS Platform" -srcfolder "$dmg_src" -ov -format UDZO -fs HFS+ "$dmg_stage" >/dev/null
python3 "$project_root/scripts/anonymous_release_check.py" --dmg "$dmg_stage"

mount_dir="$stage_dir/dmg-mount"
mkdir -p "$mount_dir"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg_stage" >/dev/null
python3 "$project_root/scripts/anonymous_release_check.py" "$mount_dir/AWSPlatform.app"
hdiutil detach "$mount_dir" >/dev/null
mount_dir=""

rm -rf "$output_dir"
mkdir -p "$output_dir"
mv "$zip_stage" "$output_dir/$zip_name"
mv "$dmg_stage" "$output_dir/$dmg_name"
(cd "$output_dir" && shasum -a 256 "$dmg_name" "$zip_name" > SHA256SUMS.txt)

cat > "$output_dir/RELEASE_NOTES.md" <<EOF
# AWSPlatform ${version} (${build_number})

Universal macOS build (Apple Silicon & Intel, macOS 13+). Built with local ad-hoc signing (\`Signature=adhoc\`, \`TeamIdentifier=not set\`, no Developer ID certificate or Apple notarization) and scanned against build-path and privacy checks.

## Changes

- Build and distribute a single **Universal** (\`arm64\` + \`x86_64\`) anonymous package with bundled third-party licenses.
- Harden EC2 SSM handoff script lease tracking and expired temporary script cleanup.
- Remove the Sparkle in-app updater and certificate-bound update feeds; settings now link directly to GitHub Releases.

## Installation & Gatekeeper Notice

1. Download \`${dmg_name}\` (or \`${zip_name}\`), verify \`SHA256SUMS.txt\`, and move \`AWSPlatform.app\` into \`/Applications\`.
2. On first launch, macOS warns that the app is not notarized ([Apple Support](https://support.apple.com/102445)):
   - **System Settings**: Click **Done**, open **System Settings -> Privacy & Security**, scroll down, and click **Open Anyway**.
   - **Terminal**: Run \`xattr -cr /Applications/AWSPlatform.app\` once before opening.

---

# AWSPlatform ${version} (${build_number})（通用匿名构建）

支持 Apple Silicon 与 Intel 的 Universal 通用 macOS 构建（要求 macOS 13 或更高版本）。安装包采用纯本地 ad-hoc 签名（\`Signature=adhoc\`、\`TeamIdentifier=not set\`，不含 Developer ID 实名证书或 Apple 公证），并已完成构建路径映射与隐私扫描。

## 更新内容

- 切换为单一 **Universal**（\`arm64\` + \`x86_64\`）匿名安装包，并在应用内附带完整第三方依赖许可证。
- 加固 EC2 SSM 会话交接临时脚本租约追踪与过期残留回收逻辑。
- 移除依赖证书签名的 Sparkle 应用内更新器与更新清单，设置页提供 GitHub Releases 直达入口。

## 安装与首次打开放行说明

1. 下载 \`${dmg_name}\`（或 \`${zip_name}\`），建议先对照 \`SHA256SUMS.txt\` 校验哈希，再将 \`AWSPlatform.app\` 拖入「应用程序」。
2. 因未接入实名 Apple 公证，首次打开时 macOS 会弹出未验证提示（见 [Apple 官方指引](https://support.apple.com/zh-cn/102445)）：
   - **图形界面**：点击弹窗「完成」，打开 **系统设置 -> 隐私与安全性**，滑到底部点击 **「仍要打开」** 即可。
   - **终端放行**：执行一次 \`xattr -cr /Applications/AWSPlatform.app\` 清除下载隔离标记后即可直接打开。
EOF

ls -lh "$output_dir"
cat "$output_dir/SHA256SUMS.txt"
