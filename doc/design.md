# secret_store — design

The canonical design document for `secret_store`. It reflects the package as it
is, with the reasoning behind the choices that aren't obvious. (It originated as
RFC 0005 in the dune_cli repo — the pathfinding consumer — and moved here when
the package was extracted.)

---

## 1. Motivation

Storing credential material from a Dart program means handing it to the OS
keystore — macOS Keychain, Linux Secret Service — or, failing that, to an
encrypted file. The community answer, `flutter_secure_storage`, is a Flutter
plugin (platform channels): unusable from a CLI or a server. Python, Go, and
Rust each have a `keyring` library; Dart did not.

`secret_store` fills that gap: pure Dart + FFI, no platform channels, so it runs
in CLIs, servers, and Flutter apps alike. It targets macOS and Linux in v1.

### Why build rather than adopt (surveyed 2026-07-05)

| Candidate | Verdict |
|---|---|
| `flutter_secure_storage` + kin | Flutter plugins — platform channels; unusable off Flutter. |
| `dbus_secrets` | The only pure-Dart Secret Service client: 2 likes, ~141 downloads, unmaintained, plaintext bus session. A useful reference, not infrastructure for DB keys. |
| `keyring` (pub) | Days-old Rust-FFI umbrella, no releases/CI, unspecified native-binary distribution. On the watch-list. |
| macOS Keychain from pure Dart | Nothing exists. |

The gap is real; the build is thin glue over vetted infrastructure
(`package:cryptography`, libc, the OS keystores), not a new subsystem.

## 2. Goals / non-goals

**Goals** — `flutter_secure_storage`-class storage without Flutter (macOS +
Linux); usable from CLIs, servers, and Flutter apps; backends as the extension
seam with honest capability reporting; zero native build artifacts (subprocess +
system-framework FFI only, no toolchain); a minimal, fully-enumerated dependency
and API surface.

**Non-goals (v1)** — Windows/Android/iOS backends (§9 sketches the path);
biometric prompts; change listeners; web; our own crypto primitives; rollback
protection (§8 — a keystore-anchored counter is a possible v2, not carried
today); cross-process write coordination (a container is single-writer — §7).

(An earlier draft brought cross-process locking in-scope via `flock`; it was
cut in the austerity pass — the race it guarded needs two processes writing one
container concurrently, a deployment the consumer controls. See §7
"Concurrency".)

## 3. Architecture

```
SecretStorage            bytes-first async KV; validation; capability guard
     │
SecretBackend  (seam)    KeystoreBackend | EncryptedFileBackend
     │                        │                    │
KeystoreApi (seam)            │              Container (AEAD+TLV)
  MacKeychainApi (SecItem FFI)│              KeySource:
  SecretToolApi (secret-tool) │                SystemKeySource (key in OS keystore)
                              │                TpmKeySource (systemd-creds, headless)
                              └── SecureFileSystem (POSIX FFI: 0600, fsync, atomic)
```

Two seams keep it testable and portable: `SecretBackend` (what storage looks
like to the app) and `KeystoreApi` (what the OS keystore looks like to a
backend). Both have fakes; the real bindings are covered by integration tests.
The core is `dart:io`-free except the file backend and the subprocess runner, so
it can run wherever Dart runs.

## 4. Public API

The `flutter_secure_storage` silhouette (async KV, nullable read, familiar) with
its known warts corrected: **bytes-first** (`Uint8List`, not `String` — values
are key material), configuration at **construction, never per call**, write
**metadata** (`label:`) for keystore UIs, and first-class **diagnostics**
(`describe()`).

**Users express intent, not mechanism.** The public API does *not* let a caller
pick between the two backends — which one to use is the library's per-platform
decision (§9). `KeystoreBackend` / `EncryptedFileBackend` are **not exported**;
"Model A / Model B" are internal vocabulary in this document, not user concepts.
There are exactly three constructors, and the two beyond the default exist only
for the cases that are a *genuine* decision:

```dart
// 1. The secure default — strongest backing the platform offers.
final store = SecretStorage(service: 'myapp');

// 2. Advanced binding override — today: opt an entitled macOS app up to the
//    Data Protection keychain + Secure Enclave (planned). Fails loudly if not
//    entitled; never silently degrades.
final store = SecretStorage(service: 'myapp', api: MacKeychainApi.dataProtection());

// 3. Encrypted file — headless (no keyring), one backup unit, or many secrets.
//    The key source is the one real decision (where the key lives).
final store = SecretStorage.encryptedFile(path: p, keySource: SystemKeySource(...));

// (SecretStorage.withBackend(fake) remains as the test / custom escape hatch.)

await store.write('token', bytes, label: 'API token');
final Uint8List? v = await store.read('token');
await store.writeString('note', 'hello');        // String convenience tier
await store.delete('token');
await store.containsKey('token');

if (store.backend.capabilities.enumeration) {
  await store.readAll(); await store.deleteAll();
}
final info = await store.backend.describe();      // which mechanism? reachable? locked?
```

**Input contract.** `service` and `key` are validated against
`[A-Za-z0-9._/-]{1,120}`; labels allow printable text with spaces but reject
control characters. One identifier grammar across backends beats per-backend
escaping — and it keeps the Linux argv path safe by construction.

**Error hygiene.** Typed `SecretStoreException`s carry key *names* and stable
codes — **never values**, and never raw subprocess output. Names/labels are
non-secret (they appear in keystore UIs); values never leave the container, the
keystore, or process memory.

**Enumeration is a capability, not a promise.** Every backend here supports it,
but the interface treats it as optional so a future direct-items backend that
can't enumerate stays honest rather than throwing after the fact.

## 5. Backends

```dart
abstract interface class SecretBackend {
  BackendCapabilities get capabilities;
  Future<Uint8List?> read(String key);
  Future<bool> contains(String key);
  Future<void> write(String key, Uint8List value, {String? label});
  Future<void> delete(String key);
  Future<Map<String, Uint8List>> readAll();   // if capabilities.enumeration
  Future<BackendInfo> describe();
}
```

| Backend | Platform | Mechanism |
|---|---|---|
| `KeystoreBackend` (macOS) | macOS | `MacKeychainApi` — direct `SecItem` CoreFoundation FFI. Classic login keychain (`kSecUseDataProtectionKeychain: false`), `kSecAttrSynchronizable: false` (a synchronizable item would escrow the key to iCloud). Secrets move as `CFData` — no text protocol on this path. Enumeration via `SecItemCopyMatching`. |
| `KeystoreBackend` (Linux) | Linux | `SecretToolApi` — `secret-tool` over an injectable, timeout-guarded `ProcessRunner`. Secret crosses on **stdin** (never argv), base64-encoded so binary/newlines survive. |
| `EncryptedFileBackend` | anywhere | An authenticated container (§7) sealed by a `KeySource`. |

**The keystore seam is async.** A keystore is an IO boundary: the macOS binding
resolves immediately (synchronous FFI wrapped in a future), the Linux binding
spawns a subprocess with a timeout. One generic `KeystoreApi` /
`KeystoreBackend` / `SystemKeySource` serves both platforms.

**macOS FFI discipline.** CoreFoundation is manually reference-counted — the one
place *we* can write a memory-safety bug. Contained by a tiny scope
(add/copy/update/delete + CF helpers), strict `*Create*`/`CFRelease` pairing (a
tracked ref list freed in `finally`), and a leak-checked integration pass.
`OSStatus` maps to the typed taxonomy (`errSecItemNotFound`,
`errSecInteractionNotAllowed` → locked, `errSecDuplicateItem` → upsert, …).
Writes are add-then-update on duplicate (covers the delete/add race).

**Linux subprocess hygiene.** Every op has a hard timeout (default 15 s):
`secret-tool` has no no-prompt flag and a locked collection spawns a GUI
prompter — over SSH that would hang forever, so on timeout we kill and surface a
typed `KeystoreLocked`. Launch failure → `KeystoreUnreachable`.

Transport is base64 (`dart:convert`) so binary/newlines survive the pipe. The
encode step makes one transient `String` of the encoded secret — a copy the GC
can't zero, but neither can it zero the secret's own `Uint8List`, so a
hand-rolled bytes-only codec bought little and was cut (austerity pass).
Subprocess **output** is a different matter and stays bytes: it can echo secret
material (`lookup` prints the value; `search` echoes stored items; a failed
`store` echoes its stdin), so it is parsed at the byte level, zeroed after use,
and **never attached to an error**.

**macOS headless hygiene.** `MacKeychainApi(nonInteractive: true)` adds
per-call `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`, so an
operation that would need interaction (locked keychain, ACL prompt) fails fast
as `KeystoreLocked` instead of raising a GUI dialog — the per-call,
non-deprecated equivalent of `SecKeychainSetUserInteractionAllowed(false)`
without its process-global blast radius. Default off: an interactive desktop
consumer *wants* the unlock prompt.

**Default resolution** (`SecretStorage(service:)`): macOS → Keychain; Linux with
a reachable Secret Service → that; otherwise **throw with guidance** — never
silently degrade to weaker storage. Consumers opt into fallbacks explicitly.

## 6. Two composition models

These are the two *internal* mechanisms the library composes; they are not a
choice the public API exposes (§4). "A" and "B" are our vocabulary here, not the
caller's — `SecretStorage(service:)` selects A or B per platform, and the
`encryptedFile` constructor is the only place a caller reaches B, and only for
the reasons below.

**A — direct items.** Each secret is its own keystore item. The
`flutter_secure_storage` shape and the default for `SecretStorage(service:)` on
the item-store platforms. Right for an app with a handful of tokens.

**B — wrapped key + container.** One keystore item holds a random 32-byte store
key; the secrets live in an encrypted container sealed by that key. Reached via
`SecretStorage.encryptedFile(...)`.

```dart
final store = SecretStorage.encryptedFile(
  path: '$dir/secrets.enc',
  keySource: SystemKeySource(service: 'myapp/$profileId', api: platformKeystore()),
  contextSalt: utf8.encode(profileId),
);
```

**When to prefer B.** Model A is strictly the smaller surface — no crypto, no
parser, one keystore round-trip per secret, hardware-backed where available.
Reach for B when you have many secrets (Model A's per-item keychain prompts recur
per binary-identity change, e.g. once per SDK upgrade under `dart run`), when you
want one backup unit, or — decisively — when you must run **headless**: a server
has no unlocked keyring, so its store key needs a file/TPM `KeySource` and its
secrets need the container. Swapping the `KeySource` is the only difference
between the desktop and headless configurations. (dune uses B for exactly these
reasons — 9 secrets and a headless `serve` node.)

**B changes the at-rest story on the legacy native stores — but be precise
about how.** Under our no-entitlement constraint the only macOS store we reach
is the classic login keychain: **3DES-CBC** (NIST-disallowed after 2023) under
**PBKDF2-HMAC-SHA1 at ~999 iterations**, so a stolen `login.keychain-db` is
crackable at roughly *login-password* speed (dictionary passwords in seconds).
Linux is no better — gnome-keyring is AES-128-CBC under an ad-hoc
iterated-SHA-256 KDF with only an MD5 check; KWallet's default Blowfish is
weaker still. Model A's secrets sit *directly* in that store, so at rest their
confidentiality is login-password-bounded and their integrity is weak/none.

Model B does three concrete things here; it is worth being exact about which
are real, because the naive "B encrypts better so it's safe" is half-wrong:

- **Integrity — unconditional win.** The container is AEAD, so tampering is
  detected; the legacy keychains have weak or no per-record MAC.
- **Portable-yet-confidential storage.** The secrets can live in a movable /
  backupable file (the container) that stays opaque *as long as its 256-bit
  random key — held separately in the keystore — does not travel with it*.
  Model A cannot put secrets in a file at all; its secrets only ever live
  inside the keychain.
- **A path to hardware the native store can't offer.** Because the key is just
  a `KeySource`, you can hold it in a TPM or Secure Enclave for a genuine
  confidentiality upgrade — which macOS otherwise reaches only via the
  entitlement-gated DP keychain.

What Model B does **not** do (correcting an earlier overstatement in this doc):
it does **not** "neutralize the weak KDF." Against an attacker who has captured
*both* the keystore and the container while the wrapping key lives in that same
legacy keystore, B is login-password-bounded too — cracking the keychain yields
the wrapping key, which opens the container, exactly as cracking it would yield
a Model-A secret directly. The 2^256 strength of the random key only helps when
the container is separated from its key (the portability case above); it does
nothing when both sit on the same stolen disk. The real confidentiality
*upgrade* comes from moving the **key** to hardware (TPM/SE `KeySource`), not
from the container's cipher.

So the rule: on a legacy file-based store (our CLI/`dart run` case, all
mainstream Linux), prefer B for **integrity, one portable backup unit, and as
the seam to a hardware key** — not on the belief that it out-encrypts the login
keychain for a full-disk attacker. And B is a *downgrade* versus Model A on the
**DP keychain + Secure Enclave** (an entitled, signed app), where per-item
hardware gating — non-exportable key, rate-limited, no offline attack — beats
any software container; prefer native A there.

## 7. Container format (`EncryptedFileBackend`)

Whole-store blob, rewritten atomically per mutation:

```
magic "DSS1" | version u8 | cipher u8 | keyCommit(32)
  | nonce(24) | ciphertext | tag(16)
  cipher v1 = XChaCha20-Poly1305
  AEAD key  = HKDF-SHA256(storeKey, salt: contextSalt,
                          info: "secret_store:v1:container" ‖ cipherId)
  keyCommit = HKDF-SHA256(storeKey, salt: contextSalt,
                          info: "secret_store:v1:commit" ‖ cipherId)
  AAD       = magic ‖ version ‖ cipher ‖ keyCommit ‖ contextSalt
  plaintext = binary TLV:
      entryCount u32 | per entry: keyLen u16 · keyUtf8 · labelLen u16 · labelUtf8
                                  · valueLen u32 · valueBytes
```

- **Binary TLV, not JSON.** JSON would route every secret value through
  `jsonDecode` into interned, unzeroable `String`s (defeating the whole
  memory-hygiene stance) and run a general parser on decrypted bytes. TLV keeps
  values as `Uint8List` views end-to-end and is a fixed-layout, bounds-checked
  reader — the direct target of the fuzz test.
- **Key commitment.** XChaCha20-Poly1305 is not key-committing (a ciphertext
  can be crafted to open under two keys — the partitioning-oracle line of
  work). `keyCommit` pins the (storeKey, contextSalt) pair and is compared in
  constant time *before* decryption: "wrong key/context" surfaces as
  `WrongStoreKey`, reliably distinct from "tampered"
  (`AuthenticationFailed`), and multi-key games fail closed. The commit value
  is a PRF output under a uniformly random 256-bit key — it discloses nothing
  and cannot be brute-forced. Its cost is one HKDF + 32 header bytes; its
  primary *delivered* value is the clean error distinction (the attack it
  closes sits at the edge of the threat model), so it is kept as cheap
  defense-in-depth, not billed as load-bearing.
- **No rollback field.** An earlier draft carried a u64 generation counter in
  the AAD "for later"; it was cut in the austerity pass because it bought *no*
  security on its own — a counter bound in the AAD is only tamper-evident, and
  an attacker who restores a whole older container restores its counter too, so
  it verifies (exactly `age`'s situation). Real rollback resistance needs a
  keystore-anchored monotonic counter to compare against; if that is ever built
  it is a versioned **v2** format change (the header carries `version u8`
  precisely so this is clean), not an inert field carried speculatively now.
- **HKDF domain separation.** The raw keystore key is never used directly as the
  AEAD key, so it could later serve other purposes (rotation, per-file keys via
  salt) without cross-protocol reuse. The AEAD and commit derivations use
  disjoint `info` strings.
- **Pinned implementations.** The container constructs `DartXchacha20` /
  `DartHkdf` concretely rather than through the `Xchacha20.poly1305Aead()` /
  `Hkdf()` factories: those resolve via the global mutable
  `Cryptography.instance`, which a host app can swap at runtime (e.g.
  `FlutterCryptography.enable()`) — substituting an implementation the vector
  firewall never ran against.
- **AAD binds identity.** A container moved between profiles (contexts) fails
  the commitment check even under a hypothetically shared key.
- **RNG:** `Random.secure()` (OS CSPRNG) exclusively — nonces and store keys.
- **Atomic, 0600-from-birth, dir-fsync'd.** An exclusive-created (`O_EXCL`)
  temp file in the same directory, `0600` before any content, `fsync`, then
  `rename`, then a best-effort `fsync` of the directory so the rename itself
  survives a power cut. The temp is unlinked on any failure; the parent dir
  must grant no group/other access (created `0700` if absent). Durability
  guarantee: **never torn** — a crash yields the complete previous or the
  complete new store.
- **Concurrency (single-writer).** Operations on one backend instance run
  under an in-process FIFO mutex, so concurrent calls within a process never
  interleave their whole-file read-modify-write (which would drop updates).
  Coordination *across processes* is deliberately out of scope: a container has
  **one writer**. Two processes writing the same container concurrently can
  lose an update or, on first write, both create a store key and leave the
  container sealed under a discarded one. An advisory `flock` was prototyped
  and cut in the austerity pass — it added an FFI binding, a lock-file
  lifecycle, and a `StoreContended` error for a race the common single-writer
  deployment never hits and the consumer can avoid by contract. Bring your own
  lock if you must share a container between writers.
- **Read hardening.** Reads are size-capped (16 MiB), refuse non-regular files
  (a FIFO would block forever), and refuse a group/other-accessible container,
  key file, or store directory (the OpenSSH stance — we only ever create
  `0600`/`0700`, so loose modes mean someone else touched it). The parser is
  total: arbitrary or truncated bytes always produce a typed error, never a
  crash (fuzzed).

**Failure matrix** (each a distinct typed error, so a diagnostics UI can explain
recovery):

| Container | Store key | State | Surfaces as |
|---|---|---|---|
| absent | absent | fresh install | create on first write |
| absent | present | container lost/moved | `ContainerMissing` (recoverable if restored) |
| present | absent | key lost | `StoreKeyMissing` (unrecoverable without a key backup) |
| present | wrong key / wrong context | swap, moved between profiles | `WrongStoreKey` (commitment mismatch, pre-decryption) |
| present | right key, bytes modified | tamper, bit rot, truncation | `AuthenticationFailed` / `ContainerCorrupt` |

## 8. Threat model

**Protects against:** plaintext key material on disk (backup / Time-Machine /
dotfile-sync leaks); offline disk theft without full-disk encryption; other local
*users*; casual disclosure (scrollback; `ps` argv — hence stdin transport).

**Does not protect against:** same-user malware while the keystore is unlocked
(macOS prompts per binary; Linux Secret Service hands secrets to any same-user
process); process-memory disclosure, including **swap** (encrypted by default on
macOS, often not on Linux) and **core dumps** (Dart-heap buffers can't be
zeroed — the package's *native* staging buffers are scrubbed, but plaintext
copies in the GC heap remain); **rollback** to an older genuine container (out
of scope — AEAD is not anti-rollback, and closing it would need a
keystore-anchored monotonic counter, a possible v2); timing side-channels in
pure-Dart crypto (there is no remote oracle — a local-timing attacker is
already same-user); root.

**macOS binary identity (know your trust unit).** Keychain ACLs key on the
*acting binary's* code identity. Under `dart run` that binary is the shared
Dart VM — one "Always Allow" click authorizes **every Dart script the user
ever runs** to read the item silently (the same failure mode as Python
`keyring` #457, where the trust unit is the interpreter). Items in the login
keychain are also 3DES-encrypted at rest (the modern AES-256-GCM store is the
Data Protection keychain, which needs a provisioned, entitlement-carrying
app — unavailable to `dart run` or unsigned CLIs). Production guidance:
`dart compile exe` and sign with a stable Developer ID, so the ACL binds to
*your* application, survives upgrades, and prompts don't recur per rebuild.

**No key escrow, by design.** Losing the keystore item loses the store; recovery,
if needed, belongs a layer up. Secrets never touch environment variables or argv.

The bar is ssh-agent / aws-vault, not an HSM. The `KeySource` seam is where a
TPM / Secure Enclave attaches later without redesign.

## 9. Platform expansion path

iOS reuses the macOS `SecItem` C API almost verbatim. Windows is DPAPI/wincred
(clean FFI). Android is the hard one — Keystore has no NDK C API, so the
no-Flutter route is `package:jni`/`jnigen`. Because this is pure Dart + FFI with
no plugin registration, it also runs inside Flutter apps — the long-term option
to retire `flutter_secure_storage` and share one audited store across surfaces.

### Backend catalog & per-platform security levels

The whole surface is three composable layers, then one policy that picks a
default per platform:

**Security tiers** (effective confidentiality of a stored secret *at rest*,
against an offline/stolen-disk attacker; integrity noted separately because
Model B always adds it):

| Tier | Key protection | Offline-attack resistance |
|---|---|---|
| **S1 hardware** | key non-exportable in secure hardware (Secure Enclave, StrongBox, TEE, TPM) | infeasible — key never leaves hardware, unwrap is rate-limited |
| **S2 software-AEAD, strong key** | modern AEAD; key is full-entropy and held apart (hardware, or a strong external secret) | bounded by that key/secret |
| **S3 legacy keystore** | OS keystore, login-password-derived (macOS 3DES; gnome AES-128-CBC; KWallet Blowfish; Windows DPAPI) | bounded by login password + a weak KDF |
| **S4 key-on-disk** | `0600` file beside the container | ≈ filesystem permissions |
| **S5 ephemeral** | process memory only | n/a — not persisted |

**Building blocks.** Two backends: `KeystoreBackend` (**Model A** — each secret
its own OS-keystore item) and `EncryptedFileBackend` (**Model B** — all secrets
in one XChaCha20-Poly1305 container sealed by a `KeySource` key). One
`KeystoreApi` **binding per OS** — `MacKeychainApi`, `SecretToolApi`, an iOS
`SecItem` binding, `WinCredApi` — and the public `KeySource`s for Model B
(`SystemKeySource`, `TpmKeySource`; the planned `AndroidKeystoreKeySource` /
`DpapiKeySource`). `InMemoryKeySource` and `FileKeySource` exist but are
**internal, not exported** — non-persistent / insecure respectively; a caller
who needs bring-your-own-key or an on-disk key implements `KeySource` directly.

**Per-platform matrix — what we promote, and its tier:**

| Platform | Promoted default | Tier | Opt-in alternatives | Status |
|---|---|---|---|---|
| **macOS** | A — login-keychain items | **S3** (weak integrity) | B + `SystemKeySource` → S3 **+ AEAD integrity + portable file**; B + a caller's on-disk `KeySource` → S4; A on **DP keychain** (`MacKeychainApi.dataProtection()`) → **S1** (signed, entitled apps) | A shipped; DP shipped (success path manual-verify) |
| **Linux** | A — Secret Service items | **S3** (weak integrity) | B + `SystemKeySource` → S3 + integrity + portable; B + a caller's on-disk `KeySource` → S4; B + `TpmKeySource` → **S1** | A + TPM shipped |
| **iOS** | A — DP-keychain items + Secure Enclave | **S1** (per-item access control) | B + `SystemKeySource` → S1 key but whole-store granularity (rarely worth it) | planned |
| **Android** | **B** + `AndroidKeystoreKeySource` (no Model A — Keystore has no general secret-item API) | **S1** key + AEAD container | B + an on-disk key in the app sandbox → S4 (self-test fallback) | planned |
| **Windows** | A — Credential Manager (DPAPI) *or* B (TBD) | **S3** either way | the other of A/B; B + a caller's on-disk `KeySource` → S4 | planned |

Three things this table encodes:

1. **Best-per-platform does *not* multiply the platform surface.** The
   platform-specific code is the `KeystoreApi` binding, and **both models use
   the same binding** — Model A directly, Model B through `SystemKeySource`.
   So promoting A on macOS/Linux/iOS and B on Android is the *same* set of
   bindings composed two ways, not two bespoke stacks. The only genuinely
   extra per-platform code Model B adds is a specialized `KeySource` where the
   wrapping key can't live in the standard keystore: `TpmKeySource` (Linux
   servers), `AndroidKeystoreKeySource` (Android is B-only), `DpapiKeySource`
   (Windows, optional). Net divergence: ~4 bindings we need regardless + one
   platform-independent container + ~3 specialized key sources — justified, not
   a maintenance explosion.
2. **Confidentiality is bounded by key protection, not the container cipher.**
   On the legacy software keystores (macOS/Linux/Windows) A and B are *both*
   login-password/DPAPI-bounded (S3); B's real wins there are AEAD **integrity**
   and a **portable** encrypted file, and its only route to **S1** is a
   **hardware** `KeySource` (TPM/Secure Enclave). S1 is native on iOS and via
   the Keystore on Android. (This corrects the earlier §6 overstatement that B
   "neutralizes the weak KDF" — it does not when key and container share a
   stolen disk.)
3. **Fail-closed, never auto-downgrade.** The default resolver selects the
   promoted config; off a supported platform, or when the keystore is
   unreachable (headless), it **throws with guidance** to compose B + a
   file/TPM `KeySource` explicitly. It never silently drops to a weaker tier.

**Android reliability note (for when that backend lands).** Android Keystore
keys can vanish, and the design must assume it — but our model B wrapping key
is in the *best-case* profile. It is **not** auth-bound
(`setUserAuthenticationRequired` false), so it structurally avoids
`KeyPermanentlyInvalidatedException`, the invalidation-on-lock-reset /
biometric-re-enrollment failure that hits biometric-gated apps. That leaves two
exposures: (1) backup/restore delivering the container's ciphertext to a new
device without the device-bound wrapping key — *fully preventable* by excluding
the container and the wrapped key from Auto Backup / D2D transfer; and (2) a
small spontaneous-OEM-corruption tail (~sub-1% of installs, ~99% Samsung,
correlated with specific firmware and usually OEM-fixed). Both are handled by
the same discipline the whole ecosystem converged on and that our typed-error
stance already fits: surface key loss as a **typed, recoverable** error
(mirroring Android's own `KeyStoreException.isTransientFailure()`), wipe and
re-provision rather than crash or silently wipe, optionally run a Tink-style
live encrypt/decrypt **self-test** and report an `isKeystoreHealthy()` signal,
and document that stored secrets are device-bound and may need re-provisioning.
(Evaluate Google **Block Store** — Play Services, end-to-end-encryptable,
survives device-to-device restore — as an optional home for the *wrapping key*
so a migrated device can recover the container instead of re-provisioning;
cost is a Play Services dependency, so it stays opt-in, not the default.)
The one contract that separates apps that survive from apps that don't:
**never let the keystore be the sole home of irreplaceable data** — which for a
credential store means the caller must have a re-fetch/re-login source of truth.

## 10. Supply chain & security engineering

- **One third-party runtime dependency**, exact-pinned: `cryptography` (verified
  publisher, ~423k weekly downloads), plus `ffi` (dart-lang official, for the
  POSIX shim). The entire runtime closure is `{cryptography, ffi, collection,
  crypto, meta, typed_data}` — everything but `cryptography` is dart-lang
  official. A `dart pub deps --json` snapshot test fails CI if the tree changes;
  CI also runs OSV advisory scanning.
- **Vector firewall.** The pinned crypto is checked against published standard
  vectors (XChaCha20-Poly1305 draft-arciszewski A.3.1, ChaCha20-Poly1305
  RFC 8439 §2.8.2, HKDF-SHA256 RFC 5869, plus empty-AAD/empty-plaintext/
  block-boundary edge properties) in our own suite, so a silently-buggy or
  compromised dependency update can't pass.
- **Narrowed crypto contract.** We call the AEAD with a caller-supplied key
  (HKDF output) and caller-supplied nonce (`Random.secure()`); the dependency's
  own keygen/RNG paths are unused, and the concrete `Dart*` implementations are
  constructed directly so the global `Cryptography.instance` locator can't swap
  them (§7). A 2026-07 source review of the shipped 2.9.0 artifact found the
  ChaCha/Poly1305/HKDF paths sound (donna-16 Poly1305, constant-time tag
  compare, `List<int>` key hygiene end-to-end); the package's known security
  issues live in AES paths this library never calls. Contingency: if
  maintenance decays further, vendor XChaCha20-Poly1305 + HKDF under the same
  vector suite (~600–800 lines against `package:crypto`'s SHA-256). A CI
  canary fails when pub.dev publishes a newer release, so the pin only ever
  moves by reviewed decision — OSV/GHSA coverage of pub.dev is too sparse to
  outsource that judgment to.
- **FFI is the safest category** — fixed-arity libc / Security.framework calls
  over ints and byte buffers, behind seams with fakes. Guard clauses in FFI use
  braces unconditionally (the "goto fail" bug class is a braceless `if` in
  security C).
- **`dart analyze --fatal-infos` clean**, `strict-casts`/`strict-inference`/
  `strict-raw-types`.

## 11. Implementation notes

Non-obvious things the build settled:

- **HKDF comes from `cryptography`, not hand-rolled** — no home-grown crypto,
  and `crypto` stays a purely transitive dependency.
- **A POSIX file shim is unavoidable.** `dart:io` cannot create a file with
  restrictive permissions (it yields `0644`), cannot `fsync`, and cannot
  exclusive-create — so `SecureFileSystem` binds libc `open`/`write`/`fsync`/
  `close`/`mkdir` directly. Trap: `open` is variadic and on **Apple arm64**
  variadic args pass on the stack, so a fixed-arity binding silently produced
  mode-`000` files; the mode must be bound via `VarArgs`. A perms test on the
  real filesystem guards this permanently.
- **macOS enumeration quirk.** `kSecMatchLimitAll` + `kSecReturnData` together
  returns `errSecParam` on the legacy keychain; `getAll` enumerates
  *attributes only* for the account names, then fetches each value singly.
- **`secret-tool` stream/exit-code facts (found by the real integration test,
  not the mock).** Two assumptions the scripted `ProcessRunner` had encoded
  were wrong against real gnome-keyring, and the Docker/CI integration run
  caught both: (1) `secret-tool clear` on a **missing** item exits **1**, not
  0 — so `delete` treats exit 1 as an idempotent no-op (like `get`'s exit-1 →
  null), not a failure; (2) `secret-tool search` prints item bodies (including
  `secret = …`) to **stdout** and the `attribute.account = …` lines to
  **stderr** — so `getAll` parses stderr for account names (and stdout too,
  defensively), then scrubs both. The lesson: a mocked subprocess can only test
  the behavior you *assumed*; the `dbus-run-session` integration tier is what
  pins the behavior that's actually there.
- **Directory ownership.** The parent-dir check enforces `mode & 0o077 == 0`
  (portable); the strict "owned by the current euid" check needs per-platform
  `struct stat` offsets and is a recorded follow-up (a 0700 dir owned by another
  uid is unusable to us anyway — EACCES).
- **Validation errors never echo the value.** `ArgumentError.value` embeds the
  offending value in its message; a caller that transposes `(key, secret)`
  arguments would leak the secret into logs. Identifier/label failures state
  the rule and the length, never the content.
- **Linux Secret Service items are deliberately *not* interoperable** with
  other keyring libraries, and this is a chosen trade, not an oversight. We
  key items on `service` + **`account`** and store the value **base64-encoded**
  (so binary/newlines survive stdin). The de-facto convention used by Python
  `keyring`, `zalando/go-keyring`, and
  the Rust `keyring` crate is `service` + **`username`** with a **plaintext**
  value. So our items won't be found by those tools (different attribute) and
  wouldn't decode usefully if they were (base64, not plaintext), and vice
  versa. We take bytes-safety and no-`String` over cross-tool interop; a caller
  who needs interop should use one of those libraries, not fight ours.

## 12. Decision log

- Standalone package (name `secret_store`; `lockbox` was the runner-up).
- macOS = direct `SecItem` FFI (an earlier `security`-CLI sketch was dropped: its
  stdin protocol was injectable and its stderr echoed values — both classes
  vanish with the direct API; ecosystem precedent — git/docker credential
  helpers, aws-vault — is unanimously direct-API).
- macOS keychain mode = classic login keychain, explicitly
  (`kSecUseDataProtectionKeychain: false`). Researched 2026-07: the SecItem
  path against the file-based keychain is NOT deprecated (only the
  `SecKeychain*` management family is, with no removal timeline), and the Data
  Protection keychain hard-requires provisioning-profile-authorized
  entitlements (`errSecMissingEntitlement` −34018 otherwise) — unusable from
  `dart run` or unsigned CLIs, i.e. most of this library's consumers. An
  aws-vault-style dedicated keychain (own password + auto-lock) and a
  DP-keychain opt-in for signed apps are recorded follow-ups, not defaults.
- Linux = `secret-tool` for v1 (its transport is already stdin); a native D-Bus
  client with the encrypted `dh-ietf1024` session is a recorded follow-up,
  promoted to the 1.0 plan (it also fixes the probe's inability to distinguish
  a fast-failing locked headless collection).
- Container: XChaCha20-Poly1305 with an HKDF-derived key-commitment header
  field, versioned header, HKDF domain separation, profile-bound AAD, binary
  TLV, `Random.secure()` only, fail-closed resolution.
- Concurrency = in-process FIFO mutex only; a container is single-writer across
  processes (cross-process `flock` was prototyped and cut — §7).
- **Intent-first public API (2026-07).** The concrete backends are *not*
  exported; A-vs-B is the library's per-platform decision, not the caller's.
  Three constructors: `SecretStorage(service:, {api})` (secure default; `api`
  is the advanced binding override — its one use is macOS DP opt-in),
  `SecretStorage.encryptedFile(path:, keySource:, …)` (headless / one-file —
  the key source is the one genuine decision), and `.withBackend(…)` (test /
  custom). Rationale: a caller who must choose "backend A or B" is being handed
  a mechanism decision the library is better placed to make; hiding it removes
  a footgun and shrinks the surface to intent.
- **macOS DP = explicit opt-in, not auto-detected.** An earlier iteration
  considered auto-selecting DP-vs-login by introspecting the process
  entitlement. Rejected on austerity + footgun grounds: it makes the *store
  location* depend on a runtime-detected, necessary-not-sufficient signal
  (debug/release flips; misconfig → silent login), for the sake of saving an
  entitled app one line. Deterministic wins: the per-platform default is fixed
  and knowable (login on macOS, DP on iOS since it is the only option there),
  and DP-on-macOS is a one-line `api:` opt-in that fails loudly (−34018) if not
  entitled. No access group is required in the common case (the app's default
  group is implicit — Xcode's Keychain Sharing capability provides the
  entitlement); an access group is an advanced knob for cross-app sharing only.
- **Austerity pass (2026-07).** Cut, on first-principles review against "no
  code for speculative or nice-to-have security": the **generation counter**
  (inert — provided no rollback protection on its own; re-add as a v2 field if
  enforcement is built), the **cross-process `flock`** (surface for a race the
  single-writer contract avoids), the **hand-rolled bytes-only base64 codec**
  (a maintained crypto-adjacent artifact to shave one `String` copy the GC
  can't zero anyway → `dart:convert`), and the **Unicode format/bidi label
  validation** (heavier than the keystore-UI-spoofing threat → plain
  control-char + length check). Kept and reframed: key commitment (cheap
  defense-in-depth + the error distinction), the String conveniences (dropping
  them adds friction for ~zero hygiene gain — the caller's `String` exists
  regardless).
- **Public key-source surface = secure-only (2026-07).** `SystemKeySource` and
  `TpmKeySource` are the exported sources; both are secure. `FileKeySource`
  (plaintext key on disk — a benign name that invites an accidental insecure
  pick) and `InMemoryKeySource` (non-persistent) were **un-exported**: they
  stay in `src/` as the reference impl and the test double. Bring-your-own-key
  / on-disk needs are served by the public `KeySource` interface + exported
  `SecureFileSystem` — so the insecure choice is one a caller writes
  deliberately, never grabs from autocomplete. Also renamed
  `KeystoreKeySource` → `SystemKeySource` (dropped the `Key…Key` stutter).
- Crypto dependency: stay exact-pinned on `cryptography 2.9.0` (2026-07 review:
  latest release; our two primitives are its healthiest code; every known vuln
  is in unused AES paths), construct the `Dart*` implementations directly, CI
  canary forces reviewed bumps, vendoring is the prepared exit.
- Pure Dart, not native: native crypto doesn't compose on an all-Dart secret
  lifecycle and would re-add a toolchain + a second FFI seam. Swap/core-dump
  belong at the OS level in the consuming process (`setrlimit`, encrypted swap).
- Per-platform model = **best-per-platform, not one model everywhere** (see the
  §9 matrix): A on macOS/Linux/iOS (native items), B-only on Android (no
  general Keystore secret-item API), A-or-B on Windows. Justified because both
  models share the same per-OS `KeystoreApi` binding — choosing best-per-platform
  composes the *same* bindings two ways rather than forking a bespoke stack per
  OS, so the divergence is ~3 specialized `KeySource`s, not N stacks. B is also
  offered as an opt-in everywhere (integrity + one portable backup unit + the
  seam to a hardware key). Corrected 2026-07: on the legacy software keystores
  A and B are the *same* confidentiality tier (S3, login-password-bounded) — B's
  edge there is integrity/portability, and S1 comes only from a hardware
  `KeySource`, not from the container cipher.

## 13. Follow-ups (recorded, non-blocking)

Native D-Bus Secret Service client (promoted: planned for 1.0) · strict euid
dir-owner check · rollback protection *if warranted* (a **v2** format with a
keystore-anchored monotonic counter — the generation field was cut, so this is
a deliberate format bump, not a latent switch) · `rotateStoreKey()` · a
`SecretBuffer` type (mlock'd, zero-on-dispose native
memory) as the store key's canonical home · macOS dedicated-keychain mode
(aws-vault style: own password + auto-lock) · a manual/notarized-CI job that
exercises the DP-keychain **success** path (the −34018 refusal path is already
CI-covered; the store-and-read path needs a signed, entitled bundle) ·
attributes-only `contains` (avoid materializing the
value) and keys-only enumeration · Windows/iOS/Android backends · the
`secret-tool` locked/headless exit-code matrix (the probe still can't
distinguish a fast-failing locked collection) · pub publication (trusted
publishing + provenance).

*(Shipped this pass: the `TpmKeySource` — `systemd-creds`, TPM2/host binding,
fail-closed without a TPM — and the Linux `secret-tool` integration test under
`dbus-run-session`, both verified against the real binaries in Docker.)*

**From the 2026-07 ecosystem benchmark** (see
[doc/ecosystem-comparison.md](ecosystem-comparison.md) for the full analysis;
these are the API-surface gaps every mobile/CLI peer has and we don't yet):
security-**backing** reporting in `BackendInfo` (software / OS-keystore / TEE /
StrongBox / Secure Enclave / TPM — the `getSecurityLevel()` / `storage`-field
pattern) · a typed **`KeyInvalidated`** error plus a per-platform key-loss and
uninstall/restore documentation matrix (the ecosystem's #1 production
data-loss source) · **accessibility tier required at construction** for the
future iOS / DP-keychain backend (Valet's model; pinned per-store, never
per-call — per-call accessibility becomes a keychain search filter and orphans
items) · a documented **value-size envelope** per backend (don't hard-enforce
a wrong number — Expo's removed 2048-byte limit is the cautionary tale) ·
`Ambiguous`/multiple-match handling on the Secret Service path (another app can
write a colliding `service`+`account`) · a per-store serial execution queue for
SecItem calls (ends the duplicate-item race class).
