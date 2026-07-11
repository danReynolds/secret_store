# secret_store on iOS

Each secret is a **native item in the Data Protection keychain**, encrypted by
the OS with **AES-256-GCM** and gated by the **Secure Enclave**. There is no
separate key and no file — the keychain item *is* the storage.

Unlike macOS, there is **no probe**: the Data Protection keychain is the only
keychain on iOS, and every app can use it (via the default access group every
signed app carries). So the scheme is unconditional.

**Item policy.** Items are created
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable by background work
after the first unlock following a boot, never migrated to another device, and
never escrowed to iCloud (`synchronizable = false`).

**What this resists.** The secret is sealed in secure hardware and bound to the
device: a stolen device backup or a restore onto different hardware cannot
decrypt it — an attacker needs that exact device, unlocked.

**Note — uninstall.** On Apple platforms, keychain items survive app
uninstall. For a secrets library this is usually what you want (tokens persist
across a reinstall), so the library does not wipe on first run; if you need
wipe-on-fresh-install, clear the store yourself on a first-launch sentinel.

**Requirements.** Runs inside a Flutter iOS app. Being pure Dart + FFI, it
pulls in **zero CocoaPods plugins**.

**Level reporting.** `describe().level` is `hardwareBacked` — the accurate
platform-mechanism claim, since every current iOS device has a Secure Enclave.
Unlike Android's Keystore (which exposes `KeyInfo.getSecurityLevel()`), the DP
keychain has no per-item hardware-residency query, and the one non-SE context —
the **Simulator** — is not reliably detectable from pure Dart FFI (the
`SIMULATOR_*` environment variables are absent in the app process). So the
simulator reports `hardwareBacked` too; treat it as the mechanism claim, with
the actual silicon check being the pending on-device run below.

**Validation.** The full round-trip (write/read/enumerate/delete, binary and
unicode values, cross-instance reads) is validated on the iOS simulator by the
`example_flutter/` integration suite. One honest limit: a simulator has no real
Secure Enclave, so this proves the keychain **code path** end-to-end, not that
physical silicon mediated it — the hardware property itself is pending a
one-time on-device run.
