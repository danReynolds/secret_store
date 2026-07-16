# keybay — architecture

The canonical, current-state architecture. The reasoning behind individual
choices lives in `design.md`; this is the austere summary of where we landed.

## TL;DR

**Two shapes, one input, zero knobs.** You name your app; the library resolves
the fixed, platform-appropriate scheme for Keybay's threat model:

- On iOS and entitled macOS apps, each secret is a **native Data Protection
  Keychain item** with a fixed device-bound, non-synchronizing accessibility
  policy. Keybay does not attest or report a hardware-backing level for these
  items.
- On the other supported paths—unentitled macOS, Linux desktop, and Android—
  every secret lives in **one authenticated encrypted file**
  (XChaCha20-Poly1305 + key commitment). Its 32-byte key lives in the desktop
  OS credential store or is wrapped by Android Keystore. The Android key's
  actual security level is inspected rather than assumed.

No per-platform secret formats beyond those two, no configuration knobs, no
fallbacks. The macOS choice between them is automatic (a once-per-process Data
Protection probe: −34018 → the file scheme, quietly — the normal CLI result;
success → native items; anything else → a loud typed error, never a silent
downgrade).

```dart
final store = SecretStorage(appId: 'com.example.myapp');
await store.writeString('token', 's3cr3t');
final t = await store.readString('token');
final info = await store.backend.describe();   // which scheme + SecurityLevel
```

## The layers

```
SecretStorage            bytes-first async KV; appId validation (traversal-proof
    │                    grammar); the per-platform resolver. Primary entry point.
    │  (appId → derived file path + keystore identity)
    │
    ├─ KeystoreBackend        native items — Apple Data Protection Keychain
    │      │                  (iOS; entitled macOS via the DP probe)
    │      └─ KeystoreApi (per OS)
    │
    └─ EncryptedFileBackend   the encrypted file: XChaCha20-Poly1305 +
           │                  key-commitment header, binary TLV, atomic 0600
           │                  writes, per-location lock. Platform-independent.
           └─ KeySource       where the file's 32-byte key lives:
                  │             desktop login → the OS keystore (SystemKeySource)
                  │             Android      → AndroidKeystoreKeySource
                  │                            (Keystore KEK over the pure-FFI
                  │                            JNI shim, API 31+)
                  └─ KeystoreApi (per OS)  store/retrieve ONE key:
                                AppleKeychainApi (SecItem, login or DP mode),
                                SecretToolApi (secret-tool), [Windows: future].
```

Three seams, all with fakes: `SecretBackend` (what storage looks like),
`KeySource` (where the key lives), and `KeystoreApi` (how one OS stores an
item/key). **Both shapes share the same per-OS `KeystoreApi` binding** — native
items use it directly, the file scheme uses it through `SystemKeySource` — so
the platform policy composes the same bindings two ways rather than forking a
stack per OS.

## Why this shape

- **Native item storage where the platform provides it.** Apple's Data
  Protection Keychain holds arbitrary secret items and supplies device-bound
  accessibility and access-group policy, so Keybay uses it directly rather than
  layering a second container over it.
- **Uniform, integrity-protected at-rest crypto everywhere else — audited
  once.** On the legacy stores (macOS login keychain: 3DES; gnome-keyring:
  AES-128-CBC + ad-hoc KDF; kwallet: Blowfish) our AEAD file adds **integrity**
  and a **portable** encrypted container the native stores can't give. It is
  *not* categorically stronger at rest: when the file's key lives in that same
  legacy keystore and both are captured off one stolen disk, confidentiality is
  login-password-bound just like a native item (cracking the keystore yields the
  key, which opens the container) — hardware resistance comes only when the
  wrapping key is actually reported in hardware, not from the container cipher.
  One crypto path to vector-firewall and review.
- **Minimal per-platform code.** Per OS, the binding is "put/get small items"
  — shared by both shapes. No second stack.
- **Android-native.** Android's Keystore is a *key* store, not a secret store;
  the file shape is the only one that works there, so it removes a special
  case rather than adding one.
- **Future key homes are a one-class difference.** Anything new (a TPM for
  headless, DPAPI for Windows) is *only* a `KeySource`/binding over the shared
  container — never a second architecture. (A TPM key source was prototyped
  and validated on exactly this seam, then removed with headless's descoping.)

## Security model

- **At rest:** Apple native-item paths delegate confidentiality and integrity to
  the Data Protection Keychain. File paths use XChaCha20-Poly1305 with a
  key-committing header: a wrong or mismatched key fails closed
  (`WrongStoreKey`) before decryption; tamper fails as `AuthenticationFailed`.
- **The file key:** held by the selected desktop credential store or wrapped by
  Android Keystore. The container's confidentiality reduces to that key's
  protection — so on
  legacy-at-rest platforms, when the key shares a stolen disk with the container,
  it is login-password-bound *just like* storing secrets natively (the AEAD's
  honest wins there are **integrity** and a **portable** backup unit, not more
  confidentiality). Android reports `hardwareBacked` only when platform
  inspection returns TEE or StrongBox; software-backed providers remain
  possible and are reported as such.
- **Fail-closed, never fake it.** No usable key store (a headless box with no
  keyring) → throw with guidance, never a silent insecure fallback.
- **Errors never carry secret values;** identifiers are validated; the Linux
  subprocess keeps values off argv, captures output as bytes, and scrubs
  buffers after use. (The input is transient base64 text on stdin; details in
  `design.md`.)

## Per-platform resolution

The [SDK guide's formal table](sdk.md#how-your-secrets-are-protected) is the
reference; the shape summary:

| Platform (context) | Shape | Key store | Status |
|---|---|---|---|
| macOS — CLI / unentitled | encrypted file | login Keychain (`SecItem`) | **shipped** |
| macOS — signed + entitled | **native items** (Data Protection Keychain) | — (data is the item) | **shipped**; fixed device-bound policy; hardware backing not attested; refusal path CI-tested and success path exercised via the signed `example_flutter/` harness |
| Linux — desktop | encrypted file | Secret Service (`secret-tool`) | **shipped** |
| Windows | encrypted file | DPAPI / wincred | future |
| iOS | **native items** (Data Protection Keychain) | — (data is the item) | **shipped**; fixed device-bound policy; hardware backing not attested; round-trip exercised on the iOS simulator (`example_flutter/`) |
| Android (API 31+) | encrypted file | Android Keystore KEK via **pure-FFI JNI** — StrongBox requested, actual level inspected | **shipped**; validated on an API 33 emulator incl. the StrongBox-fallback branch; physical hardware mediation not established by emulator testing |
| **headless deployment** | no dedicated shape | no dedicated provider | **out of scope** (owner call 2026-07-10). The desktop resolver may still reach a configured desktop credential service, but there is no supported availability contract. A TPM prototype and its rationale remain in `headless-implementation-plan.md` and git history. |

## What is deliberately NOT here

- **No third shape.** Native items exist where the Data Protection Keychain
  stores arbitrary secrets; the authenticated file covers everything else. No
  per-platform bespoke formats beyond those two.
- **No configuration knobs.** No `keyStore` / `path` / `dataStore` /
  `api` / `nonInteractive` parameters — `appId` is the only input; the file
  path, the keystore identity, and the scheme are derived. (Non-interactive
  keychain behavior is simply always on: a locked keychain fails typed instead
  of raising a GUI prompt.)
- **No insecure fallback.** No plaintext key-on-disk option; if there is no secure place
  for the key, we throw.
- **No dedicated headless mode** (out of scope, owner call 2026-07-10). It
  cannot be safely auto-detected (see `headless-implementation-plan.md` §1), so
  it would need its own explicit entry point — and until there is demand, no
  entry point beats a rarely-used one. A headless process can still encounter
  the desktop resolver; if its credential service is absent or locked, the
  operation fails typed. The macOS DP probe is *not* an instance of the
  auto-detection problem:
  entitlements are baked into the code signature, so the probe is
  deterministic per binary, and every ambiguous outcome fails loud rather
  than switching schemes.
- **No bring-your-own / KMS keys in v1.** The `KeySource` interface is the seam
  if that demand ever appears.

## The Apple note (stated honestly)

On iOS and entitled macOS apps, secrets are **native per-item Data Protection
Keychain entries**. Keybay uses
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: items do not migrate to a
different device, but after the first unlock following boot they remain
available when the device relocks. They are non-synchronizing. A separate
hardware-backing level is deliberately omitted because Keybay cannot attest it.

Two lifecycle consequences matter: Apple Keychain items commonly persist after
app uninstall, but Apple does not document that as a contract, so applications
must not depend on either persistence or automatic deletion. A macOS app that
gains the entitlement between versions moves from the file scheme to Data
Protection Keychain items. Keybay surfaces the existing file as
`MigrationRequired` instead of silently presenting an empty store. Plain CLIs
and `dart run` use the authenticated file plus a login-Keychain key; AEAD adds
integrity and a portable container, while at-rest confidentiality remains
login-password-bound.
