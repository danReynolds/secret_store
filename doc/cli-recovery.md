# Keybay CLI store recovery

This procedure is for an unreadable `keybay-cli` store. It is intentionally
manual: Keybay never deletes or replaces ciphertext it cannot authenticate.

## Before changing anything

1. Stop other Keybay processes.
2. Unlock the login Keychain (macOS) or Secret Service collection (Linux), run
   `keybay doctor`, and retry. A locked Linux collection can look like a
   missing store key.
3. If a backup exists, restore the encrypted container and its matching
   keystore item as a pair. Either half alone is insufficient.

Do not run `keybay set` against an unreadable existing container. It cannot
recover lost key material, and Keybay deliberately fails closed.

## Preserve an abandoned container

If recovery is impossible and you deliberately choose to re-provision, move
the entire application-data directory aside first. Do not delete it:

### macOS

```sh
mv "$HOME/Library/Application Support/keybay-cli" \
  "$HOME/Library/Application Support/keybay-cli.unreadable.$(date +%Y%m%d%H%M%S)"
```

Only after preserving the directory, remove the unmatched login-Keychain item
if it still exists:

```sh
security delete-generic-password -s keybay-cli -a store-key
```

### Linux

```sh
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
mv "$data_home/keybay-cli" \
  "$data_home/keybay-cli.unreadable.$(date +%Y%m%d%H%M%S)"
```

Only after preserving the directory, remove the unmatched Secret Service item
if it still exists:

```sh
secret-tool clear -- service keybay-cli account store-key
```

These commands are destructive to the active store identity. Re-read the
paths and service name before running them. Afterward, `keybay set` provisions
a new store; old ciphertext remains preserved but is unreadable without its
original key.

## Permission failures

Keybay accepts no group/other access on its store:

- directories: `chmod 700 PATH`
- container and lock files: `chmod 600 PATH`

Use the exact path printed by Keybay. Do not weaken the check or move the store
to network storage; atomic replacement and advisory locking require local
application-data storage.

## Scheme migration

`MigrationRequired` means the same app ID now resolves to a different physical
storage scheme. Keep both stores intact. Use the last known working binary to
read each required value only into a deliberately scoped process, write it
through the new binary, verify the application, and only then preserve and
retire the old store. Keybay does not automate this because a wrong migration
decision can strand the only readable copy.
