# keybay on iOS

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

**Level reporting.** `describe().level` is **measured, not assumed**: the
library probes for a usable Secure Enclave (it tries to create an ephemeral SE
key) and reports `hardwareBacked` only if that succeeds — the Apple analogue of
Android's `KeyInfo.getSecurityLevel()`. On iOS this is effectively always
`hardwareBacked`, because every Flutter-supported iOS device has a Secure
Enclave and the modern iOS **Simulator emulates one** (so the probe succeeds
there too, matching real-device behaviour). The probe reports `softwareBacked`
only where an SE is genuinely absent — which on Apple means a pre-T2 Intel Mac,
not iOS.

**Validation.** The full round-trip (write/read/enumerate/delete, binary and
unicode values, cross-instance reads) plus the measured level are validated on
the iOS simulator by the `example_flutter/` integration suite. One honest
limit: the simulator's Secure Enclave is emulated in software, so this proves
the keychain **code path** and the SE-probe end-to-end, not that physical
silicon mediated it — a one-time on-device run remains the final confirmation.
