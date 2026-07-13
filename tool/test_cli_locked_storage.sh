#!/usr/bin/env bash
# Exercise the CLI's honest Linux failure path when Secret Service hides a
# stored item behind a locked collection. This deliberately locks the login
# collection and therefore belongs only in a disposable dbus-run-session.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
  echo "$1" >&2
  exit 1
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "CLI locked-store check is Linux-only; skipped"
  exit 0
fi

if [[ "${KEYWAY_LOCKED_TEST:-}" != "1" ]]; then
  echo "refusing to lock a real login keyring" >&2
  echo "run only in a disposable dbus-run-session with KEYWAY_LOCKED_TEST=1" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keyway-cli-locked.XXXXXX")"
app_id="keyway-cli-locked-itest-${GITHUB_RUN_ID:-$$}"
cleanup() {
  rm -rf "$tmp"
  rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/$app_id"
}
trap cleanup EXIT

dart compile exe packages/keyway_cli/tool/integration_harness.dart \
  -o "$tmp/keyway-integration"

sentinel="keyway-locked-value-${GITHUB_RUN_ID:-$$}"
printf '%s' "$sentinel" | \
  "$tmp/keyway-integration" "$app_id" set --stdin keyway-itest/token

dbus-send \
  --session \
  --print-reply \
  --dest=org.freedesktop.secrets \
  /org/freedesktop/secrets \
  org.freedesktop.Secret.Service.Lock \
  array:objpath:/org/freedesktop/secrets/collection/login >/dev/null

set +e
output="$("$tmp/keyway-integration" "$app_id" list 2>&1)"
rc=$?
set -e

[[ $rc -eq 69 ]] || fail "locked-store list exited $rc, expected 69"
[[ "$output" == *"store key was not returned"* ]] || \
  fail "locked-store output omitted the observed failure"
[[ "$output" == *"Unlock or reconnect the OS keystore and retry first"* ]] || \
  fail "locked-store output omitted unlock guidance"
[[ "$output" == *"some locked Linux providers report this state"* ]] || \
  fail "locked-store output omitted provider guidance"
[[ "$output" != *"$sentinel"* ]] || \
  fail "locked-store output leaked the secret sentinel"

echo "CLI locked-store guidance passed"
