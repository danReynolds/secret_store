# keybay — security & best-practice research agenda

Input for a deep research pass over the package as of `ba8b918`. Each item says
what to research, why (tied to the code as it stands), and what a good answer
looks like. Items marked **[code fact]** are observations from reading the
implementation that the research should confirm, contextualize, or turn into a
fix decision.

> **Status (2026-07-06, hardening pass):** resolved in code — §4 key
> commitment + generation field (format amended pre-publication), §5 native
> staging buffers zeroed, §6 read-side perm checks + dir-fsync, §7 in-process
> mutex + flock, §9 no-echo errors + Unicode label rules, §10 SHA-pinned
> actions + pin canary (the osv-scanner reference was found dangling and
> fixed), §13 partial (RFC 8439 vector + AEAD edge tests; fuzz corpus and the
> dbus harness remain), §14 all fixed except attributes-only `contains`
> (recorded follow-up). Resolved by targeted research — §1 `package:
> cryptography` (stay pinned at 2.9.0; `Dart*` implementations now constructed
> directly, bypassing the swappable `Cryptography.instance`; vendoring is the
> prepared exit), §2 macOS keychain mode (legacy login keychain confirmed the
> right default; `dart run` ACL trust-unit and 3DES-at-rest confirmed and now
> documented; `nonInteractive` fail-fast mode added; dedicated-keychain and
> DP-keychain opt-ins recorded as follow-ups). Still open for future research/
> work — §3 Secret Service behavior matrix (answer empirically via the
> dbus-run-session harness), §8 rollback enforcement design, §5 SecretBuffer
> (mlock'd native key memory), §11 remaining platform-claim verifications,
> §12 ecosystem benchmarking.
>
> **Post-austerity correction (later pass):** two of the "resolved in code"
> items above were subsequently *cut* — the §7 cross-process `flock` (locking
> is out of scope now; the in-process mutex is the only serialization) and the
> §9 Unicode label rules (labels are now control-char + length checks only).
> (The §4 generation field was likewise removed — see design.md §7/§12.)

---

## 1. `package:cryptography` — the single third-party dependency

The whole container's confidentiality rests on `cryptography 2.9.0` (exact-pinned,
pure Dart). The vector firewall (`test/crypto_vectors_test.dart`) catches a
*wrong* implementation but not a *leaky* or *partially wrong* one.

- **Maintenance and ownership status as of 2026.** The package has a history of
  maintainer churn and community forks (e.g. `cryptography_plus`). Who controls
  the pub.dev publisher today? Release cadence? Open security issues? Is the
  right move to stay pinned, switch to a maintained fork, or vendor
  XChaCha20-Poly1305 + HKDF under the existing vector suite (the design doc's
  stated contingency)?
- **Known bug history for its AEAD paths** — past GitHub issues/advisories about
  `Xchacha20.poly1305Aead()`, especially edge cases the single
  draft-arciszewski A.3.1 vector doesn't cover: empty plaintext, empty AAD,
  block-boundary lengths. Decide whether to widen the in-repo vector set
  (RFC 8439 §2.8.2, Project Wycheproof vectors).
- **Constant-time MAC verification.** Does `decrypt`/`checkMac` compare Poly1305
  tags in constant time in 2.9.0? A variable-time compare is a classic forgery
  side channel. The SDK guide scopes out *timing side channels in pure-Dart crypto*
  with a "no remote oracle" argument — verify that argument holds for every way
  this library can be embedded (e.g. a server using `EncryptedFileBackend` where
  an attacker can submit containers).
- **Internal secret handling.** Does `SecretKey`/`SecretBox` copy key bytes into
  `String`s or otherwise multiply copies? Feeds §5 (memory hygiene).

## 2. macOS Keychain backend (`lib/src/ffi/keychain.dart`)

The binding targets the **classic login keychain**
(`kSecUseDataProtectionKeychain = false`, `kSecAttrSynchronizable = false`).

- **Legacy-keychain lifecycle.** What is Apple's current (2025–2026) support and
  deprecation posture for file-based keychains and `SecItem` against them? Any
  WWDC signals that would force a migration to the Data Protection keychain —
  which requires code signing + keychain-access-groups entitlements a bare Dart
  CLI may not have? What *are* the exact requirements for an unsandboxed,
  developer-ID-signed (or unsigned) CLI to use the DP keychain?
- **At-rest cryptography of the login keychain file.** Historically the
  `.keychain-db` format used 3DES-derived item encryption. What does the current
  format use? This bounds the real at-rest strength of model A on macOS and
  belongs in the SDK guide's threat model if it's weaker than the container's
  XChaCha20-Poly1305.
- **ACL identity for JIT-run Dart. [code fact]** Keychain ACLs key on the
  *binary* identity. Under `dart run`, the acting binary is the shared `dart` VM
  — so after one "Always Allow", plausibly *any* Dart script run by that user
  reads the item silently. Research the exact ACL matching rules for unsigned /
  ad-hoc-signed binaries and partition lists (macOS 10.12+), and whether the
  SDK guide should direct production users to `dart compile exe` so the ACL binds
  to their app's identity, not the SDK's.
- **Prompt suppression for headless use. [code fact]** The binding never calls
  `SecKeychainSetUserInteractionAllowed(false)` (or a per-call equivalent), so on
  a locked keychain a `get`/`probe` may raise a GUI unlock prompt instead of the
  intended typed `KeystoreLocked` — the exact hang the Linux path's timeout was
  built to prevent (`probe()` at keychain.dart:419 does a real `get`). Research
  the legacy-API best practice for non-interactive processes and how peers
  (aws-vault, docker-credential-osxkeychain) handle it.
- **Add-then-update race semantics.** `set()` handles `errSecDuplicateItem` by
  updating, but a delete racing between add and update surfaces
  `errSecItemNotFound` as a hard failure rather than a retry — confirm what
  peers do (retry loop vs. surface).
- **Enumeration robustness.** `_copyString` uses a fixed 1 KiB buffer, sized for
  *our* validated accounts — but `getAll` enumerates any item another app wrote
  under the same service string. Confirm failure mode is a typed error (DoS at
  worst) and note it.

## 3. Linux Secret Service backend (`lib/src/ffi/secret_service.dart`)

- **`secret-tool` behavior matrix.** The taxonomy branches only on
  launch-failure / timeout / exit≠0. Build the real matrix across gnome-keyring,
  KWallet (≥ 5.97 Secret Service portal — verify that version claim), and
  headless sessions: locked collection *with no prompter* (immediate nonzero exit
  — currently misreported by `probe()` as available+unlocked, secret_service.dart:184-197),
  missing default collection, no D-Bus session, prompt dismissed. Map each to the
  right typed error. This decides whether `secret-tool` remains adequate or the
  recorded native-D-Bus follow-up should be promoted.
- **Transport encryption on the bus.** Does libsecret/`secret-tool` negotiate the
  `dh-ietf1024-sha256-aes128-cbc-pkcs7` session by default, or plain? Same-user
  D-Bus is outside the threat model, but the design doc dinged `dbus_secrets`
  for a plaintext session — the doc should state what our own path does.
- **Secret-as-`String` on this path. [code fact]** `ProcessRunResult` carries
  stdout as a Dart `String`, and `set()` passes base64 stdin as a `String` —
  so on Linux the *base64 encoding of every secret* becomes an immutable,
  unzeroable Dart String (secret_service.dart:74-96), despite the bytes-first
  core surface. Research: restructure the runner to bytes end-to-end, or
  qualify the guide. Base64-of-secret is
  security-equivalent to the secret.
- **Interop note.** Values are stored base64-encoded, so items are not readable
  as raw values by other Secret Service consumers (and vice versa). Survey how
  Python/Go/Rust keyring libraries store binary values (many use their own
  encodings too) and document the compatibility posture.
- **Subprocess edge cases.** A child that exits before consuming stdin can fail
  `stdin.close()` with an untranslated `SocketException` (not mapped into the
  taxonomy). Also confirm `secret-tool`'s documented exit codes justify the
  `exit 1 == not found` branches.

## 4. Container format & crypto design (`container.dart`, `tlv.dart`)

- **Key commitment.** XChaCha20-Poly1305 is not key-committing (Len/Grubbs/
  Ristenpart line of work; partitioning-oracle attacks). An attacker who can
  supply a container file could craft bytes valid under two keys. Assess whether
  any deployment shape here (restored backups, synced dotfiles, server accepting
  containers) makes that exploitable, and whether to add a cheap key-commitment
  (e.g. HKDF-derived key-check value in the header, or the "padding fix"
  construction) in the v2 format.
- **XChaCha standardization status.** draft-irtf-cfrg-xchacha never became an
  RFC. Confirm 2026 status and that the libsodium/age ecosystem consensus still
  makes it the right random-nonce AEAD choice vs. AES-256-GCM-SIV or
  ChaCha20-Poly1305 with a counter scheme.
- **Nonce collision bounds** for 24-byte random nonces at this write frequency —
  trivially fine, but state the bound in the design doc for reviewers.
- **HKDF usage review.** salt = caller `contextSalt` (may be empty → RFC 5869
  zero-salt), info = versioned domain string + cipher id, AAD also binds the
  salt. Confirm this against current HKDF usage guidance (empty-salt caveats,
  salt-vs-info roles) — expected verdict: fine, but get it on record.
- **Failure-oracle check.** `AuthenticationFailed` vs `ContainerCorrupt` are
  deliberately distinguishable. Confirm no chosen-ciphertext oracle arises from
  the distinction (no padding, AEAD-only — expected fine).
- **Size side channel / padding.** Container length leaks total plaintext size.
  age/libsodium mostly don't pad either — confirm and document as accepted.

## 5. Memory hygiene — validate the ceiling, then hit it

SDK guide: "Dart cannot zero buffers." True for the GC heap (and a compacting GC
strands old copies), but **not** for the package's own native allocations:

- **[code fact]** The POSIX write path stages bytes in a `malloc` buffer freed
  without zeroing (posix_file.dart:94-117) — for `FileKeySource.create` that
  buffer holds the raw store key. Same for the Keychain `_cfData`/`_cfString`
  staging buffers holding secret values (keychain.dart:189-203). Zeroing before
  `free` (memset via FFI, `fillRange`) is cheap and standard (libsodium
  `sodium_memzero`). Research compiler/GC caveats in Dart FFI and just do it.
- **State of the art for secrets in GC'd languages** — Go `memguard`, Java
  `char[]` guidance, .NET SecureString deprecation rationale — to calibrate what
  the SDK guide can honestly promise, and whether holding the store key *only* in
  mlock'd native memory (with a zeroing finalizer) is worth the complexity.
- **OS-level mitigations to offer or document:** `setrlimit(RLIMIT_CORE, 0)`
  via the existing libc shim as an opt-in helper; `mlock` for the key buffer;
  macOS encrypted swap default vs. Linux reality; `MADV_DONTDUMP`.
- **Copy inventory.** Decrypt → `Uint8List.fromList(plaintext)` → per-entry
  copies in `_Reader.bytes` (tlv.dart:145-152) → caller copies: count the
  surviving plaintext copies per read and decide which are avoidable.

## 6. Filesystem hardening (`posix_file.dart`, backend read paths)

- **Read-side permission checks. [code fact]** `ensurePrivateDirSync` runs only
  on the *write* path (encrypted_file_backend.dart:72). Reads accept a
  world-readable dir, container, or `FileKeySource` key file without complaint
  (`readCappedSync` never stats mode). OpenSSH refuses group/world-readable key
  files; research whether peers (age, pass, aws-vault file backend) enforce
  perms on read, and add the check (especially for `FileKeySource.read`).
- **POSIX ACLs.** `mode & 0o077` misses ACL grants (`setfacl`) and the deferred
  euid-owner check. Survey what security-sensitive tools actually check
  (most: mode+owner only) and either match that (add owner via per-platform
  `stat`) or document ACLs as out of scope.
- **Directory fsync.** The design doc says Dart can't fsync a directory, but the
  shim already binds `open`/`fsync` — opening the dir `O_RDONLY` and fsyncing is
  the standard crash-durability completion of atomic-rename. Verify the claim is
  merely "dart:io can't" and promote the recorded follow-up.
- **fsync/close EINTR semantics** per platform (close-EINTR must *not* retry on
  Linux — current code correctly doesn't; fsync-EINTR handling differs) — verify
  against modern guidance.
- **`readCappedSync` TOCTOU** (length check then read) — benign? Confirm.

## 7. Concurrency & durability semantics

**RESOLVED (implemented).** Both failure modes below are now closed: every
mutating operation takes an exclusive advisory `flock` on a `<container>.lock`
file (non-blocking with async backoff, typed `StoreBusy` on timeout), layered
under the in-process per-path FIFO mutex. `flock`'s per-descriptor ownership
serializes writers across isolates *and* processes; reads stay lock-free
(atomic replace is never torn). See encrypted_file_backend.dart and
posix_file.dart `withExclusiveLock`, with cross-isolate and mutual-exclusion
tests. The original research notes are kept below for the record.

Cross-process coordination was once a documented non-goal, but two shapes
deserved research because their failure mode is *silent credential loss*:

- **[code fact]** No in-process serialization either: two interleaved
  `write()`s on one `EncryptedFileBackend` race the whole-file
  read-modify-write and one update vanishes (last-writer-wins).
- **[code fact]** First-write key race: two fresh processes both see no key,
  both `KeySource.create()` (unconditional overwrite, key_source.dart:164-167)
  — one process's container can end up sealed under a key that was just
  replaced → later `AuthenticationFailed` on good data.
- Research: `flock`/`O_EXLOCK` advisory locking via the existing libc shim
  (cost: ~1 binding), an in-process mutex as a floor, and how peers handle this
  (keyring daemons serialize; file-based peers like pass/age mostly don't).
  Decide: fix, or sharpen the "bring your own lock" documentation with the
  concrete failure modes. → **Chosen: fix.** Shipped `flock(LOCK_EX|LOCK_NB)`
  via the libc shim plus the in-process mutex floor, exactly as scoped here.

## 8. Rollback protection design (recorded follow-up — needs a concrete shape)

AEAD can't detect restoration of an older genuine container. Research
keystore-anchored monotonic-counter patterns: how do Chrome (OSCrypt), Signal
Desktop, systemd-creds, or TPM-backed stores bind "freshness"? Sketch the v2
change (counter in AAD + counter item in keystore; recovery UX when they
diverge — restored backup looks like tamper).

## 9. Input validation & error hygiene

- **Unicode label injection. [code fact]** `validateLabel` rejects only
  C0/DEL (identifiers.dart:31-36); U+202E (RTL override), zero-width and other
  format characters pass and render in Keychain Access / Seahorse. Research
  UTS #39 / bidi-spoofing guidance for UI-displayed strings and tighten
  (reject Cf/Cc categories or normalize).
- **`ArgumentError.value` echoes the offending value. [code fact]** If a caller
  transposes `(key, secret)` arguments, the secret lands verbatim in an
  exception message → logs (identifiers.dart:14-20). Peers' pattern: describe
  the violation without echoing. Cheap fix; confirm as best practice.
- **Error-content audit** — systematic pass that no path attaches subprocess
  output, values, or key bytes to errors (spot-checks look clean; make it a
  test: throw-site grep + a fake backend asserting message contents).

## 10. Supply chain & CI posture

- **Pin GitHub Actions by commit SHA** (currently `@v4`/`@v1` tags,
  ci.yml:15-49) — tag-retarget is a live attack class. Also evaluate OpenSSF
  Scorecard, StepSecurity harden-runner, and dependabot/renovate config.
- **OSV coverage of pub.dev** — confirm the scanner actually resolves Dart
  advisories from `pubspec.lock` (the ecosystem's advisory density is low; what
  else covers Dart?).
- **Publication hardening for the pub.dev release** (pre-1.0 follow-up):
  trusted publishing / automated publishing from CI with OIDC, provenance,
  2FA on the publisher, `pana` checks.
- **Exact-pin consequences post-publish.** `cryptography: 2.9.0` exact-pinned in
  a *published library* forces the resolution for every consumer (conflict
  risk) — research the ecosystem norm (range + lockfile + advisory process) and
  decide the published-version policy; the vector firewall changes the usual
  trade-off calculus here.
- **CF symbol / ABI assumptions on untested targets:** Linux arm64 `VarArgs`
  for `open(2)` mode (verified only on Apple arm64 + CI x64), musl
  `__errno_location`, `mode_t` width claims, `O_CREAT`/`O_EXCL` flag values per
  platform — consider a CI matrix addition (linux-arm64 runner) instead of
  trusting header lore.

## 11. Platform-behavior claims to verify (doc accuracy)

- Dart `Random.secure()` implementation per platform (getrandom? /dev/urandom?
  CryptGenRandom lineage?), failure modes, fork-safety — it's the only RNG.
- `File.renameSync` → `rename(2)` mapping (same-dir, so no cross-device risk).
- gnome-keyring and KWallet **at-rest formats/strength** (parallels the macOS
  keychain-file question; bounds model A on Linux).
- macOS: does Time Machine / Migration Assistant restore of
  `~/Library/Keychains` behave as assumed (encrypted under login password)?
- Whether `secret-tool store` to the default collection fails cleanly when no
  default collection exists (fresh headless account).

## 12. Ecosystem benchmarking (API + semantics)

Structured comparison against: Rust `keyring`, Python `keyring`,
`zalando/go-keyring` + `99designs/keyring` (aws-vault), `age`, `pass`,
`git`/`docker` credential helpers, `flutter_secure_storage` (attribute-layout
compat: could model A read/write its items?), systemd-creds. Extract: locked-
keystore UX, headless story, attribute naming conventions, enumeration support,
rollback/locking decisions, and anything they all do that this package doesn't
(or vice versa — e.g. the timeout-guarded subprocess is ahead of several).

## 13. Testing depth

- Fuzzing: in-suite random fuzz is a smoke layer — research Dart-native
  structured fuzzing / property-based testing for the TLV reader and envelope
  parser, and a corpus checked into the repo.
- AEAD edge vectors (empty plaintext/AAD, boundary lengths, Wycheproof set).
- A concurrency test that demonstrates (or rules out) §7's lost-update.
- The Linux `dbus-run-session` integration harness (already tracked, ci.yml:42)
  — unblocks the §3 behavior matrix permanently.
- Leak-check pass for CF refs claimed in the design doc ("leak-checked
  integration pass") — verify it exists or build it.

## 14. Doc-consistency nits found while reading (fold into any fix pass)

- backend.dart:5-6 and errors.dart:91-93 still say the macOS backend *cannot*
  enumerate; it can and does (keychain.dart getAll, capabilities say so).
- `KeystoreBackend.contains` materializes the value via `get` despite the seam
  doc promising avoidance where possible (backend.dart:60-61) — macOS could
  query attributes-only; Linux could too.
- `deleteAll` round-trips every secret's *value* through memory just to get
  keys — wants a keys-only enumeration on the seam.

## 15. `deleteAll()` semantics vs. a destructive reset (needs its own review)

Surfaced during the CLI RFC review (cli-implementation-plan.md §14) and
deliberately **not** a CLI ask. Today's `deleteAll()` is a healthy-store
convenience: it begins with `readAll()` and then deletes per key
(secret_storage.dart) — so it requires a *decryptable* store, is non-atomic
mid-loop, and round-trips every value through memory to obtain keys. It
cannot recover a `KeyInvalidated` store; the documented recovery there is
deleting the store's data directory and re-provisioning
(platforms/android.md). The open design question: keep `deleteAll()` as the
logout/wipe convenience it is (documenting those semantics), and/or add a
deliberately-named destructive reset that deletes container + wrapped key +
keystore material and therefore works on an *unreadable* store. Decide on
its own merits — "unused by the CLI" is not an argument either way.
