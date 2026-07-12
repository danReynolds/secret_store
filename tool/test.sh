#!/usr/bin/env bash
# Local pre-push regression suite: everything runnable NATIVELY on this machine
# — the same checks CI runs, minus the ones that need another OS or signing.
#
#   ./tool/test.sh
#
# Also run, separately:
#   ./tool/test_linux.sh                 # Linux Secret Service tier (Docker)
#   tool/dp_keychain_verification.md     # macOS Data Protection keychain (manual)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> format"
dart format --output=none --set-exit-if-changed .
echo "==> analyze (--fatal-infos)"
dart analyze --fatal-infos
echo "==> unit tier"
dart test -x integration
echo "==> native OS-keystore integration tier (real keychain/secret-service)"
KEYWAY_INTEGRATION=1 dart test -t integration

echo
echo "OK — native tiers green."
echo "Full real-platform matrix (sim/emu/Docker): ./tool/test_e2e.sh [--entitled]"
