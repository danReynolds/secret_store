# keyway — design

The canonical design document for `keyway`. It reflects the package as it
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

`keyway` fills that gap: pure Dart + FFI, no platform channels, so it runs
in CLIs, servers, and Flutter apps alike. It ships backends for macOS, Linux,
iOS, and Android (12 / API 31+).

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

**Goals** — `flutter_secure_storage`-class storage without Flutter (macOS,
Linux, iOS, Android); usable from CLIs, servers, and Flutter apps; backends as
the extension seam with honest capability reporting; zero native build artifacts
(subprocess + system-framework FFI only, no toolchain); a minimal,
fully-enumerated dependency and API surface.

**Non-goals (v1)** — Windows backend (§9 sketches the path); headless/server
operation (out of scope — a headless box fails closed; §12); biometric prompts;
change listeners; web; our own crypto primitives; rollback protection (§8 — a
keystore-anchored counter is a possible v2, not carried today).

(Cross-isolate and cross-process write coordination *is* carried, via an
exclusive advisory `flock` around every mutating read-modify-write — see §7
"Concurrency". An earlier draft cut it in the austerity pass and leaned on a
single-writer contract; it was brought back because the first-write key race it
prevents is cheap to close and easy to hit with a spawned isolate.)

## 3. Architecture

```
SecretStorage            bytes-first async KV; validation; capability guard
     │
SecretBackend  (seam)    KeystoreBackend | EncryptedFileBackend
     │                        │                    │
KeystoreApi (seam)            │              Container (AEAD+TLV)
  AppleKeychainApi (SecItem FFI)│              KeySource:
  SecretToolApi (secret-tool) │                SystemKeySource (key in OS keystore)
  Jni shim (Android, pure FFI)│                AndroidKeystoreKeySource (HW KEK)
                              └── SecureFileSystem (POSIX FFI: 0600, fsync, atomic)
```

Two seams keep it testable and portable: `SecretBackend` (what storage looks
like to the app) and `KeystoreApi` (what the OS keystore looks like to a
backend). Both have fakes; the real bindings are covered by integration tests.
`dart:io` is confined to platform and path resolution (the resolver front API,
`app_paths`, the bindings' platform checks), the file backend's POSIX layer,
and the subprocess runner — the container/crypto layer imports none of it, so
that core runs wherever Dart runs.

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
There is **one constructor with one input**, plus the test hatch:

```dart
// The whole production surface. appId is validated traversal-proof (it names
// the derived data directory and the keystore service); the scheme — native
// Secure-Enclave items vs encrypted-file-with-keystore-key — is resolved per
// platform, with the macOS entitled/unentitled split decided by a
// once-per-process DP probe (−34018 → file, quietly; success → native items;
// anything else → loud typed error).
final store = SecretStorage(appId: 'com.example.myapp');

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

**Input contract.** `appId` and `key` are validated identifiers. `appId` is
**traversal-proof** (`[A-Za-z0-9._-]{1,120}`, no `/`, must contain an
alphanumeric — so `.`/`..` are unrepresentable — since it names a derived
directory and the keystore service); `key` is validated against
`[A-Za-z0-9._/-]{1,120}`. Labels allow printable text with spaces but reject
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

| Backend | Where the resolver uses it | Mechanism |
|---|---|---|
| `KeystoreBackend` (native items — Model A) | iOS; entitled macOS (DP probe succeeds) | `AppleKeychainApi` — direct `SecItem` CoreFoundation FFI against the **Data Protection** keychain (Secure Enclave). `kSecAttrSynchronizable: false` (a synchronizable item would escrow the key to iCloud). Secrets move as `CFData` — no text protocol on this path; enumeration via `SecItemCopyMatching`. |
| `EncryptedFileBackend` (Model B) | unentitled macOS / CLI; Linux; Android | An authenticated container (§7) whose 32-byte key is held by a `KeySource` in the platform keystore — **the keystore holds only the key, never the secrets**, so login Keychain / Secret Service are *not* native-item backends here. Key-storage bindings: `AppleKeychainApi` on the classic login keychain (`kSecUseDataProtectionKeychain: false`); `SecretToolApi` on the Secret Service (`secret-tool` over an injectable, timeout-guarded `ProcessRunner`, the key crossing on **stdin** never argv, base64 so binary/newlines survive); `AndroidKeystoreKeySource` (hardware-wrapped key via the pure-FFI JNI shim). |

**The keystore seam is async.** A keystore is an IO boundary: the macOS binding
resolves immediately (synchronous FFI wrapped in a future), the Linux binding
spawns a subprocess with a timeout. One generic `KeystoreApi` /
`KeystoreBackend` / `SystemKeySource` serves both platforms.

**macOS FFI discipline.** CoreFoundation is manually reference-counted — the one
place *we* can write a memory-safety bug. Contained by a tiny scope
(add/copy/update/delete + CF helpers), strict `*Create*`/`CFRelease` pairing (a
tracked ref list freed in `finally`), and a manual ownership audit (an automated
leak-checked integration pass is a recorded follow-up, not yet built).
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

**macOS non-interactive hygiene — always on, no knob.** Every SecItem call
carries `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`, so an
operation that would need interaction (locked keychain, ACL prompt) fails fast
as `KeystoreLocked` instead of raising a GUI dialog — the per-call,
non-deprecated equivalent of `SecKeychainSetUserInteractionAllowed(false)`
without its process-global blast radius. The login keychain auto-unlocks at
login, so a locked keychain is an abnormal state (SSH, manual lock) where a
typed error beats a prompt that may hang forever; one behavior for every
caller. (This was briefly a `nonInteractive:` flag; the knob was cut.)

**Default resolution** (`SecretStorage(appId:)`): macOS → the once-per-process
DP probe picks native Secure-Enclave items (entitled) or the encrypted file +
login-Keychain key (−34018, the normal CLI result), with any other DP failure
thrown loud; Linux with a reachable Secret Service → the encrypted file +
Secret Service key; Android 12+ → the encrypted file + a hardware Keystore
key; otherwise **throw with guidance** — never silently degrade to weaker
storage. Headless is out of scope (§12) and fails closed.

## 6. Two composition models

These are the two *internal* mechanisms the library composes; they are not a
choice the public API exposes (§4). "A" and "B" are our vocabulary here, not
the caller's — the resolver selects A or B per platform (§9); no public
constructor reaches either directly.

**A — direct items.** Each secret is its own keystore item. The
`flutter_secure_storage` shape; the resolver selects it where a hardware store
holds arbitrary secrets per item (the Apple Data Protection keychain).

**B — wrapped key + container.** One keystore item holds a random 32-byte store
key; the secrets live in an encrypted container sealed by that key. The
resolver composes it (derived path, `SystemKeySource` over the platform
binding); there is no public constructor for it — B is a scheme the library
selects, not one the caller assembles.

**When to prefer B.** Model A is strictly the smaller surface — no crypto, no
parser, one keystore round-trip per secret, hardware-backed where available.
Reach for B when you have many secrets (Model A's per-item keychain prompts recur
per binary-identity change, e.g. once per SDK upgrade under `dart run`), when you
want one backup unit, or when the platform's keystore stores *keys*, not blobs
(Android — B is forced there). Historically the decisive B case was headless
(swap in a TPM `KeySource`, everything else unchanged) — headless is out of
scope for now (§12), but the seam it validated is the same one Android's
hardware key source now ships on.

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
  version   = 2 (1 was the pre-release layout without keyCommit; an
              incompatible layout means a version bump, so v1 is rejected as
              "unsupported version" — never misread as a wrong key)
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

The `secret_store:` prefix in the two HKDF info strings is a frozen wire-format
constant predating the package's rename to `keyway` and is never rebranded —
deriving with different info strings re-keys every existing container, so any
change would be a container-format version bump.

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
  it is a versioned format change — a header-version bump, which the `version
  u8` exists precisely to make clean — not an inert field carried
  speculatively now.
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
- **Concurrency (two-layer serialization).** Mutating operations are serialized
  on two layers. First, a FIFO mutex keyed on the **container path** — shared
  across backend instances within one isolate — so concurrent calls in that
  isolate never interleave their whole-file read-modify-write (which would drop
  updates). That mutex is an isolate-local static, so on its own it cannot
  coordinate other isolates or processes. Second, therefore, every mutating
  operation additionally takes an **exclusive advisory `flock`** on a dedicated
  `<container>.lock` file for the duration of its read-modify-write. `flock`
  ownership belongs to the *open file description*, so a fresh descriptor per
  operation excludes other isolates in the same process (which per-process POSIX
  `fcntl` locks would not) **and** other processes — closing both cross-writer
  hazards: a lost update, and two first-writers each minting a store key and
  leaving the container sealed under a discarded one. Acquisition is
  non-blocking with async backoff (the event loop never stalls); a peer that
  holds the lock past the timeout yields a typed `StoreBusy` rather than a
  hang (a crashed holder's lock is released by the OS when its fd closes, so a
  timeout means a *live* wedged peer). The lock file is created `0600`, never
  renamed (the container is what gets atomically replaced, so the lock must sit
  on a stable inode), and reused across operations. Reads are deliberately
  **not** locked: atomic replace means a reader always sees the whole old or
  whole new container, so a read is consistent without one. `flock` is advisory
  and needs a filesystem that supports it — true for local app-data storage. On
  one that does not (a `flock` returning `ENOLCK`/`EOPNOTSUPP`, e.g. some network
  mounts), a mutating operation **fails closed** with `SecureFileError` rather
  than silently proceeding unlocked: a dropped lock is a security downgrade, so
  it surfaces instead of being swallowed.
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
macOS, often not on Linux) and **core dumps** (the package scrubs its *native*
staging buffers, which it can, but key material also transits GC-managed heaps —
the Dart heap, and on Android the intermediate Java arrays passing through the
JNI shim — which a moving collector can relocate or retain, so they can't be
reliably zeroed and are not claimed to be); **rollback** to an older genuine
container (out
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

iOS ships, reusing the macOS `SecItem` C API almost verbatim (loaded from the
process image rather than by absolute-path `dlopen`). Android ships too and was
the hard one — Keystore has no NDK C API, so JNI is unavoidable; the no-Flutter
route is a **hand-rolled ~24-function JNI shim over `dart:ffi`** that discovers
the VM via `libnativehelper`'s `JNI_GetCreatedJavaVMs` (app-exported at API 31+)
— *not* `package:jni`/`jnigen`, which §12 proved unusable off Flutter. Windows
remains DPAPI/wincred (clean FFI), planned. Because this is pure Dart + FFI with
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
**binding per OS** — `AppleKeychainApi` (macOS + iOS), `SecretToolApi`, the
Android JNI shim, `WinCredApi` (planned) — and the internal `KeySource`s for
Model B (`SystemKeySource`, `AndroidKeystoreKeySource`; `DpapiKeySource`
planned). `InMemoryKeySource` and `FileKeySource` exist but are
**internal, not exported** — non-persistent / insecure respectively; a caller
who needs bring-your-own-key or an on-disk key implements `KeySource` directly.

**Per-platform matrix — what we promote, and its tier:**

| Platform | Promoted default | Tier | Opt-in alternatives | Status |
|---|---|---|---|---|
| **macOS** | resolver: entitled → A on **DP keychain** (`AppleKeychainApi.dataProtection()`, **S1**); else B + `SystemKeySource` (key in login Keychain) — **S3 + AEAD integrity + portable file** | **S1 / S3** | none (no public composition) | file scheme shipped + CI-validated; DP success validated via the Flutter harness |
| **Linux** | resolver: B + `SystemKeySource` (key in Secret Service) — **S3 + AEAD integrity + portable file** | **S3** | none (no public composition) | shipped + CI-validated against real gnome-keyring |
| **iOS** | A — DP-keychain items + Secure Enclave | **S1** (per-item access control) | B + `SystemKeySource` → S1 key but whole-store granularity (rarely worth it) | shipped; round-trip validated on the iOS simulator (Secure-Enclave hardware check pending on-device) |
| **Android** (API 31+) | **B** + `AndroidKeystoreKeySource` (no Model A — Keystore has no general secret-item API); pure-FFI JNI, no plugin (§12) | **S1** key + AEAD container | none — key loss is loud (`KeyInvalidated`), no software fallback | shipped; emulator-validated incl. StrongBox fallback + write-time self-test |
| **Windows** | A — Credential Manager (DPAPI) *or* B (TBD) | **S3** either way | the other of A/B; B + a caller's on-disk `KeySource` → S4 | planned |

Three things this table encodes:

1. **Best-per-platform does *not* multiply the platform surface.** The
   platform-specific code is the `KeystoreApi` binding, and **both models use
   the same binding** — Model A directly, Model B through `SystemKeySource`.
   So promoting A on entitled-Apple and B elsewhere is the *same* set of
   bindings composed two ways, not two bespoke stacks. The only genuinely
   extra per-platform code Model B adds is a specialized `KeySource` where the
   wrapping key can't live in the standard keystore: `AndroidKeystoreKeySource`
   (Android is B-only), `DpapiKeySource` (Windows, planned). Net divergence:
   the bindings we need regardless + one platform-independent container + ~2
   specialized key sources — justified, not a maintenance explosion.
2. **Confidentiality is bounded by key protection, not the container cipher.**
   On the legacy software keystores (macOS/Linux/Windows) A and B are *both*
   login-password/DPAPI-bounded (S3); B's real wins there are AEAD **integrity**
   and a **portable** encrypted file, and its only route to **S1** is a
   **hardware** `KeySource` (TPM/Secure Enclave). S1 is native on iOS and via
   the Keystore on Android. (This corrects the earlier §6 overstatement that B
   "neutralizes the weak KDF" — it does not when key and container share a
   stolen disk.)
3. **Fail-closed, never auto-downgrade.** The resolver selects the promoted
   config; off a supported platform, or when the keystore is unreachable
   (e.g. a headless box), it **throws typed guidance**. It never silently
   drops to a weaker tier, and there is no public composition to fall back
   onto — an unsupported environment is an error, not a knob.

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
  (Renamed `keyway` 2026-07-12, pre-publish — never released as `secret_store`;
  naming record in cli-implementation-plan.md Appendix B. The container's HKDF
  info strings keep the frozen `secret_store:` wire prefix — §7.)
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
- Concurrency = isolate-local FIFO mutex **plus** an exclusive advisory `flock`
  around every mutating read-modify-write, so writers are serialized across
  isolates and processes alike; reads stay lock-free (atomic replace — §7).
- **Intent-first public API (2026-07, tightened twice).** The concrete
  backends are *not* exported; A-vs-B is the library's per-platform decision,
  not the caller's. First iteration kept three constructors (`service:` +
  `api:` override, `encryptedFile(path:, keySource:)`, `withBackend`); the
  final austerity pass collapsed to **one production constructor,
  `SecretStorage(appId:)`** — path, keystore identity, and scheme all derived
  — plus `withBackend` (tests) and a then-planned `.headless(appId:)` (since
  descoped — see the headless entry below). Cut with
  it: the `api:` knob, the public `encryptedFile` composition, `contextSalt`,
  the `nonInteractive` flag (now unconditionally on: a locked keychain fails
  typed instead of raising a GUI prompt), and the exported key-source/binding
  surface. Rationale: every removed knob was a way to hold the library wrong.
  `appId` is validated **traversal-proof** (no `/`, must contain an
  alphanumeric — so `.`/`..` are unrepresentable), because it now names a
  derived directory.
- **macOS DP = auto-probe with fail-loud (2026-07; supersedes the earlier
  "explicit opt-in" decision).** First ruling rejected auto-detection because
  an *entitlement-claim* check is necessary-not-sufficient and a
  detection-driven store location risks silent scheme flips. Revisited and
  reversed on the owner's call — "use the Secure Enclave where possible; if
  the DP write fails, fail loud" — because the probe as built avoids both
  original objections: it tests the **actual capability** (a real DP write,
  not an entitlement-claim read), it is **deterministic per binary**
  (entitlements are baked into the code signature; the result is cached
  per-process), and it is **three-way precise** on the raw OSStatus: −34018 →
  file scheme, quietly (the normal CLI branch, CI-tested live); success →
  native DP items; anything else → loud typed error, never a silent
  downgrade. Accepted residual, documented: an app that *gains* the
  entitlement between versions moves its store (one-time re-provision) —
  deliberate-developer-action, recoverable, and preferred over carrying a
  public knob. No access group is required (the app's implicit default group
  suffices; Xcode's Keychain Sharing capability provides the entitlement).
- **Austerity pass (2026-07).** Cut, on first-principles review against "no
  code for speculative or nice-to-have security": the **generation counter**
  (inert — provided no rollback protection on its own; re-add as a v2 field if
  enforcement is built), the **cross-process `flock`** (*later reinstated* —
  the first-write key race it prevents proved cheap to close and easy to hit
  with a spawned isolate; see §7), the **hand-rolled bytes-only base64 codec**
  (a maintained crypto-adjacent artifact to shave one `String` copy the GC
  can't zero anyway → `dart:convert`), and the **Unicode format/bidi label
  validation** (heavier than the keystore-UI-spoofing threat → plain
  control-char + length check). Kept and reframed: key commitment (cheap
  defense-in-depth + the error distinction), the String conveniences (dropping
  them adds friction for ~zero hygiene gain — the caller's `String` exists
  regardless).
- **Public key-source surface = secure-only (2026-07).** `SystemKeySource` and
  `TpmKeySource` were the exported sources at the time; both secure. (Both
  since un-exported by the appId surface; `TpmKeySource` later removed with
  headless's descoping — see below.) `FileKeySource`
  (plaintext key on disk — a benign name that invites an accidental insecure
  pick) and `InMemoryKeySource` (non-persistent) were **un-exported**: they
  stay in `src/` as the reference impl and the test double. Bring-your-own-key
  / on-disk needs are served by the public `KeySource` interface + exported
  `SecureFileSystem` — so the insecure choice is one a caller writes
  deliberately, never grabs from autocomplete. Also renamed
  `KeystoreKeySource` → `SystemKeySource` (dropped the `Key…Key` stutter).
- **Android = pure-FFI JNI in core, no `package:jni`, no companion package
  (2026-07-10; supersedes both the jnigen plan and an interim "federation is
  forced" recommendation).** The chain of evidence: Android Keystore is
  Java-only (no NDK C API — android/ndk#1284 unfulfilled), so JNI is
  unavoidable; `package:jni` requires the Flutter SDK to resolve (proven in
  Flutter-less Docker: "version solving failed") and cannot drop that
  constraint (pub's publish validator forces `environment: flutter:` onto any
  package with a plugin section — proven by dry-run publish; jni needs its
  plugin section for its Java bootstrap); pub has no optional/conditional
  dependencies. The near-miss: we almost shipped a `secret_store_android`
  companion. The owner challenged it; deep research + local probes found the
  escape: **API 31+ officially exports `JNI_GetCreatedJavaVMs` from
  `libnativehelper` to apps** (android/ndk#1320), so a dlopen'd pure-`dart:ffi`
  caller discovers the VM with no `JNI_OnLoad`/Java/plugin, and every class
  Keystore needs is on the **boot classpath** — sidestepping the
  app-classloader blocker that stalls the Dart team's own de-Flutter migration
  of package:jni (dart-lang/native#2997 / #1350; they ship custom Java, we
  ship none). Proven end-to-end on an API 33 emulator by a standalone probe,
  deleted once the production shim shipped (one JNI implementation only — the
  harness suite now exercises the full chain every run). Consequences:
  **min API 31** on Android (below → typed fail-closed error), a ~24-function
  hand-rolled JNI shim in the CF-binding austerity class (hand-roll over
  vendoring jni's ~230-function generated layer: smaller, and consistent with
  the base64/CF precedent — prefer SDK-maintained, else own the smallest
  surface), and a recorded **off-ramp**: re-evaluate official jni when
  dart-lang/native#2997 lands. Rejected en route: linker-namespace bypass via
  `dl_iterate_phdr` ELF-scanning (platform-hardening circumvention — wrong
  posture for a security package), `app_process` child JVM (SELinux/OEM
  roulette), keystore2-AIDL-direct (private platform surface).
- **Headless/TPM = out of scope; prototype removed (2026-07-10, owner call).**
  A `TpmKeySource` (store key wrapped by `systemd-creds`, host/TPM2 binding,
  fail-closed without a TPM) was built and validated against the real binary
  in Docker/CI, staged for a `SecretStorage.headless(appId:)` entry point.
  With headless descoped, it sat in `lib/` **unreachable from any public
  path** — and the austerity audit's own rule applied: unreachable code in a
  security package is unjustified surface. Removed from the tree (source,
  tests, CI leg); the design survives in headless-implementation-plan.md and
  the implementation in git history. Headless boxes fail closed with typed
  guidance. Re-adding is a contained change on the same `KeySource` seam
  Android now ships on.
- **Review hardening (2026-07-11).** An external review found lifecycle and
  reporting defects (the crypto core held up); fixes, each now tested:
  - *Truthful security level.* `describe().level` is **measured**, not assumed.
    Added `SecurityLevel.softwareBacked`; the level moved onto the `KeySource`
    (it knows where the key lives). Android reads `KeyInfo.getSecurityLevel()`
    → `hardwareBacked` only for TEE/StrongBox, else `softwareBacked`. Apple
    **native items** are also **measured**, not assumed: a fail-safe probe
    tries to create an ephemeral Secure-Enclave key and reports
    `hardwareBacked` only on success. The real over-claim this fixes is an
    entitled app on a **pre-T2 Intel Mac** (no SE → software fallback), which
    now honestly reports `softwareBacked`. (An earlier attempt to detect the
    iOS Simulator via `SIMULATOR_*` env vars failed — they're absent under
    `flutter test` — and it turned out moot: the modern Simulator *emulates*
    the SE, so the probe succeeds there and reports `hardwareBacked`, matching
    a real device.)
  - *No silent store migration on macOS.* No marker file: the encrypted-file
    scheme leaves its own trace (the container), so an entitled resolve that
    finds a pre-existing container throws typed `MigrationRequired`
    (`encryptedFile → nativeItems`) rather than presenting an empty store. A
    never-written store has no container, so it never false-fires; the reverse
    (lost entitlement) is not detectable from an unentitled process, which
    can't read the OS-walled DP items. (An interim `.scheme` marker was tried
    and removed — it could false-fire on a never-written store and threw
    untyped on a corrupt/loose marker.)
  - *No bricking, no lost updates.* `write` rejects an oversized sealed
    container (`StoreTooLarge`) **before** replacing the prior one; the
    read-modify-write mutex is keyed by container **path** so two backend
    instances for one store serialize.
  - *Smaller blast radius on the edges.* The DP probe uses a dedicated internal
    service (outside the `appId` grammar) and deletes only its own item;
    `secret-tool` gets a `--` terminator so a dash-leading `appId` is data not
    a flag; the XDG data hierarchy is created `0700` on a clean account; the
    POSIX errno symbol is resolved across libcs (glibc/musl `__errno_location`,
    bionic `__errno`).
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

*(Shipped this pass: the Linux `secret-tool` integration test under
`dbus-run-session`, verified against the real binaries in Docker. A
`TpmKeySource` was also built and validated here, then removed when headless
was descoped — see §12.)*

**From the 2026-07 ecosystem benchmark** (see
[doc/ecosystem-comparison.md](ecosystem-comparison.md) for the full analysis;
these are the API-surface gaps the benchmark found; since-closed ones are
marked "(shipped)"): security-**backing** reporting in `BackendInfo` (software
/ OS-keystore / TEE / StrongBox / Secure Enclave / TPM — the
`getSecurityLevel()` / `storage`-field pattern) (shipped: the measured
`SecurityLevel` on `BackendInfo`) · a typed **`KeyInvalidated`** error plus a
per-platform key-loss and uninstall/restore documentation matrix (the
ecosystem's #1 production data-loss source) (shipped: `KeyInvalidated` + the
doc/platforms/ matrix) · **accessibility tier required at construction** for
the future iOS / DP-keychain backend (Valet's model; pinned per-store, never
per-call — per-call accessibility becomes a keychain search filter and orphans
items) · a documented **value-size envelope** per backend (don't hard-enforce
a wrong number — Expo's removed 2048-byte limit is the cautionary tale) ·
`Ambiguous`/multiple-match handling on the Secret Service path (another app can
write a colliding `service`+`account`) · a per-store serial execution queue for
SecItem calls (ends the duplicate-item race class).
