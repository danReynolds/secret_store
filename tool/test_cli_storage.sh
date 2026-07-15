#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keybay-cli-storage.XXXXXX")"
holder_pid=""
app_id=""
writer_pids=()
fail() {
  echo "$1" >&2
  exit 1
}
cleanup() {
  # macOS still ships Bash 3.2, where expanding an empty array under `set -u`
  # is an unbound-variable error. Guard before expanding it.
  if [[ -n "${writer_pids[*]-}" ]]; then
    for writer_pid in "${writer_pids[@]}"; do
      kill "$writer_pid" 2>/dev/null || true
      wait "$writer_pid" 2>/dev/null || true
    done
  fi
  if [[ -n "$holder_pid" ]]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  if [[ -n "$app_id" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      rm -rf "$HOME/Library/Application Support/$app_id"
      security delete-generic-password -s "$app_id" -a store-key \
        >/dev/null 2>&1 || true
    else
      rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/$app_id"
      secret-tool clear -- service "$app_id" account store-key \
        >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

dart compile exe packages/keybay_cli/tool/integration_harness.dart \
  -o "$tmp/keybay-integration"

app_id="keybay-cli-itest-${GITHUB_RUN_ID:-$$}"
key="keybay-itest/token"
sentinel="keybay-integration-value-${GITHUB_RUN_ID:-$$}"
manifest="$tmp/.secrets.env"
printf 'LITERAL=from-manifest\nSECRET=kb://%s\n' "$key" >"$manifest"

concurrent_writers=8
concurrent_names=()
concurrent_gate="$tmp/concurrent-writer-gate"
for writer in $(seq 0 $((concurrent_writers - 1))); do
  suffix="$(printf '%02d' "$writer")"
  concurrent_names+=("CONCURRENT_$suffix")
  printf 'CONCURRENT_%s=kb://keybay-itest/concurrent-%s\n' \
    "$suffix" "$suffix" >>"$manifest"
  (
    touch "$tmp/concurrent-writer-ready-$suffix"
    while [[ ! -e "$concurrent_gate" ]]; do
      sleep 0.01
    done
    printf 'concurrent-%s' "$suffix" | \
      "$tmp/keybay-integration" "$app_id" set --stdin \
        "keybay-itest/concurrent-$suffix"
  ) &
  writer_pids+=("$!")
done
ready_count=0
for _ in $(seq 1 200); do
  ready_count="$(
    find "$tmp" -name 'concurrent-writer-ready-*' -type f | \
      wc -l | tr -d ' '
  )"
  [[ "$ready_count" == "$concurrent_writers" ]] && break
  sleep 0.01
done
[[ "$ready_count" == "$concurrent_writers" ]] || \
  fail "concurrent writers did not reach the start gate"
touch "$concurrent_gate"
writer_failed=0
for writer_pid in "${writer_pids[@]}"; do
  if ! wait "$writer_pid"; then
    writer_failed=1
  fi
done
writer_pids=()
((writer_failed == 0)) || fail "a concurrent writer failed"

set_output="$(printf '%s' "$sentinel" | \
  "$tmp/keybay-integration" "$app_id" set --stdin "$key")"
[[ -z "$set_output" ]] || fail "set --stdin wrote unexpected output"

list_output="$("$tmp/keybay-integration" "$app_id" list)"
expected_list="$(
  for writer in $(seq 0 $((concurrent_writers - 1))); do
    printf 'keybay-itest/concurrent-%02d\n' "$writer"
  done
  printf 'keybay-itest/token'
)"
[[ "$list_output" == "$expected_list" ]] || \
  fail "list output did not contain the sorted test keys"

concurrent_values="$(
  "$tmp/keybay-integration" "$app_id" run -f "$manifest" -- \
    /bin/sh -c 'for name do /usr/bin/printenv "$name"; done' \
      keybay-concurrent-values "${concurrent_names[@]}"
)"
expected_values="$(
  for writer in $(seq 0 $((concurrent_writers - 1))); do
    printf 'concurrent-%02d\n' "$writer"
  done
)"
[[ "$concurrent_values" == "$expected_values" ]] || \
  fail "concurrent writes did not preserve every value"

resolved="$("$tmp/keybay-integration" "$app_id" run -f "$manifest" -- \
  /usr/bin/printenv SECRET)"
[[ "$resolved" == "$sentinel" ]] || fail "run did not resolve the stored value"

literal="$("$tmp/keybay-integration" "$app_id" run -f "$manifest" -- \
  /usr/bin/printenv LITERAL)"
[[ "$literal" == "from-manifest" ]] || \
  fail "run did not overlay the manifest literal"

if [[ "$(uname -s)" == "Darwin" ]]; then
  lock_path="$HOME/Library/Application Support/$app_id/secrets.enc.lock"
else
  lock_path="${XDG_DATA_HOME:-$HOME/.local/share}/$app_id/secrets.enc.lock"
fi
ready="$tmp/lock-ready"
python3 tool/hold_cli_lock.py "$lock_path" "$ready" &
holder_pid=$!
for _ in $(seq 1 100); do
  [[ -e "$ready" ]] && break
  sleep 0.05
done
[[ -e "$ready" ]] || fail "lock holder did not become ready"
set +e
busy_output="$(printf 'replacement' | \
  "$tmp/keybay-integration" "$app_id" set --stdin "$key" 2>&1)"
busy_status=$?
set -e
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
[[ $busy_status -eq 75 ]] || \
  fail "live lock contention exited $busy_status, expected 75"
[[ "$busy_output" == *"another live Keybay writer"* ]] || \
  fail "live lock output omitted writer guidance"
[[ "$busy_output" == *"not a stale lock file"* ]] || \
  fail "live lock output omitted stale-file guidance"
resolved_after_busy="$("$tmp/keybay-integration" "$app_id" run -f "$manifest" -- \
  /usr/bin/printenv SECRET)"
[[ "$resolved_after_busy" == "$sentinel" ]] || \
  fail "contended write changed the previously stored value"

"$tmp/keybay-integration" "$app_id" rm "$key"
"$tmp/keybay-integration" "$app_id" rm "$key"
for writer in $(seq 0 $((concurrent_writers - 1))); do
  "$tmp/keybay-integration" "$app_id" rm \
    "keybay-itest/concurrent-$(printf '%02d' "$writer")"
done

set +e
missing_output="$("$tmp/keybay-integration" "$app_id" run -f "$manifest" -- \
  /usr/bin/true 2>&1)"
missing_status=$?
set -e
[[ $missing_status -eq 78 ]] || \
  fail "missing-reference run exited $missing_status, expected 78"
[[ "$missing_output" == *"keybay set $key"* ]] || \
  fail "missing-reference output omitted set remediation"
[[ "$missing_output" == *"Nothing was launched."* ]] || \
  fail "missing-reference output omitted atomicity notice"

"$tmp/keybay-integration" "$app_id" doctor >/dev/null
echo "CLI real-store round trip passed"
