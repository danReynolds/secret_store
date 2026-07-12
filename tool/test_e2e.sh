#!/usr/bin/env bash
# The FULL end-to-end matrix, one command: every supported platform exercised
# against its REAL keystore (simulator/emulator for mobile), repeatably.
#
#   ./tool/test_e2e.sh              # all legs except entitled-macOS
#   ./tool/test_e2e.sh --entitled   # + the DP-success leg (needs a signing
#                                   #   identity; temporarily applies the
#                                   #   Keychain Sharing overlay, restores it)
#
# Legs (each = the real platform, not a mock):
#   unit        hermetic tier: crypto vectors, container fuzz, resolver fakes
#   macos-cli   real login Keychain via SecItem (dart test, this machine)
#   linux       real gnome-keyring under D-Bus (Docker)
#   macos-app   file scheme inside a real sandboxed .app (Flutter harness)
#   ios         native DP items on an iPhone simulator (Flutter harness)
#   android     hardware-Keystore-wrapped file scheme on an emulator (harness)
#   entitled    (--entitled) native DP items in a signed, entitled macOS app
#
# Requires: macOS dev box with Xcode (+ an iPhone simulator runtime), the
# Android SDK (+ one AVD), Flutter, Docker.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$REPO/example_flutter"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ENTITLED=0
[[ "${1:-}" == "--entitled" ]] && ENTITLED=1

declare -a RESULTS=()
STARTED_EMULATOR=0

note() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
record() { RESULTS+=("$1|$2"); }

run_leg() { # name, command...
  local name="$1"; shift
  note "$name"
  if "$@"; then record "$name" "PASS"; else record "$name" "FAIL"; fi
}

# --- device lifecycle ----------------------------------------------------------

boot_ios_sim() {
  IOS_UDID=$(xcrun simctl list devices available | grep -m1 -E "iPhone" \
    | grep -oE '[0-9A-F-]{36}' || true)
  [[ -z "$IOS_UDID" ]] && return 1
  xcrun simctl boot "$IOS_UDID" 2>/dev/null || true # already booted is fine
  local waited=0
  until xcrun simctl list devices booted | grep -q "$IOS_UDID"; do
    sleep 2; waited=$((waited + 2)); [[ $waited -ge 120 ]] && return 1
  done
}

boot_android_emu() {
  local emu_pid=""
  if ! adb devices | grep -q "^emulator-"; then
    local avd
    avd=$("$ANDROID_SDK/emulator/emulator" -list-avds | head -1)
    [[ -z "$avd" ]] && { echo "no AVD found"; return 1; }
    # Reset a possibly-stale adb server (e.g. left over from a prior leg that
    # killed its emulator) so the fresh instance is seen.
    adb kill-server >/dev/null 2>&1 || true
    adb start-server >/dev/null 2>&1 || true
    "$ANDROID_SDK/emulator/emulator" -avd "$avd" -no-snapshot -no-audio \
      -no-boot-anim -gpu swiftshader_indirect >/tmp/e2e-emulator.log 2>&1 &
    emu_pid=$!
    STARTED_EMULATOR=$emu_pid
    disown "$emu_pid" 2>/dev/null || true
  fi
  local waited=0
  until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    # Fail fast if an emulator we launched died before booting, instead of
    # waiting out the full timeout.
    if [[ -n "$emu_pid" ]] && ! kill -0 "$emu_pid" 2>/dev/null; then
      echo "emulator exited before boot (see /tmp/e2e-emulator.log)"
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
    [[ $waited -ge 420 ]] && { echo "emulator boot timed out"; return 1; }
  done
}

# --- entitled-macOS overlay (applied temporarily, always restored) --------------

XCCONFIG="$HARNESS/macos/Runner/Configs/AppInfo.xcconfig"
ENTITLEMENTS="$HARNESS/macos/Runner/DebugProfile.entitlements"
OVERLAY_BACKUP=""

apply_entitled_overlay() {
  local team
  team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[A-Z0-9]{10}' | head -1 | cut -d= -f2)
  [[ -z "$team" ]] && { echo "no Apple Development identity/team found"; return 1; }
  OVERLAY_BACKUP=$(mktemp -d)
  cp "$XCCONFIG" "$ENTITLEMENTS" "$OVERLAY_BACKUP/" \
    || { echo "overlay backup copy failed; leaving configs untouched"; return 1; }
  printf '\nDEVELOPMENT_TEAM = %s\nCODE_SIGN_IDENTITY = Apple Development\n' \
    "$team" >>"$XCCONFIG"
  /usr/bin/sed -i '' \
    's|<key>com.apple.security.network.server</key>|<key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)com.example.exampleFlutter</string></array><key>com.apple.security.network.server</key>|' \
    "$ENTITLEMENTS"
  # Regenerate Flutter's ephemeral xcode inputs, then provision (idempotent;
  # creates the managed profile on first run — needs the account's PLA signed).
  (cd "$HARNESS" && flutter build macos --debug --config-only >/dev/null) &&
    (cd "$HARNESS/macos" && xcodebuild build -workspace Runner.xcworkspace \
      -scheme Runner -configuration Debug -destination 'platform=macOS' \
      -allowProvisioningUpdates -quiet)
}

restore_entitled_overlay() {
  [[ -n "$OVERLAY_BACKUP" ]] || return 0
  local failed=0
  cp "$OVERLAY_BACKUP/AppInfo.xcconfig" "$XCCONFIG" || failed=1
  cp "$OVERLAY_BACKUP/DebugProfile.entitlements" "$ENTITLEMENTS" || failed=1
  [[ $failed -eq 0 ]] && rm -rf "$OVERLAY_BACKUP" # keep the backup on failure
  OVERLAY_BACKUP=""
}
trap restore_entitled_overlay EXIT

# --- the legs -------------------------------------------------------------------

leg_unit() {
  cd "$REPO" && dart format --output=none --set-exit-if-changed . &&
    dart analyze --fatal-infos && dart test -x integration
}
leg_macos_cli() {
  cd "$REPO" && KEYWAY_INTEGRATION=1 dart test test/keychain_integration_test.dart
}
leg_linux() { cd "$REPO" && ./tool/test_linux.sh; }
leg_macos_app() {
  # Distinct APP_ID from the entitled leg — same machine, different scheme, so
  # they must not share an app-support dir (the migration guard would fire).
  cd "$HARNESS" && flutter test integration_test/keyway_test.dart \
    -d macos --dart-define=APP_ID=com.example.keywayHarness.file \
    --dart-define=EXPECT_SCHEME=file --dart-define=EXPECT_LEVEL=login
}
leg_ios() {
  boot_ios_sim || return 1
  # Modern iOS Simulators (Xcode 15+) emulate the Secure Enclave, so the SE
  # probe succeeds and reports hardware — same as a real device. (The probe
  # reports software only where an SE is genuinely absent, e.g. a pre-T2 Intel
  # Mac, which isn't emulated.)
  cd "$HARNESS" && flutter test integration_test/keyway_test.dart \
    -d "$IOS_UDID" --dart-define=EXPECT_SCHEME=native \
    --dart-define=EXPECT_LEVEL=hardware
}
leg_android() {
  boot_android_emu || return 1
  # Level is measured from the KEK (asserted in the dedicated test after a
  # write); leave EXPECT_LEVEL unset here.
  cd "$HARNESS" && flutter test integration_test/keyway_test.dart \
    -d "$(adb devices | grep -m1 '^emulator-' | cut -f1)" \
    --dart-define=EXPECT_SCHEME=file
}
leg_entitled() {
  apply_entitled_overlay || return 1
  # This dev Mac (Apple silicon) has a Secure Enclave → hardware.
  local rc=0
  (cd "$HARNESS" && flutter test integration_test/keyway_test.dart \
    -d macos --dart-define=EXPECT_SCHEME=native \
    --dart-define=EXPECT_LEVEL=hardware \
    --dart-define=APP_ID=com.example.keywayHarness.native) || rc=1
  restore_entitled_overlay
  return $rc
}

run_leg "unit + analyze"          leg_unit
run_leg "macOS CLI (login Keychain)" leg_macos_cli
run_leg "Linux (gnome-keyring, Docker)" leg_linux
run_leg "macOS .app (file scheme)" leg_macos_app
run_leg "iOS simulator (DP native items)" leg_ios
run_leg "Android emulator (Keystore-wrapped)" leg_android
if [[ $ENTITLED -eq 1 ]]; then
  run_leg "macOS entitled (DP success)" leg_entitled
else
  record "macOS entitled (DP success)" "SKIP (--entitled to run; needs signing identity)"
fi

# If we booted the emulator, shut it down again.
if [[ "$STARTED_EMULATOR" != "0" ]]; then
  adb -s "$(adb devices | grep -m1 '^emulator-' | cut -f1)" emu kill \
    >/dev/null 2>&1 || true
fi

note "e2e matrix"
FAILED=0
for r in "${RESULTS[@]}"; do
  printf '  %-38s %s\n' "${r%%|*}" "${r##*|}"
  [[ "${r##*|}" == "FAIL" ]] && FAILED=1
done
exit $FAILED
