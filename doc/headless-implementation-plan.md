# Headless mode — design record (out of scope)

**Status (owner call, 2026-07-10): out of scope — not shipping at this time.**
A `TpmKeySource` prototype (systemd-creds wrap/unwrap) was built with unit +
real `systemd-creds` integration coverage, then **removed from the tree**:
unreachable code in a security package is unjustified surface (see the
austerity principle, design.md §12). The implementation is recoverable from
git history; this document remains the complete design so headless can be
built without re-deriving it if demand appears. Until then, a headless box
gets a typed, fail-closed `KeystoreUnreachable`.

The encrypted-file substrate this depends on (container, `EncryptedFileBackend`,
the POSIX shim, the per-location lock) is **already built and tested**; it lives
**unexported** in the tree. Headless work is mostly wiring, a TPM `KeySource`,
and the resolver/error plumbing — not new crypto.

---

## 1. Why headless needs an explicit signal (settled — do not relitigate)

The one temptation to resist is auto-detecting "am I headless" and silently
switching storage. A deep research pass (2026-07, 27 primary sources, adversarial
verification) **confirmed this is unsafe**; the finding is that headless / no-
unlocked-keyring **cannot be auto-detected reliably enough for a stateful
store**, because a runtime probe cannot separate three genuinely distinct
states, and basing a store's *location* on a flappy probe causes silent
split-brain data loss.

The three indistinguishable states:
- **(a) truly headless / no keyring provider** — a file is correct.
- **(b) keyring present but LOCKED** — real and persistent; e.g. fingerprint
  login leaves gnome-keyring's collection locked for the whole session (no
  password to derive the unlock key — RH Bugzilla #1859476). Should wait/prompt,
  *not* switch to a file.
- **(c) keyring transiently unavailable** — real; PAM/keyring races the session
  bus and `/run/user/<uid>` control-socket bring-up (gkr-pam has a retry loop
  precisely for this). The provider exists and appears moments later.

Supporting evidence (all primary, verified 3-0):
- **Signals flip across transport and version.** `XDG_SESSION_TYPE` is `x11`
  locally but `tty` after `ssh localhost` on the same machine/session (systemd
  #40992); a systemd-256 change pointed `XDG_SESSION_ID` at the manager's
  session so **gnome-shell misdetected headless and shipped it** (systemd
  #31287). `DBUS_SESSION_BUS_ADDRESS` is decoupled both ways (absent when a bus
  exists for `systemd --user`; present-but-"connection refused" on a stale
  socket — systemd #1600).
- **The Secret Service spec can't express the distinction.** Its entire error
  vocabulary is three errors (`IsLocked`, `NoSession`, `NoSuchObject`);
  absent/transient fall through to ungoverned lower-level D-Bus errors. logind
  has no "headless" session type (cron → `unspecified`).
- **Two direct precedents fixed it our way.** aws-vault's maintainer: silent
  keyring auto-fallback "is confusing, and results in lost credentials" → moved
  to an **operator-declared backend** (aws-vault #670, keyring #74 documents the
  split-brain). Python `keyring` actually *shipped* nondeterministic backend
  selection (same state → silent-`None` on some runs, raise on others, by
  unordered-set order — jaraco/keyring #372); the fix **did not add
  auto-detection** — it made absence deterministic and added an explicit
  `NoKeyringError` for callers to handle.

**Conclusion:** headless is a *deployment fact the operator declares*, via an
explicit `SecretStorage.headless(appId:)`. Auto-detection is out, permanently.

---

## 2. API

```dart
SecretStorage(appId: 'com.example.app')      // non-headless: OS keystore (ships first)
SecretStorage.headless(appId: 'com.example.svc')  // this plan: TPM-or-unsupported
```

**A named constructor, not a `headless: bool` flag.** Headless is a *different
storage model* (encrypted file, not keystore), so it's a different construction
path — and keeping it separate makes contradictory combinations
**unrepresentable**: `.headless()` simply has no keystore-only options (like the
future macOS `dataProtection`) on it, so `headless: true, dataProtection: true`
can never be written. (A boolean also invites `headless: someRuntimeCheck()` —
the exact flappy-detection footgun §1 forbids.)

**Self-revealing.** The plain `SecretStorage(appId:)` on a headless box throws
`KeystoreUnreachable` with guidance pointing at `.headless()`, so an operator
learns it exactly when needed and never carries the concept on desktop/mobile.

---

## 3. Per-platform resolution inside `.headless()`

Auto-pick the secure option for the platform, or **fail closed** — never an
insecure fallback.

| Platform (headless) | Result |
|---|---|
| **Linux + TPM 2.0** (most cloud VMs — NitroTPM, Azure/GCP vTPM — and bare metal) | Encrypted file + key sealed in the TPM via `systemd-creds`. **S1.** Zero further config. |
| **Linux, no TPM** (some minimal containers) | **Throw** `UnsupportedEnvironment` — no secure at-rest option exists; we don't fake it with an on-disk key. |
| **macOS headless** (SSH'd Mac, no GUI login) | **Throw** — Macs have no TPM (the hardware root is the Secure Enclave, which is *not* reachable headless: the DP keychain that gates it needs entitlements + a user login context). No clean path. |
| **Windows headless** (future) | TPM is common; same shape as Linux. Not planned until the Windows backend lands. |

---

## 4. Mechanism — `systemd-creds` (Linux)

Verified against real `systemd-creds` in an Ubuntu 24.04 container (systemd 255):

- **Commands:** `systemd-creds encrypt --name=<name> --with-key=<mode> - -`
  (plaintext on stdin → blob on stdout) and the symmetric `decrypt`. Exit 0 on
  success; the "credential secret not on encrypted media" line is a **warning
  with exit 0** — only exit codes signal failure.
- **`--with-key` modes** (expose as a small enum, default fail-closed):
  - `host+tpm2` (default) — needs the TPM *and* the host key. Strongest.
  - `tpm2` — TPM only.
  - `host` — **not hardware-bound** (key derives from
    `/var/lib/systemd/credential.secret` on the same disk). *Not* offered as a
    production option; used only to integration-test the wrap/unwrap plumbing
    in a container with no TPM (it works there — that's how CI covers this).
- **TPM detection:** `systemd-creds has-tpm2` (exit 0 = present; non-zero = not).
  Stable hardware fact (does not flap like keyring availability), so safe to
  branch on — but still surface it via `describe()`, don't guess a trust root.
- **Blob:** base64-ish text (~175 bytes for a 32-byte key), single value; stored
  `0600` next to the container. It's the *wrapped* key — the material lives in
  the TPM and never hits disk.
- **Transport:** the 32-byte store key rides through the shared (String-stdin)
  `ProcessRunner` **base64-wrapped**, consistent with the austerity-accepted
  boundary-base64 stance. No plaintext key ever written to a temp file.
- **`--name` binding:** bind the credential to a stable name so a blob can't be
  reused as a different systemd credential; must match on decrypt.

`TpmKeySource implements KeySource` — reuses the injectable `ProcessRunner` (so
it's unit-testable over a fake) and the `SecureFileSystem` atomic-write path for
the blob. Errors map to the typed taxonomy: launch-failure → `KeystoreUnreachable`
(`systemd-creds` absent), non-zero exit → `KeystoreOperationFailed` (never
attach subprocess output — same discipline as the Linux secret-tool path).

---

## 5. Substrate already in the tree (keep, don't rebuild)

Built and tested during the pre-1.0 work; kept **unexported** so it isn't public
surface until headless ships:

- `EncryptedFileBackend` — XChaCha20-Poly1305 container, **key-committing**
  header (so a wrong/mismatched key throws `WrongStoreKey`, not silent
  divergence — relevant to the reconciliation question below), HKDF domain
  separation, atomic `0600` writes + dir-fsync, the total/fuzzed TLV parser.
- The **per-location lock** (process-global `Map<path, mutex>`) that makes
  multiple in-process handles on one container conflict-free.
- `KeySource` interface + `InMemoryKeySource`/`FileKeySource` — retained as
  **internal test helpers only** (they exercise the container without a TPM);
  neither is public. `KeystoreKeySource` becomes relevant again here (wrap the
  key in the OS keystore) for any future desktop "one backup unit" use, but that
  is *not* in scope for headless.

---

## 6. Testing

- **Unit:** `TpmKeySource` over a scripted `ProcessRunner` (command construction,
  `--with-key`/`--name` args, exit-code → typed-error mapping, base64 transport,
  no-output-in-errors) — runs on any OS.
- **Integration (CI, Linux):** real `systemd-creds` with `--with-key=host` in a
  container (no TPM needed — verified feasible). Proves the encrypt→store→
  decrypt round-trip and exit-code handling end to end. Gate behind
  `KEYBAY_INTEGRATION=1`, `@TestOn('linux')`, alongside the existing
  secret-tool integration test.
- CI **cannot** exercise real TPM sealing (`tpm2` mode) without a TPM/swtpm; the
  `host`-mode round-trip covers the plumbing, and the TPM binding itself is
  systemd's concern, which we trust.

---

## 7. Open questions to resolve before/while building

1. **Reconciliation / migration.** Even with a correct explicit signal, what
   happens if an operator flips it, or a keyring appears/disappears between
   runs? aws-vault #74 shows the divergence but no blessed fix. *Our* position
   is stronger by construction — the container is key-committing, so opening it
   with the wrong key throws `WrongStoreKey` rather than silently reading empty
   and re-provisioning (the split-brain trigger). Document that switching modes
   does **not** auto-migrate, and that a mode change is a deliberate,
   re-provision-if-needed operation. Consider a one-time sealed marker recording
   the chosen backend so a mismatch is a loud typed error, not a guess.
2. **macOS SecItem error semantics headless (unverified).** The research pass
   could not independently confirm what `SecItemCopyMatching` returns under SSH/
   launchd (errSecInteractionNotAllowed vs errSecAuthFailed vs
   errSecMissingEntitlement) or whether it's stable. Since macOS headless
   resolves to **"unsupported"** anyway, this only matters if we ever revisit
   that decision; confirm before doing so.
3. **`$XDG_RUNTIME_DIR/bus` stat vs env var.** On modern `dbus-user-session`
   the bus socket has a fixed path; statting it is a marginally more stable
   *availability* probe than reading `DBUS_SESSION_BUS_ADDRESS` — but it still
   collapses the locked-vs-transient distinction, so it does **not** change the
   §1 conclusion. Only relevant to the plain constructor's fail-closed check,
   not to auto-selection.

---

## 8. Explicitly out of scope (v1 headless)

- **BYO / KMS key source** (Vault, cloud KMS, injected). The `KeySource`
  interface is the seam; re-expose it if real demand appears. Not built now.
- **macOS headless** — no clean hardware path (§3).
- **No-TPM headless** — no secure option; unsupported by design, not by
  omission.
- **Auto-detection of headless** — forbidden (§1).
