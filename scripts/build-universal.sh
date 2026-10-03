#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="AWSPlatform"
dist_dir="$project_root/dist"
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 2 ] && [ "$1" = --output-dir ] && [ -n "$2" ]; then
        mkdir -p "$2"
        dist_dir="$(cd "$2" && pwd)"
    else
        printf 'Usage: %s [--output-dir DIRECTORY]\n' "$0" >&2
        exit 2
    fi
fi
stage_dir=""
publishing=0
old_app=0
old_zip=0
new_app=0
new_zip=0

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    restore_failed=0
    if [ "$result" -ne 0 ] && [ "$publishing" -eq 1 ]; then
        if [ "$new_app" -eq 1 ]; then
            rm -rf "$dist_dir/$app_name.app" || restore_failed=1
        fi
        if [ "$new_zip" -eq 1 ]; then
            rm -f "$dist_dir/$app_name-universal.zip" || restore_failed=1
        fi
        if [ "$old_app" -eq 1 ]; then
            mv "$stage_dir/previous.app" "$dist_dir/$app_name.app" || restore_failed=1
        fi
        if [ "$old_zip" -eq 1 ]; then
            mv "$stage_dir/previous.zip" "$dist_dir/$app_name-universal.zip" || restore_failed=1
        fi
    fi
    if [ "$restore_failed" -ne 0 ]; then
        printf 'Could not restore every previous artifact. Preserved files: %s\n' "$stage_dir" >&2
    elif [ -n "$stage_dir" ]; then
        rm -rf "$stage_dir"
    fi
    exit "$result"
}

[ "$(uname -s)" = Darwin ] || fail 'This script requires macOS and Xcode command-line tools.'
[ -f "$project_root/Package.resolved" ] || fail 'Package.resolved is required; resolve and review dependency versions first.'
command -v swift >/dev/null || fail 'Swift was not found.'
xcrun --find lipo >/dev/null
xcrun --find vtool >/dev/null
# These engines generate accessors that search an app's Contents/Resources.
build_system=xcode
case "$(swift build --help-hidden)" in
    *swiftbuild*) build_system=swiftbuild ;;
esac
mkdir -p "$project_root/.tmp/universal-build"
stage_dir="$(mktemp -d "$project_root/.tmp/universal-build/run.XXXXXX")"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$project_root/Package.resolved" "$stage_dir/Package.resolved"

build_architecture() {
    local architecture="$1"
    local bin_path
    local bundle
    local bundle_count=0
    local swift_args=(
        --package-path "$project_root"
        --configuration release
        --build-system "$build_system"
        --arch "$architecture"
        --product "$app_name"
        --disable-automatic-resolution
    )

    printf 'Building %s for %s...\n' "$app_name" "$architecture"
    MACOSX_DEPLOYMENT_TARGET=13.0 swift build "${swift_args[@]}"
    cmp -s "$stage_dir/Package.resolved" "$project_root/Package.resolved" || fail 'Package.resolved changed during the build.'
    bin_path="$(swift build "${swift_args[@]}" --show-bin-path)"
    [ -x "$bin_path/$app_name" ] || fail "Missing executable for $architecture: $bin_path/$app_name"
    mkdir -p "$stage_dir/$architecture/resources"
    cp "$bin_path/$app_name" "$stage_dir/$architecture/$app_name"
    xcrun lipo "$stage_dir/$architecture/$app_name" -verify_arch "$architecture"

    # Capture each build immediately: some SwiftPM engines share their output path.
    for bundle in "$bin_path"/*.bundle; do
        [ -d "$bundle" ] || continue
        /usr/bin/ditto "$bundle" "$stage_dir/$architecture/resources/$(basename "$bundle")"
        bundle_count=$((bundle_count + 1))
    done
    [ "$bundle_count" -gt 0 ] || fail "Missing SwiftPM resource bundles for $architecture."
}

build_architecture arm64
build_architecture x86_64
diff -rq "$stage_dir/arm64/resources" "$stage_dir/x86_64/resources" || fail 'The architecture builds contain different resource bundles.'

app_path="$stage_dir/$app_name.app"
executable="$app_path/Contents/MacOS/$app_name"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
xcrun lipo -create "$stage_dir/arm64/$app_name" "$stage_dir/x86_64/$app_name" -output "$executable"
chmod 755 "$executable"
/usr/bin/ditto "$stage_dir/arm64/resources" "$app_path/Contents/Resources"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AWSPlatform</string>
    <key>CFBundleIdentifier</key>
    <string>AWSPlatform</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AWSPlatform</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$app_path/Contents/Info.plist"
for architecture in arm64 x86_64; do
    xcrun lipo "$executable" -verify_arch "$architecture"
    minimum_os="$(xcrun vtool -arch "$architecture" -show-build "$executable" | awk '$1 == "minos" { print $2 }')"
    case "$minimum_os" in
        13.0|13.0.0) ;;
        *) fail "Expected macOS 13.0 for $architecture; found: $minimum_os" ;;
    esac
done

# Include Swift back-deployment libraries before removing build-machine search paths.
frameworks_dir="$app_path/Contents/Frameworks"
mkdir -p "$frameworks_dir"
xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$executable" \
    --destination "$frameworks_dir" --sign -
# The tool may retain a backup when re-signing copied libraries.
rm -f "$frameworks_dir"/*.dylib.original
while IFS= read -r build_rpath; do
    case "$build_rpath" in
        /usr/lib/swift) ;;
        /*) xcrun install_name_tool -delete_rpath "$build_rpath" "$executable" ;;
    esac
done < <(xcrun otool -l "$executable" | awk '
    $1 == "cmd" { is_rpath = ($2 == "LC_RPATH") }
    is_rpath && $1 == "path" {
        sub(/^[[:space:]]*path /, ""); sub(/ [(]offset.*$/, ""); print
    }' | sort -u)
xcrun install_name_tool -add_rpath '@executable_path/../Frameworks' "$executable"

while IFS= read -r dependency; do
    [ -f "$frameworks_dir/${dependency#@rpath/}" ] || fail "Missing bundled library: $dependency"
done < <(xcrun otool -L "$executable" | awk '$1 ~ /^@rpath\// { print $1 }' | sort -u)
for library in "$frameworks_dir"/*.dylib; do
    [ -f "$library" ] || continue
    for architecture in arm64 x86_64; do
        xcrun lipo "$library" -verify_arch "$architecture"
        minimum_os="$(xcrun vtool -arch "$architecture" -show-build "$library" | awk '
            $1 == "cmd" { legacy_macos = ($2 == "LC_VERSION_MIN_MACOSX"); platform = "" }
            $1 == "platform" { platform = $2 }
            legacy_macos && $1 == "version" { print $2 }
            platform == "MACOS" && $1 == "minos" { print $2 }')"
        [ -n "$minimum_os" ] || fail "Missing macOS deployment target: $library ($architecture)"
        printf '%s\n' "$minimum_os" | awk -F. '
            $1 < 13 || ($1 == 13 && $2 == 0 && ($3 == "" || $3 == 0)) { next }
            { exit 1 }' || fail "Runtime requires newer than macOS 13: $library ($architecture)"
    done
    /usr/bin/codesign --verify --strict --verbose=2 "$library"
done

# Ad-hoc signing uses no signing identity or Apple account.
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/ditto -c -k --keepParent "$app_path" "$stage_dir/$app_name-universal.zip"
/usr/bin/unzip -t -q "$stage_dir/$app_name-universal.zip"

# Keep prior deliverables until both new artifacts have passed validation.
mkdir -p "$dist_dir"
publishing=1
if [ -e "$dist_dir/$app_name.app" ]; then
    mv "$dist_dir/$app_name.app" "$stage_dir/previous.app"
    old_app=1
fi
if [ -e "$dist_dir/$app_name-universal.zip" ]; then
    mv "$dist_dir/$app_name-universal.zip" "$stage_dir/previous.zip"
    old_zip=1
fi
mv "$app_path" "$dist_dir/$app_name.app"
new_app=1
mv "$stage_dir/$app_name-universal.zip" "$dist_dir/$app_name-universal.zip"
new_zip=1
publishing=0

printf '\nBuilt Universal app (arm64 + x86_64, macOS 13+):\n%s\n%s\n' \
    "$dist_dir/$app_name.app" "$dist_dir/$app_name-universal.zip"
printf 'Signing: local ad-hoc only; not Developer ID signed or notarized.\n'
