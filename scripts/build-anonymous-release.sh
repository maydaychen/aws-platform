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
if [ "$output_dir" != "/" ]; then
    output_dir="${output_dir%/}"
fi
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
    printf 'Error: output directory already exists; refusing to overwrite: %s\n' "$output_dir" >&2
    exit 1
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
python3 "$project_root/scripts/anonymous_release_check.py" --zip "$zip_stage"
python3 "$project_root/scripts/privacy_scan.py" "$stage_dir/zip-verify"
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
python3 "$project_root/scripts/anonymous_release_check.py" --dmg-mount "$mount_dir"
hdiutil detach "$mount_dir" >/dev/null
mount_dir=""

metadata_dir="$stage_dir/release-metadata"
mkdir -p "$metadata_dir"
(cd "$stage_dir" && shasum -a 256 "$dmg_name" "$zip_name" > "$metadata_dir/SHA256SUMS.txt")

cat > "$metadata_dir/RELEASE_NOTES.md" <<EOF
# AWSPlatform ${version} (${build_number})

Universal macOS build (Apple Silicon & Intel, macOS 13+). \`AWSPlatform.app\` uses local ad-hoc signing (\`Signature=adhoc\`, \`TeamIdentifier=not set\`, no Developer ID certificate or Apple notarization), the outer \`.dmg\` disk image container is unsigned, and both build paths and packaged payloads pass privacy verification.

## Changes

- Build and distribute a single **Universal** (\`arm64\` + \`x86_64\`) anonymous package with bundled third-party licenses.
- Harden profile/credential generation scope isolation, async AWS config loading, S3 download commit/ACL safety, Auto Scaling default template version resolution, and keyboard/detail UI interactions.
- Harden EC2 SSM handoff script lease tracking and expired temporary script cleanup.
- Remove the Sparkle in-app updater and certificate-bound update feeds; settings now link directly to GitHub Releases.

## Installation & Gatekeeper Notice

1. Download \`${dmg_name}\` (or \`${zip_name}\`), verify \`SHA256SUMS.txt\`, and move \`AWSPlatform.app\` into \`/Applications\`.
2. On first launch, macOS warns that the app is not notarized ([Apple Support](https://support.apple.com/102445)):
   - **Recommended (System Settings)**: Click **Done**, open **System Settings -> Privacy & Security**, scroll down, and click **Open Anyway**.
   - **Alternative (Terminal, after verifying \`SHA256SUMS.txt\`)**: Run \`xattr -d com.apple.quarantine /Applications/AWSPlatform.app\` once before opening.

---

# AWSPlatform ${version} (${build_number})（通用匿名构建）

支持 Apple Silicon 与 Intel 的 Universal 通用 macOS 构建（要求 macOS 13 或更高版本）。应用 \`AWSPlatform.app\` 采用纯本地 ad-hoc 签名（\`Signature=adhoc\`、\`TeamIdentifier=not set\`，不含 Developer ID 实名证书或 Apple 公证），外层 \`.dmg\` 磁盘映像容器本身未签名，已完成构建路径映射与隐私扫描。

## 更新内容

- 切换为单一 **Universal**（\`arm64\` + \`x86_64\`）匿名安装包，并在应用内附带完整第三方依赖许可证。
- 补齐服务端身份代次与作用域隔离、AWS 配置异步读取、S3 下载原子提交与继承 ACL 防护、Auto Scaling 默认启动模板版本解析及列表／详情交互细节。
- 加固 EC2 SSM 会话交接临时脚本租约追踪与过期残留回收逻辑。
- 移除依赖证书签名的 Sparkle 应用内更新器与更新清单，设置页提供 GitHub Releases 直达入口。

## 安装与首次打开放行说明

1. 下载 \`${dmg_name}\`（或 \`${zip_name}\`），建议先对照 \`SHA256SUMS.txt\` 校验哈希，再将 \`AWSPlatform.app\` 拖入「应用程序」。
2. 因未接入实名 Apple 公证，首次打开时 macOS 会弹出未验证提示（见 [Apple 官方指引](https://support.apple.com/zh-cn/102445)）：
   - **推荐（图形界面）**：点击弹窗「完成」，打开 **系统设置 -> 隐私与安全性**，滑到底部点击 **「仍要打开」** 即可。
   - **备选（终端，请先核对 \`SHA256SUMS.txt\`）**：执行一次 \`xattr -d com.apple.quarantine /Applications/AWSPlatform.app\` 移除下载隔离属性后再打开。
EOF

python3 "$project_root/scripts/privacy_scan.py" "$metadata_dir"
release_bundle="$stage_dir/release-bundle"
mkdir -p "$release_bundle"
mv "$zip_stage" "$release_bundle/$zip_name"
mv "$dmg_stage" "$release_bundle/$dmg_name"
mv "$metadata_dir/SHA256SUMS.txt" "$release_bundle/SHA256SUMS.txt"
mv "$metadata_dir/RELEASE_NOTES.md" "$release_bundle/RELEASE_NOTES.md"
(cd "$release_bundle" && shasum -a 256 -c SHA256SUMS.txt >/dev/null)
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
    printf 'Error: output directory already exists; refusing to overwrite: %s\n' "$output_dir" >&2
    exit 1
fi
mkdir -p "$(dirname "$output_dir")"
mv "$release_bundle" "$output_dir"

ls -lh "$output_dir"
cat "$output_dir/SHA256SUMS.txt"
