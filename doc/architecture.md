# keyway — architecture

The canonical, current-state architecture. (History and the reasoning behind
individual choices live in `design.md`; this is the austere summary of where we
landed.)

## TL;DR

**Two shapes, one input, zero knobs.** You name your app; the library resolves
the strongest scheme the platform offers:

- Where the platform has a hardware store that holds *arbitrary secrets* —
  Apple's **Secure Enclave** via the Data Protection keychain (iOS; entitled
  macOS apps) — each secret is a **native keychain item**, hardware-gated.
- Everywhere else, every secret lives in **one authenticated encrypted file**
  (XChaCha20-Poly1305 + key commitment) whose 32-byte key lives in the
  platform's best secure store — the desktop OS keystore, or a hardware
  Keystore key on Android.

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
    │                    grammar); the per-platform resolver. The only public type.
    │  (appId → derived file path + keystore identity)
    │
    ├─ KeystoreBackend        native items — Apple Secure Enclave path
    │      │                  (iOS; entitled macOS via the DP probe)
    │      └─ KeystoreApi (per OS)
    │
    └─ EncryptedFileBackend   the encrypted file: XChaCha20-Poly1305 +
           │                  key-commitment header, binary TLV, atomic 0600
           │                  writes, per-location lock. Platform-independent.
           └─ KeySource       where the file's 32-byte key lives:
                  │             desktop login → the OS keystore (SystemKeySource)
                  │             Android      → AndroidKeystoreKeySource
                  │                            (hardware KEK over the pure-FFI
                  │                            JNI shim, API 31+)
                  └─ KeystoreApi (per OS)  store/retrieve ONE key:
                                AppleKeychainApi (SecItem, login or DP mode),
                                SecretToolApi (secret-tool), [Windows: future].
```

Three seams, all with fakes: `SecretBackend` (what storage looks like),
`KeySource` (where the key lives), and `KeystoreApi` (how one OS stores an
item/key). **Both shapes share the same per-OS `KeystoreApi` binding** — native
items use it directly, the file scheme uses it through `SystemKeySource` — so
best-per-platform composes the same bindings two ways rather than forking a
stack per OS.

## Why this shape

- **Hardware for the data wherever the platform can give it.** Apple's DP
  keychain is the one mainstream store that hardware-gates arbitrary secrets
  per item — so there, native items beat any software container and we use
  them. Nothing else qualifies, so nowhere else pays for a second shape.
- **Uniform, integrity-protected at-rest crypto everywhere else — audited
  once.** On the legacy stores (macOS login keychain: 3DES; gnome-keyring:
  AES-128-CBC + ad-hoc KDF; kwallet: Blowfish) our AEAD file adds **integrity**
  and a **portable** encrypted container the native stores can't give. It is
  *not* categorically stronger at rest: when the file's key lives in that same
  legacy keystore and both are captured off one stolen disk, confidentiality is
  login-password-bound just like a native item (cracking the keystore yields the
  key, which opens the container) — the confidentiality upgrade to hardware (S1)
  comes only from moving the key to a TPM/Secure Enclave, not from the container
  cipher (§9; design.md §6). One crypto path to vector-firewall and review.
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

- **At rest:** every secret is XChaCha20-Poly1305-sealed with a key-committing
  header on every platform. A wrong or mismatched key fails closed
  (`WrongStoreKey`) before decryption; tamper fails as `AuthenticationFailed`.
- **The key:** protected by the platform's best available secure storage, gated
  by whatever that store gates on (device unlock; Secure Enclave on Apple). The
  container's confidentiality reduces to the key's protection — so on
  legacy-at-rest platforms, when the key shares a stolen disk with the container,
  it is login-password-bound *just like* storing secrets natively (the AEAD's
  honest wins there are **integrity** and a **portable** backup unit, not more
  confidentiality); on hardware platforms the key is hardware-held and the
  container shares that gate.
- **Fail-closed, never fake it.** No usable key store (a headless box with no
  keyring) → throw with guidance, never a silent insecure fallback.
- **Errors never carry secret values;** identifiers are validated; the Linux
  subprocess transport is bytes-only and scrubbed. (Details in `design.md`.)

## Per-platform resolution

The README's formal table is the reference; the shape summary:

| Platform (context) | Shape | Key store | Status |
|---|---|---|---|
| macOS — CLI / unentitled | encrypted file | login Keychain (`SecItem`) | **shipped** |
| macOS — signed + entitled | **native items** (DP keychain, Secure Enclave) | — (data is the item) | **shipped**; refusal path CI-tested, success path validated end-to-end via the `example_flutter/` harness (local-only, needs signing) |
| Linux — desktop | encrypted file | Secret Service (`secret-tool`) | **shipped** |
| Windows | encrypted file | DPAPI / wincred | future |
| iOS | **native items** (DP keychain, Secure Enclave) | — (data is the item) | **shipped**; round-trip validated on the iOS simulator (`example_flutter/`); on-device Secure-Enclave check pending |
| Android (API 31+) | encrypted file | Android Keystore KEK (TEE / StrongBox) via **pure-FFI JNI** — no plugin, no package:jni (design.md §12) | **shipped**; validated on an API 33 emulator incl. the StrongBox-fallback branch; on-device hardware check pending |
| any, **headless** | — (fails closed) | — | **out of scope** (owner call 2026-07-10) — not safely auto-detectable, needs its own entry point, and no demand yet. A `TpmKeySource` prototype was built + validated, then removed from the tree — design in `headless-implementation-plan.md`, impl in git history. Headless boxes fail closed, typed. |

## What is deliberately NOT here

- **No third shape.** Native items exist *only* where a hardware store holds
  arbitrary secrets per item (Apple's Secure Enclave); the encrypted file
  covers everything else. No per-platform bespoke formats beyond those two.
- **No configuration knobs.** No `keyStore` / `path` / `dataStore` /
  `api` / `nonInteractive` parameters — `appId` is the only input; the file
  path, the keystore identity, and the scheme are derived. (Non-interactive
  keychain behavior is simply always on: a locked keychain fails typed instead
  of raising a GUI prompt.)
- **No insecure fallback.** No key-on-disk option; if there is no secure place
  for the key, we throw.
- **No headless mode at all** (out of scope, owner call 2026-07-10). It cannot
  be safely auto-detected (see `headless-implementation-plan.md` §1), so it
  would need its own explicit entry point — and until there is demand, no
  entry point beats a rarely-used one. Headless boxes fail closed, typed. The
  macOS DP probe is *not* an instance of the auto-detection problem:
  entitlements are baked into the code signature, so the probe is
  deterministic per binary, and every ambiguous outcome fails loud rather
  than switching schemes.
- **No bring-your-own / KMS keys in v1.** The `KeySource` interface is the seam
  if that demand ever appears.

## The Apple note (stated honestly)

Where the Secure Enclave is reachable (iOS; entitled macOS apps), secrets are
**native per-item keychain entries** — the platform convention, hardware bulk
crypto, per-item gating by the OS. Two consequences to know: keychain items
**survive app uninstall** on Apple platforms (documented platform behavior),
and an app that *gains* the entitlement between versions moves its store from
the file to the DP keychain — a one-time re-provision, by design (deterministic
schemes; no silent migration). Where the Enclave is *not* reachable (every
plain CLI, `dart run`), the encrypted file + login-Keychain key is the
documented, OWASP-endorsed envelope pattern; its AEAD adds integrity and a
portable container, though at-rest confidentiality stays login-password-bound
(the key sits in that same login keychain) until the key moves to hardware.
