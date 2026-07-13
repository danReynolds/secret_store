#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keyway-cli-storage.XXXXXX")"
holder_pid=""
app_id=""
fail() {
  echo "$1" >&2
  exit 1
}
cleanup() {
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

dart compile exe packages/keyway_cli/tool/integration_harness.dart \
  -o "$tmp/keyway-integration"

app_id="keyway-cli-itest-${GITHUB_RUN_ID:-$$}"
key="keyway-itest/token"
sentinel="keyway-integration-value-${GITHUB_RUN_ID:-$$}"
manifest="$tmp/.secrets.env"
printf 'LITERAL=from-manifest\nSECRET=kw://%s\n' "$key" >"$manifest"

concurrent_writers=8
writer_pids=()
concurrent_names=()
for writer in $(seq 0 $((concurrent_writers - 1))); do
  suffix="$(printf '%02d' "$writer")"
  concurrent_names+=("CONCURRENT_$suffix")
  printf 'CONCURRENT_%s=kw://keyway-itest/concurrent-%s\n' \
    "$suffix" "$suffix" >>"$manifest"
  printf 'concurrent-%s' "$suffix" | \
    "$tmp/keyway-integration" "$app_id" set --stdin \
      "keyway-itest/concurrent-$suffix" &
  writer_pids+=("$!")
done
writer_failed=0
for writer_pid in "${writer_pids[@]}"; do
  if ! wait "$writer_pid"; then
    writer_failed=1
  fi
done
((writer_failed == 0)) || fail "a concurrent writer failed"

set_output="$(printf '%s' "$sentinel" | \
  "$tmp/keyway-integration" "$app_id" set --stdin "$key")"
[[ -z "$set_output" ]] || fail "set --stdin wrote unexpected output"

list_output="$("$tmp/keyway-integration" "$app_id" list)"
expected_list="$(
  for writer in $(seq 0 $((concurrent_writers - 1))); do
    printf 'keyway-itest/concurrent-%02d\n' "$writer"
  done
  printf 'keyway-itest/token'
)"
[[ "$list_output" == "$expected_list" ]] || \
  fail "list output did not contain the sorted test keys"

concurrent_values="$(
  "$tmp/keyway-integration" "$app_id" run -f "$manifest" -- \
    /bin/sh -c 'for name do /usr/bin/printenv "$name"; done' \
      keyway-concurrent-values "${concurrent_names[@]}"
)"
expected_values="$(
  for writer in $(seq 0 $((concurrent_writers - 1))); do
    printf 'concurrent-%02d\n' "$writer"
  done
)"
[[ "$concurrent_values" == "$expected_values" ]] || \
  fail "concurrent writes did not preserve every value"

resolved="$("$tmp/keyway-integration" "$app_id" run -f "$manifest" -- \
  /usr/bin/printenv SECRET)"
[[ "$resolved" == "$sentinel" ]] || fail "run did not resolve the stored value"

literal="$("$tmp/keyway-integration" "$app_id" run -f "$manifest" -- \
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
  "$tmp/keyway-integration" "$app_id" set --stdin "$key" 2>&1)"
busy_status=$?
set -e
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
[[ $busy_status -eq 75 ]] || \
  fail "live lock contention exited $busy_status, expected 75"
[[ "$busy_output" == *"another live Keyway writer"* ]] || \
  fail "live lock output omitted writer guidance"
[[ "$busy_output" == *"not a stale lock file"* ]] || \
  fail "live lock output omitted stale-file guidance"

"$tmp/keyway-integration" "$app_id" rm "$key"
"$tmp/keyway-integration" "$app_id" rm "$key"
for writer in $(seq 0 $((concurrent_writers - 1))); do
  "$tmp/keyway-integration" "$app_id" rm \
    "keyway-itest/concurrent-$(printf '%02d' "$writer")"
done

set +e
missing_output="$("$tmp/keyway-integration" "$app_id" run -f "$manifest" -- \
  /usr/bin/true 2>&1)"
missing_status=$?
set -e
[[ $missing_status -eq 78 ]] || \
  fail "missing-reference run exited $missing_status, expected 78"
[[ "$missing_output" == *"keyway set $key"* ]] || \
  fail "missing-reference output omitted set remediation"
[[ "$missing_output" == *"Nothing was launched."* ]] || \
  fail "missing-reference output omitted atomicity notice"

"$tmp/keyway-integration" "$app_id" doctor >/dev/null
echo "CLI real-store round trip passed"
