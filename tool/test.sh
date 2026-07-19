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
(cd packages/keybay && dart test -x integration)
(cd packages/keybay_cli && dart test -x integration)
dart run tool/test_release.dart
./tool/test_cli.sh
echo "==> native OS-keystore integration tier (real keychain/secret-service)"
(cd packages/keybay && KEYBAY_INTEGRATION=1 dart test -t integration)
./tool/test_cli_storage.sh

echo
echo "OK — native tiers green."
echo "Full real-platform matrix (sim/emu/Docker): ./tool/test_e2e.sh [--entitled]"
