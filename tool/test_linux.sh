#!/usr/bin/env bash
# Run the Linux integration tier locally on ANY machine with Docker (e.g. a
# macOS dev box) — the same tier CI runs: the Secret Service backend against a
# real gnome-keyring under a throwaway D-Bus session. Verified in-repo.
#
#   ./tool/test_linux.sh
#
# The repo is mounted read-only and copied inside the container, so the host's
# .dart_tool is never rewritten with container paths.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec docker run --rm -i -v "$REPO":/src:ro dart:stable bash -s <<'INNER'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq libsecret-tools gnome-keyring dbus >/dev/null
cp -r /src /build && cd /build
dart pub get >/dev/null

# Secret Service via secret-tool, under a throwaway D-Bus session + keyring.
# NB: we deliberately do NOT pre-create ~/.local/share — a bare container lacks
# it, so this exercises the clean-account path where the library creates the
# missing XDG data hierarchy itself (0700).
dbus-run-session -- bash -c '
  eval "$(printf itest | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
  export GNOME_KEYRING_CONTROL
  KEYWAY_INTEGRATION=1 dart test test/secret_service_integration_test.dart
'

# The locked-collection tier, in its OWN session (it locks the login collection
# and can't unlock it again) — the same second step CI runs. The container is
# exactly the throwaway session KEYWAY_LOCKED_TEST demands.
dbus-run-session -- bash -c '
  eval "$(printf itest | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
  export GNOME_KEYRING_CONTROL
  KEYWAY_INTEGRATION=1 KEYWAY_LOCKED_TEST=1 dart test test/secret_service_locked_integration_test.dart
'
INNER
