# keyway on macOS

macOS has two schemes. The library picks one automatically — once per process,
deterministically, and never by silently degrading.

## How the choice is made

On first use the library attempts a tiny probe write to the **Data Protection
keychain** and reads the result:

- **Success** → the app is signed and carries the Keychain Sharing
  entitlement → [native items](#signed-apps-entitled).
- **`errSecMissingEntitlement` (−34018)** → the normal result for a plain CLI
  or `dart run` → the [encrypted file](#command-line-and-unentitled).
- **Any other error** → it throws. A misconfigured entitlement is surfaced
  loudly, never quietly downgraded.

Entitlements are baked into the code signature, so the outcome is fixed per
binary and cached for the process. The probe writes to a **dedicated internal
service** (outside the `appId` grammar), so it can never collide with — or
delete — one of your secrets. (The full rationale — why a probe rather than
reading the entitlement, and why this is *not* the unsafe kind of
auto-detection — is in [design.md](../design.md).)

**Gaining the entitlement between versions moves the store.** Switching from a
CLI/unentitled build to an entitled one changes the resolved scheme from the
encrypted file to native items — physically different places. The encrypted
file leaves its own on-disk trace (the container), so rather than silently
present an empty store and strand those secrets, an entitled resolve that finds
a pre-existing `~/Library/Application Support/<appId>/secrets.enc` throws a
typed `MigrationRequired` (`from: encryptedFile, to: nativeItems`). Migrate the
secrets across, then remove that file (or the directory) to proceed. (No
separate marker file is kept — the container's existence is the signal, so a
store that was only *opened* under the file scheme but never written never
false-fires. The reverse, a *lost* entitlement, isn't detectable from the
now-unentitled process — it cannot read the abandoned Data Protection items,
which the OS walls off rather than resurfaces.)

## Signed apps (entitled)

Each secret is a **native item in the Data Protection keychain**, encrypted by
the OS with **AES-256-GCM** and gated by the **Secure Enclave**. There is no
separate key and no file — the keychain item *is* the storage. Items are marked
non-synchronizable, so they never escrow to iCloud.

**What this resists.** The key material is sealed in secure hardware and bound
to the device: a stolen disk, laptop, or backup is useless offline — an
attacker needs that exact machine, unlocked.

`describe().level` is **measured**: the library probes for a usable Secure
Enclave (it attempts to create an ephemeral SE key) and reports `hardwareBacked`
only if that succeeds. On Apple-silicon and T2 Macs it does; on a **pre-T2 Intel
Mac**, where the Data Protection keychain falls back to software, the probe
fails and the level is honestly `softwareBacked` — no over-claim. The probe is
fail-safe (any error → `softwareBacked`, the pessimistic direction).

**Validation.** The refusal path (−34018 → the file scheme, with nothing
written as a fallback) is CI-tested on every push. The success path needs a
signed, provisioned bundle CI can't produce; it is validated end-to-end by the
`example_flutter/` host app (Keychain Sharing + a development team → the
resolver picks native items and reports hardware-backed). That leg is local —
the repeatable recipe is [tool/dp_keychain_verification.md](../../tool/dp_keychain_verification.md).

## Command-line and unentitled

Every secret lives in **one authenticated encrypted file** at
`~/Library/Application Support/<appId>/secrets.enc` (mode `0600`, written
atomically). The file is sealed with **XChaCha20-Poly1305** under an
HKDF-SHA256-derived key with a key-commitment header (a wrong key fails closed
*before* decryption, distinct from tampering). The 32-byte file key is stored
in the **login Keychain** via the `SecItem` API — the key never touches disk;
only the encrypted file does.

**What this resists.** The file key sits in the login Keychain under a
login-password-derived key: safe from other local users and casual theft.
Against a stolen disk it is only as strong as the login password — but the data
itself is still modern AEAD, *stronger* at rest than the 3DES the login
Keychain would apply to a secret stored in it directly.

**Validation.** Real login-Keychain round-trips run in CI on every push; the
file scheme is additionally exercised inside a real sandboxed `.app` by the
`example_flutter/` harness.

## Know your trust unit

Keychain ACLs bind to the **acting binary**. Under `dart run` that binary is
the shared Dart VM, so one "Always Allow" authorizes *every* Dart program you
run to read the item silently. For production, `dart compile exe` and sign with
a stable Developer ID — the ACL then binds to your app and survives upgrades. A
locked keychain (SSH, CI) surfaces as a typed error rather than hanging on a
GUI unlock prompt.
