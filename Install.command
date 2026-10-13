#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
HELPER="$ROOT/bin/dual-kakaotalk-tool"
PROGRESS_APP="$ROOT/bin/DualKakaoProgress.app"
SOURCE="/Applications/KakaoTalk.app"
DESTINATION="/Applications/KakaoTalkWork.app"
HASHES="$ROOT/Compatibility/asset-sha256.txt"
INSTALLER_VERSION="0.2.0-beta.1"
PHASE="bootstrap"
FAILURE_RECORDED=0
LOG_DIR="$HOME/Library/Logs/DualKakaoTalk"
mkdir -p -m 700 "$LOG_DIR"
LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S)-$$.log"
PROGRESS_FILE="${TMPDIR:-/tmp}/DualKakaoTalk-progress-$$.state"
PROGRESS_STARTED=0
# Refuse a pre-existing/symlink log, then keep all installer output private to this user.
set -o noclobber
: > "$LOG"
chmod 600 "$LOG"
set +o noclobber
exec > >(/usr/bin/sed -E "s|$HOME|~|g; s|/private/tmp/DualKakaoTalk-[^ /]+|<STAGING>|g; s|/var/folders/[^ /]+|<TEMP>|g" | /usr/bin/tee -a "$LOG") 2>&1

LANG_CODE="${LANG:-en}"
if [[ "$LANG_CODE" == ko* ]]; then
  START="Dual KakaoTalk 설치를 시작합니다."
  MISSING="공식 KakaoTalk을 /Applications/KakaoTalk.app에 설치한 뒤 다시 실행하세요."
  MENU_ICON_SKIPPED="이 KakaoTalk 빌드는 메뉴 막대 아이콘 초록색 변경이 아직 검증되지 않아 이 단계만 건너뜁니다. 듀얼 실행과 초록색 앱 아이콘은 정상 적용됩니다."
  ARM_WARNING="M1~M5는 동일한 arm64 Universal 빌드를 사용합니다. M3/macOS 26.5.2는 검증 완료했으며 다른 칩·macOS 조합은 실험적입니다."
  BUSY="카카오톡 두 앱을 모두 종료한 뒤 설치 프로그램을 다시 실행하세요."
  DONE="완료되었습니다. 개인용과 듀얼 카카오톡을 실행합니다."
  FAILURE="설치에 실패했습니다. 개인정보를 확인한 뒤 로그와 함께 GitHub 이슈를 등록하시겠습니까?"
  REPORT_BUTTON="이슈 등록"
  CANCEL_BUTTON="취소"
  PROGRESS_TITLE="Dual KakaoTalk 설치"
  STEP_1="설치 프로그램을 확인하고 있습니다."
  STEP_2="공식 KakaoTalk 호환성을 확인하고 있습니다."
  STEP_3="실행 중인 KakaoTalk을 종료하고 있습니다."
  STEP_4="듀얼 카카오톡 이름과 초록색 아이콘을 준비하고 있습니다."
  STEP_5="듀얼 카카오톡을 복사·변경·서명하고 있습니다. 잠시 기다려 주세요."
  STEP_6="관리자 승인 후 듀얼 카카오톡을 설치하고 있습니다."
  STEP_7="설치 결과를 확인하고 앱을 실행하고 있습니다."
else
  START="Starting Dual KakaoTalk installation."
  MISSING="Install the official KakaoTalk app at /Applications/KakaoTalk.app, then run this installer again."
  MENU_ICON_SKIPPED="Green menu-bar icons are not verified for this KakaoTalk build, so only that step is skipped. Dual launch and the green app icon still apply."
  ARM_WARNING="M1 through M5 use the same arm64 Universal build. M3/macOS 26.5.2 is verified; other chip and macOS combinations remain experimental."
  BUSY="Quit both KakaoTalk applications and run the installer again."
  DONE="Installation complete. Opening personal and Dual KakaoTalk."
  FAILURE="Installation failed. Review the log for personal information, then open a GitHub issue?"
  REPORT_BUTTON="Open Issue"
  CANCEL_BUTTON="Cancel"
  PROGRESS_TITLE="Dual KakaoTalk Installation"
  STEP_1="Checking the installer."
  STEP_2="Checking official KakaoTalk compatibility."
  STEP_3="Closing running KakaoTalk applications."
  STEP_4="Preparing the Dual KakaoTalk name and green icons."
  STEP_5="Copying, modifying, and signing Dual KakaoTalk. This may take a moment."
  STEP_6="Installing Dual KakaoTalk after administrator approval."
  STEP_7="Verifying the installation and opening both apps."
fi

diagnostic() {
  printf 'diagnostic.%s=%s\n' "$1" "$2"
}

progress() {
  local current="$1" total="$2" message="$3" percent temporary
  percent=$((current * 100 / total))
  printf '\n[%s/%s] %s\n' "$current" "$total" "$message"
  temporary="$PROGRESS_FILE.tmp"
  printf '%s\n%s\nrunning\n' "$percent" "$message" > "$temporary"
  /bin/mv -f "$temporary" "$PROGRESS_FILE"
  if (( PROGRESS_STARTED == 0 )); then
    /usr/bin/open -n "$PROGRESS_APP" --args progress-window "$PROGRESS_FILE" "$PROGRESS_TITLE"
    PROGRESS_STARTED=1
  fi
}

finish_progress() {
  local state="$1" message="$2" temporary="$PROGRESS_FILE.tmp"
  if (( PROGRESS_STARTED == 1 )); then
    printf '100\n%s\n%s\n' "$message" "$state" > "$temporary"
    /bin/mv -f "$temporary" "$PROGRESS_FILE"
  fi
}

diagnostic schema_version 1
diagnostic installer_version "$INSTALLER_VERSION"
diagnostic timestamp_utc "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
diagnostic macos_version "$(/usr/bin/sw_vers -productVersion)"
diagnostic macos_build "$(/usr/bin/sw_vers -buildVersion)"
diagnostic architecture "$(/usr/bin/uname -m)"
diagnostic hardware_model "$(/usr/sbin/sysctl -n hw.model 2>/dev/null || printf unknown)"
diagnostic cpu_brand "$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)"
diagnostic locale "${LANG:-unknown}"

on_exit() {
  local status=$?
  if (( status != 0 && FAILURE_RECORDED == 0 )); then
    diagnostic result failed
    diagnostic failure_phase "$PHASE"
    diagnostic exit_code "$status"
    diagnostic log_file "$(basename "$LOG")"
  fi
  if (( status == 0 )); then
    finish_progress done "$DONE"
  else
    finish_progress failed "$FAILURE"
  fi
}
trap on_exit EXIT

on_error() {
  local status="${1:-1}" line="${2:-unknown}" choice
  trap - ERR
  FAILURE_RECORDED=1
  printf 'Installation failed at line %s (exit %s). Log: %s\n' "$line" "$status" "$LOG"
  diagnostic result failed
  diagnostic failure_phase "$PHASE"
  diagnostic exit_code "$status"
  diagnostic failure_line "$line"
  diagnostic log_file "$(basename "$LOG")"
  choice="$(/usr/bin/osascript -e "button returned of (display dialog \"$FAILURE\" buttons {\"$CANCEL_BUTTON\", \"$REPORT_BUTTON\"} default button \"$REPORT_BUTTON\" cancel button \"$CANCEL_BUTTON\")" 2>/dev/null || true)"
  if [[ "$choice" == "$REPORT_BUTTON" ]]; then
    /usr/bin/open -R "$LOG" || true
    /usr/bin/open 'https://github.com/hubeen/dual-kakaotalk-macos/issues/new?template=compatibility.yml' || true
  fi
  exit "$status"
}
trap 'on_error $? $LINENO' ERR
printf '%s\n' "$START"

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 13 )); then printf 'macOS Ventura 13 or newer is required.\n'; exit 1; fi
PHASE="helper_validation"
[[ -x "$HELPER" ]] || { printf 'Installer helper is missing or not executable.\n'; exit 1; }
[[ -d "$PROGRESS_APP" && ! -L "$PROGRESS_APP" ]] || { printf 'Installer progress application is missing.\n'; exit 1; }
# The user has explicitly opened this installer; clear inherited archive quarantine only from bundled executables.
if /usr/bin/xattr -p com.apple.quarantine "$HELPER" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.quarantine "$HELPER"
fi
if /usr/bin/xattr -p com.apple.quarantine "$PROGRESS_APP" >/dev/null 2>&1; then
  /usr/bin/xattr -dr com.apple.quarantine "$PROGRESS_APP"
fi
/usr/bin/codesign --verify --deep --strict "$PROGRESS_APP"
progress 1 7 "$STEP_1"
/usr/bin/codesign --verify --strict "$HELPER"
diagnostic helper_sha256 "$(/usr/bin/shasum -a 256 "$HELPER" | /usr/bin/cut -d' ' -f1)"
diagnostic helper_architectures "$(/usr/bin/lipo -archs "$HELPER")"
PHASE="source_validation"
progress 2 7 "$STEP_2"
[[ -d "$SOURCE" && ! -L "$SOURCE" ]] || { printf '%s\n' "$MISSING"; exit 1; }
assets="$SOURCE/Contents/Resources/Assets.car"
[[ -f "$assets" && ! -L "$assets" ]] || { printf '%s\n' "$MISSING"; exit 1; }
hash="$(shasum -a 256 "$assets" | cut -d' ' -f1)"
diagnostic kakao_version "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")"
diagnostic kakao_build "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Contents/Info.plist")"
diagnostic kakao_bundle_id "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
diagnostic assets_sha256 "$hash"
# An unrecognised catalog only disables the green menu-bar icons.  Installation continues, so a
# KakaoTalk update no longer requires a new installer release before the dual app can be rebuilt.
if /usr/bin/grep -Fxq "$hash" "$HASHES"; then
  diagnostic menu_bar_icons expected
else
  diagnostic menu_bar_icons skipped
  printf '%s\nAsset fingerprint: %s\n' "$MENU_ICON_SKIPPED" "$hash"
fi
if [[ "$(uname -m)" == arm64 ]]; then printf '%s\n' "$ARM_WARNING"; fi
PHASE="application_shutdown"
progress 3 7 "$STEP_3"
/usr/bin/osascript -e 'tell application id "com.kakao.KakaoTalkMac" to quit' 2>/dev/null || true
/usr/bin/osascript -e 'tell application id "com.kakao.KakaoTalkWorkMac" to quit' 2>/dev/null || true
for _ in {1..20}; do
  if ! /usr/bin/pgrep -x KakaoTalk >/dev/null && ! /usr/bin/pgrep -x KakaoTalkWork >/dev/null; then break; fi
  sleep 0.25
done
if /usr/bin/pgrep -x KakaoTalk >/dev/null || /usr/bin/pgrep -x KakaoTalkWork >/dev/null; then
  printf '%s\n' "$BUSY"
  exit 1
fi

PHASE="dual_identity_preparation"
progress 4 7 "$STEP_4"
PHASE="staging_preparation"
progress 5 7 "$STEP_5"
# Preparation, catalog mutation and ad-hoc signing happen before administrator authorization.
REQUEST="$("$HELPER" prepare-install "$hash" "1.0")"
[[ "$REQUEST" == /private/tmp/DualKakaoTalk-*/* || "$REQUEST" == /tmp/DualKakaoTalk-*/* ]] || { printf 'Invalid staging receipt.\n'; exit 1; }
PHASE="administrator_authorization"
progress 6 7 "$STEP_6"
/usr/bin/osascript - "$HELPER" "$REQUEST" <<'APPLESCRIPT'
on run argv
  set helperPath to item 1 of argv
  set requestPath to item 2 of argv
  do shell script (quoted form of helperPath & " install " & quoted form of requestPath) with administrator privileges
end run
APPLESCRIPT
PHASE="installed_app_verification"
progress 7 7 "$STEP_7"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"
diagnostic result success
diagnostic installed_bundle_id "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")"
diagnostic installed_icon_file "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$DESTINATION/Contents/Info.plist" 2>/dev/null || printf unset)"
PHASE="launch"
printf '%s\n' "$DONE"
open "$SOURCE"
open -n "$DESTINATION"
PHASE="complete"
# Keep only five 0600, privacy-sanitized logs.
/usr/bin/find "$LOG_DIR" -type f -name 'install-*.log' -print0 | /usr/bin/xargs -0 ls -1t 2>/dev/null | /usr/bin/awk 'NR>5' | while IFS= read -r old; do rm -f "$old"; done
