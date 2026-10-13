#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="$ROOT/.build-release"
DIST="$ROOT/dist/Dual-KakaoTalk-for-macOS"
ARTIFACT="$ROOT/dist/Dual-KakaoTalk-for-macOS-v0.2.0-beta.1.zip"
MANIFEST="$ARTIFACT.manifest.json"
DEPLOYMENT_TARGET=13.0

fail() {
  printf 'release validation failed: %s\n' "$*" >&2
  exit 1
}

require_universal_slice() {
  local binary="$1"
  local arch="$2"
  lipo -archs "$binary" | tr ' ' '\n' | grep -Fx "$arch" >/dev/null || fail "$binary is missing $arch"
}

require_macos_13_or_later() {
  local binary="$1"
  local version
  version="$(otool -l "$binary" | awk '
    $1 == "cmd" && ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX") { want_version = 1; next }
    want_version && ($1 == "minos" || $1 == "version") { print $2; exit }
  ')"
  [[ -n "$version" ]] || fail "$binary has no macOS deployment load command"
  [[ "$version" == 13.* ]] || fail "$binary targets macOS $version; the release must retain a macOS 13 deployment target"
}

require_private_coreui_load() {
  local binary="$1"
  otool -L "$binary" | grep -F 'CoreUI.framework/Versions/A/CoreUI' >/dev/null || fail "$binary is missing the expected CoreUI private framework load"
  otool -l "$binary" | awk '
    $1 == "cmd" { load = ($2 == "LC_LOAD_DYLIB") }
    load && $1 == "name" && $2 ~ /CoreUI\.framework\/Versions\/A\/CoreUI/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' || fail "$binary is missing the expected LC_LOAD_DYLIB command for CoreUI"
}

audit_archive() {
  local archive="$1"
  local extracted entry entry_lower magic
  extracted="$(mktemp -d "${TMPDIR:-/tmp}/dual-kakaotalk-audit.XXXXXX")"
  trap 'rm -rf "$extracted"' RETURN

  while IFS= read -r entry; do
    entry_lower="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    case "$entry_lower" in
      *.app|*.app/*)
        case "$entry" in
          */bin/DualKakaoProgress.app|*/bin/DualKakaoProgress.app/*) ;;
          *) fail "archive contains forbidden application bundle: $entry" ;;
        esac
        ;;
      *.car|*.icns|*.png|*.jpg|*.jpeg|*.gif|*.zip)
        fail "archive contains forbidden Kakao asset name: $entry"
        ;;
    esac
  done < <(zipinfo -1 "$archive")

  unzip -q "$archive" -d "$extracted"
  while IFS= read -r -d '' entry; do
    magic="$(file -b "$entry")"
    case "$magic" in
      *'PNG image data'*|*'JPEG image data'*|*'GIF image data'*|*'Apple icon image'*|*'Zip archive data'*|*'Apple asset catalog'*)
        fail "archive contains forbidden Kakao asset magic: $entry ($magic)"
        ;;
    esac
  done < <(find "$extracted" -type f -print0)

  rm -rf "$extracted"
  trap - RETURN
}

rm -rf "$BUILD" "$DIST"
mkdir -p "$DIST/bin" "$DIST/Compatibility"

# Release archives ship Universal.  ARCHS exists so a contributor without a
# working cross-compile toolchain can still produce a host-only build for their
# own machine: DUAL_KAKAOTALK_ARCHS=arm64 ./Scripts/build-release.sh
read -r -a ARCHS <<< "${DUAL_KAKAOTALK_ARCHS:-x86_64 arm64}"
[[ ${#ARCHS[@]} -gt 0 ]] || fail "DUAL_KAKAOTALK_ARCHS must name at least one architecture"

# SwiftPM's output layout is not stable across build systems -- the newer one
# writes under <scratch>/out/Products rather than <scratch>/<triple>/release --
# so ask SwiftPM where the binary landed instead of assuming a path.
BUILT_BINARY=""
build_arch() {
  local arch="$1" scratch="$BUILD/$arch" bin_path
  mkdir -p "$scratch"
  swift build -c release --arch "$arch" --scratch-path "$scratch"
  bin_path="$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path | tail -n 1)"
  BUILT_BINARY=""
  local candidate
  for candidate in "$bin_path/dual-kakaotalk-tool" \
      $(find "$scratch" -type f -name dual-kakaotalk-tool 2>/dev/null); do
    [[ -f "$candidate" ]] || continue
    lipo -archs "$candidate" 2>/dev/null | tr ' ' '\n' | grep -Fx "$arch" >/dev/null || continue
    BUILT_BINARY="$candidate"
    break
  done
  [[ -n "$BUILT_BINARY" ]] || fail "no $arch dual-kakaotalk-tool build output under $scratch"
}

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
SLICES=()
for arch in "${ARCHS[@]}"; do
  build_arch "$arch"
  require_macos_13_or_later "$BUILT_BINARY"
  require_private_coreui_load "$BUILT_BINARY"
  SLICES+=("$BUILT_BINARY")
done

lipo -create "${SLICES[@]}" -output "$DIST/bin/dual-kakaotalk-tool"
chmod +x "$DIST/bin/dual-kakaotalk-tool"
for arch in "${ARCHS[@]}"; do
  require_universal_slice "$DIST/bin/dual-kakaotalk-tool" "$arch"
done

PROGRESS_APP="$DIST/bin/DualKakaoProgress.app"
mkdir -p "$PROGRESS_APP/Contents/MacOS"
cp "$DIST/bin/dual-kakaotalk-tool" "$PROGRESS_APP/Contents/MacOS/dual-kakaotalk-tool"
cat > "$PROGRESS_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleExecutable</key>
  <string>dual-kakaotalk-tool</string>
  <key>CFBundleIdentifier</key>
  <string>com.hubeen.DualKakaoTalk.Progress</string>
  <key>CFBundleName</key>
  <string>Dual KakaoTalk</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0-beta.1</string>
  <key>CFBundleVersion</key>
  <string>22</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
EOF

cp "$ROOT/Install.command" "$DIST/Install.command"
chmod +x "$DIST/Install.command"
cp "$ROOT/Uninstall.command" "$DIST/Uninstall.command"
chmod +x "$DIST/Uninstall.command"
cp "$ROOT/Compatibility/asset-sha256.txt" "$DIST/Compatibility/asset-sha256.txt"
cp "$ROOT/README.md" "$DIST/README.ko.txt"
cp "$ROOT/README.en.md" "$DIST/README.en.txt"
cp "$ROOT/LICENSE" "$DIST/LICENSE.txt"

codesign --force --sign - "$DIST/bin/dual-kakaotalk-tool"
codesign --verify --strict --verbose=2 "$DIST/bin/dual-kakaotalk-tool"
codesign --force --deep --sign - "$PROGRESS_APP"
codesign --verify --deep --strict --verbose=2 "$PROGRESS_APP"
"$ROOT/Scripts/verify-no-kakao-assets.sh"

mkdir -p "$ROOT/dist"
rm -f "$ARTIFACT" "$MANIFEST"
ditto --norsrc -c -k --keepParent "$DIST" "$ARTIFACT"
audit_archive "$ARTIFACT"

artifact_sha256="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
source_revision="${GITHUB_SHA:-unknown}"
build_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$MANIFEST" <<EOF
{
  "schemaVersion": 1,
  "artifact": "$(basename "$ARTIFACT")",
  "sha256": "$artifact_sha256",
  "sourceRevision": "$source_revision",
  "builtAt": "$build_timestamp",
  "deploymentTarget": "$DEPLOYMENT_TARGET",
  "architectures": [$(printf '"%s",' "${ARCHS[@]}" | sed 's/,$//')],
  "provenance": "CI-generated build metadata only; it is not immutable or protected provenance."
}
EOF

printf 'Artifact SHA-256: %s\nManifest: %s\n' "$artifact_sha256" "$MANIFEST"
