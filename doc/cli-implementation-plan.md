# keyway CLI (`keyway_cli`) — implementation plan

*Plan for a package that does not yet exist. It records the product design,
the DX and security requirements, the frozen constants, and the
implementation context, so the build starts from conclusions rather than
re-deriving them. Once code exists, the usual rule applies: where this file
and the code disagree, the code wins and this file gets corrected.*

*Naming is **settled** (2026-07-12): the product and executable are
**`keyway`**, the CLI package is **`keyway_cli`**, and the library —
formerly `secret_store`, never published under that name — is renamed
**`keyway`**. The full decision record, availability research, and
registration checklist are in Appendix B. Every constant that freezes with
the name is in §16.*

Governing rules, inherited from [implementation-plan.md](implementation-plan.md)
and extended: **one clear way to do things**; **the library stays the security
engine** (the CLI adds workflow, never crypto or storage policy); **fail
closed, never downgrade**; **no secret value ever touches argv, a log, an
error, or a file the CLI writes**; **small code = small attack surface** —
the CLI must be auditable to the same standard as the core.

## 0. Product statement

A secure, local replacement for plaintext `.env` files — for any application
in any language, not just Dart.

The repository commits a **manifest** (`.secrets.env`) holding non-secret
config as literals and secrets as **references** (`kw://openai-api-key`).
Real values live in the OS keystore / encrypted container via the `keyway`
library. `keyway run -- npm start` resolves the references, builds the
child's environment in memory, and executes the command. The child receives
ordinary environment variables; it needs no library, no Dart, no knowledge
of `kw://`.

What this buys, concretely:

- **Nothing secret-derived in the repository, ever.** Unlike the
  encrypted-values-in-repo model (dotenvx), there is no ciphertext in git
  history to protect forever and no key file whose loss decrypts it all.
  Rotation is an ordinary `set`.
- **A repo that is safe to hand to development tools.** An AI agent or
  indexer reading the workspace sees `kw://openai-api-key` — a name, not a
  credential. This is robust by construction, not by advisory ignore-files.
- **`.env` ergonomics preserved.** One committed file documents exactly which
  variables an app needs; `check`/`fill` turn onboarding into "clone, run one
  command, paste your keys".
- **No account, no server, no daemon, no network.** The entire product is a
  local binary over the already-audited library.

Positioning vs. the 2026 landscape is in Appendix A. The one-line version:
the free/local tools (envchain, envsec, envguard) keep secret *profiles
outside the repo* — no committable contract; the committable-manifest UX
exists only in 1Password's paid `op run`. This CLI is that UX, local-only,
on an audited core.

## 1. Goals / non-goals

**Goals (v1)** — the `run` / `set` / `get` / `rm` / `list` / `check` /
`fill` / `import` / `doctor` / `init` / `completion` surface (§5); the
manifest format specified exactly (§4); macOS and Linux desktop; signed,
notarized release binaries plus `dart install`; onboarding UX good enough
that a teammate needs one command; zero new third-party runtime dependencies
(§8 SR-9); zero library changes required (§3).

**Non-goals (v1)** —

| Cut | Why |
|---|---|
| Windows | Rides the core `WinCredApi` backend ([implementation-plan.md](implementation-plan.md) Phase 5). No interim key-on-disk scheme — that would be S4 storage behind a product that promises S3+ (design.md §9), violating fail-closed. |
| Headless / CI operation | The library fails closed there by design (design.md §12; [headless-implementation-plan.md](headless-implementation-plan.md)). The CLI's job is a **good error**: this is a dev-machine tool; CI should use the CI platform's secret store (§5 `run`). |
| Secret sync / team sharing | The model is per-developer values behind a shared contract. Sharing values is 1Password/Doppler territory — a different product with a server in it. |
| Shell hook / auto-env (direnv-style) | Rejected on principle, not effort: exporting secrets into an interactive shell leaks them to *every* subsequently launched process and into the shell's own memory for the session. Run-scoped injection is the model. |
| Output masking (`op run`-style redaction) | Deferred, not rejected — masking requires interposing pipes on the child's stdio, which breaks TTY inheritance (child sees `isatty=false`: colors, prompts, buffering change). v1 chooses exec transparency; a `--mask` opt-in with the documented TTY trade-off is a v1.x candidate (§13). |
| `kw+file://` materialization (`*_FILE` convention) | v1.x candidate (§13). Genuinely stronger than env for apps that support password-files; sketched so it isn't re-derived. |
| Value interpolation / templating in the manifest | `${VAR}` expansion is dotenv scope-creep with injection-shaped edges. Literal or reference, nothing else. |
| Import from password managers | v1 imports plaintext `.env` only. `op`/`bw` interop later, if ever. |

## 2. Architecture & packaging

Two packages, one repository, per the standing decision (design.md §1 —
the library is a small security primitive; the CLI brings parsing, TTY,
process, and locking concerns that must not enlarge the library's audit
surface):

```
keyway_cli   (product: manifest, commands, prompting, exec, lock)
    │  exact-pinned dependency (pre-1.0)
keyway       (engine: platform storage, container, typed errors — unchanged;
              renamed from secret_store 2026-07-12, pre-publish)
```

- **Repo layout:** convert to a pub workspace. Whether the library stays at
  the root or both packages move under `packages/` is settled at
  implementation time against pub's workspace constraints; the requirements
  are: one repo, shared CI, the CLI pins the exact core version, and the
  library's `repository:` link stays valid for pub.dev.
- **The CLI needs zero library changes for v1.** `SecretStorage(appId:)`,
  the string verbs, `containsKey`, `readAll` (enumeration capability),
  `describe()`, and the typed error taxonomy cover every command (§17).
  Remaining v1.x ask on the core follow-up list (design.md §13): keys-only
  enumeration (so `list`/`check` stop materializing values).
  Attributes-only `contains` shipped in core PR #3 — though on the CLI's v1
  platforms (file backend) `contains` still decrypts the whole sealed
  container, so one `readAll` per command remains the right resolution
  pattern regardless.
- **Dependency policy (normative):** runtime deps = `keyway` (exact pin) +
  `args` (dart-lang official). Nothing else. The core's dependency-closure
  snapshot test is replicated for the CLI package; CI fails if the tree
  changes. Argument parsing, terminal echo control (`stdin.echoMode`), the
  POSIX `execve`/`flock` bindings, and manifest parsing are all stdlib +
  `dart:ffi` work (`package:ffi` is already in the pinned closure).

## 3. Store mapping — appId, references, scopes

**One fixed `appId` for the whole CLI**: **`keyway-cli`** (frozen, §16).
Secrets are namespaced *inside* it using the library's key grammar, which
already permits `/` (design.md §4):

| Reference in manifest | Library key | Meaning |
|---|---|---|
| `kw://openai-api-key` | `openai-api-key` | machine-global secret |
| `kw://myapp/database-password` | `myapp/database-password` | scoped secret |

Reference grammar: `kw://<segment>` or `kw://<segment>/<segment>` where each
segment matches `[A-Za-z0-9._-]+` and the joined key respects the library's
120-char cap. Case-sensitive. Anything else is a hard error.

Why one appId rather than appId-per-scope: one container and **one** keystore
item for the store key, so macOS users see one ACL prompt total, not one per
project (the Model-B consequence design.md §6 predicts: N secrets, one
keychain item); enumeration (`list`) works across everything the CLI manages;
and per-scope containers would fake an isolation boundary that doesn't exist —
everything is same-user anyway (design.md §8).

Why scopes are **explicit strings in the ref** and never inferred: inferring
project identity from the git remote breaks on forks, from the path breaks on
moved checkouts and worktrees. Identity is what is written in the committed
manifest — zero config, greppable, and the whole team resolves the same
names. Deliberate cross-project sharing is spelled `kw://shared/foo`.

## 4. Manifest specification (`.secrets.env`)

The manifest is a **committable contract**, not a dotenv dialect. The parser
is strict and total (arbitrary bytes → parse result or typed error, never a
crash — same stance as the container's TLV reader, and fuzzed the same way).

The default filename stays **`.secrets.env`** rather than a tool-branded
name: it describes the *content*, remains accurate if a team ever migrates
tooling, and reads as what it is in a repo listing (§14).

Grammar, exactly:

- UTF-8; a single leading BOM is tolerated and stripped; NUL bytes are an
  error. CRLF is tolerated. Manifest ≤ 1 MiB, line ≤ 64 KiB.
- Blank lines and lines whose first non-whitespace byte is `#` are ignored.
  No inline comments — `KEY=value # note` puts `# note` in the value.
- Entries are `NAME=VALUE`. `NAME` matches `[A-Za-z_][A-Za-z0-9_]*`.
  Duplicate `NAME` is a **hard error** (silent last-wins hides mistakes).
  `export NAME=…` is a hard error whose message says to drop `export`.
- `VALUE` is everything after the first `=`, with surrounding whitespace
  trimmed; a single pair of matching `"` or `'` quotes is stripped, with **no
  escape processing** (the bytes inside are the value). No interpolation, no
  multiline values.
- If the (unquoted) value is exactly a `kw://` reference (§3 grammar), the
  entry is a **reference**. If it merely *starts with* `kw://` but fails the
  grammar, that is a **hard error** — it is almost certainly a typo'd
  reference, and treating it as a literal would ship the typo into the child
  env. A value that contains `kw://` elsewhere is an ordinary literal.

**The tool never writes a manifest.** Not `import`, not `init`, not anything
— they print to stdout and the user redirects. This keeps "the CLI never
touches your repo" as an absolute, checkable property (SR-3).

## 5. Command surface

Conventions: no command accepts a secret **value** as an argument, anywhere
(SR-1). All human-facing errors name the exact fix (DX-3). `--help`
everywhere, with examples.

| Command | Behavior |
|---|---|
| `run [-f <manifest>]… [--] <cmd> [args…]` | The product. Default manifest: `./.secrets.env` **in the cwd only — no upward directory search** (a walk toward `/` could pick up a manifest planted in a parent directory, e.g. `/tmp`). Multiple `-f` compose; later files win per key. Parse → resolve **all** references → on any failure, list *every* missing/broken ref with its fix command and exit 78 **before** anything runs (no partial injection, SR-4) → exec (§6). On a headless/locked keystore: the library's typed error, plus CLI guidance ("dev-machine tool; use your CI's secret store in CI"). |
| `set <name-or-ref>` | Accepts `name`, `scope/name`, or full `kw://…`, normalized per §3. Value via interactive hidden prompt (echo off; TTY required) or `--stdin` (exact bytes to EOF; one trailing `\n` stripped by default, `--keep-newline` to keep — the trailing-newline API-key footgun is worth a flag). Optional `--label` for keystore UIs. Refuses to prompt when stdin is not a TTY: scripts must say `--stdin`. |
| `get <name-or-ref>` | Prints the value, raw bytes, **no added newline**, no TTY-dependent behavior (output identical piped or not — varying by `isatty` is a footgun). Exists for interop/scripting; docs steer toward `run`. |
| `rm <name-or-ref>` | Deletes; error (exit 1) if absent. |
| `list [--scope <s>]` | Names, scopes, labels. **Never values.** |
| `check [-f <manifest>]…` | Parses the manifest(s), resolves every ref, prints a set/missing table with the exact `set` command per missing ref. Exit 0 iff all resolve. The team-onboarding contract: `git clone && keyway check`. |
| `fill [-f <manifest>]…` | `check`, then interactively prompts for each missing secret. Clone → `fill` → running. |
| `import <path>` | Reads a plaintext `.env`, stores each entry (`--scope` to namespace), prints the equivalent manifest to stdout. **Never modifies or deletes the source.** The output ends with honest guidance: secure deletion is not promised on modern filesystems/SSDs (journaling, wear-leveling) — delete the file, then **rotate** the credentials that lived in plaintext. |
| `doctor` | Surfaces `describe()`: scheme, measured `SecurityLevel`, keystore reachability/locked state, container path, versions. On macOS additionally reports the binary-identity situation: running under `dart run`/JIT (trust unit = the shared VM — design.md §8) or an unsigned/ad-hoc binary earns a printed warning explaining keychain re-prompt behavior. |
| `init` | Prints a commented starter manifest to stdout. |
| `completion <bash\|zsh\|fish>` | Static completion scripts. |

Global: `--version`, `-h/--help`, `-q/--quiet`, `--no-color` (and `NO_COLOR`
/ not-a-TTY autodetect). There is deliberately **no `--verbose` that could
ever print a value**: verbosity levels change *operation* detail, never data.

## 6. `run` semantics

**Environment composition.** Child env = parent env, overlaid by the
manifest's entries (literals and resolved references). **The manifest wins
on conflict** — it is the declared contract, and letting a stray inherited
`DATABASE_PASSWORD` silently beat the manifest is spooky action. This
diverges from node-dotenv's existing-env-wins default; the divergence is
documented. Nothing is removed from the inherited env (v1 has no
`--isolate`); nothing not named in the manifest is added.

**Execution (POSIX).** Build the child's `envp` explicitly and replace the
process image via FFI `execve` (with our own `PATH` resolution, execvp-style):

- Signals, TTY, exit status, and process-group semantics are inherited by
  construction — there is no wrapper process left to forward anything, and
  no long-lived process whose memory holds the resolved values.
- The command line is executed **verbatim as an argv vector — never through
  `/bin/sh -c`** (SR-13). No shell means no injection surface and no quoting
  surprises.
- The wrapper's own environment is never mutated; secrets go only into the
  `envp` array handed to `execve`.

**Fallback (and the future Windows path):** `Process.start(mode:
inheritStdio)` + explicit forwarding of SIGINT/SIGTERM/SIGHUP + exit-code
mirroring, with signal deaths mapped to 128+n.

**Exit codes** (spec, tested):

| Code | Meaning |
|---|---|
| child's code | forwarded exactly once exec happens |
| 2 | usage error |
| 78 (EX_CONFIG) | manifest invalid, or references unresolved |
| 69 (EX_UNAVAILABLE) | keystore unreachable / locked / store unusable / unsupported platform |
| 70 (EX_SOFTWARE) | internal invariant violated (bug) |
| 75 (EX_TEMPFAIL) | store write lock held by a live peer (`StoreBusy`) — retry |
| 126 / 127 | command found-but-not-executable / not found |
| 128+n | child killed by signal n (fallback path; native on the exec path) |

## 7. Concurrency

Since core PR #3, **the library itself serializes writers across isolates
and processes**: every mutating read-modify-write takes an exclusive
advisory `flock` on `<container>.lock` (fresh descriptor per operation;
non-blocking acquisition with async backoff; a live peer holding it past
the timeout surfaces as typed `StoreBusy`; a filesystem without `flock`
fails closed — design.md §7). Both hazards the CLI cares about are closed
in the library: two terminals running `set` cannot lose an update, and the
first-use race (two processes each minting a store key) cannot happen.

**The CLI therefore ships no locking of its own.** An earlier revision of
this plan had the CLI carry its own `flock` because the library had cut
cross-process locking in the austerity pass; the library's reinstatement
supersedes that (§14). Read paths (`run`, `check`, `list`, `get`) remain
lock-free by the library's design — atomic replace guarantees a reader sees
a complete old or complete new store — so a wedged writer can never block
launches. The CLI's only lock-related surface is UX: mapping `StoreBusy`
to exit 75 with retry guidance (§17).

## 8. Security requirements (normative)

Each SR is a testable invariant; §12 maps them to tests.

- **SR-1 — no values in argv.** No command accepts a secret value as an
  argument (`set NAME VALUE` does not exist); no secret is ever passed to a
  child in argv. `/proc/*/cmdline` is world-readable; env is not.
- **SR-2 — no plaintext persistence.** The CLI writes no secret value to any
  file, ever: no temp files, no caches, no logs. Prompts run with echo off
  (restored on every exit path, including interrupt). Values exist in process
  memory and the library's stores, nowhere else.
- **SR-3 — the CLI never writes into the repository.** No manifest creation,
  mutation, or "helpful" rewriting. Output that looks like a manifest goes to
  stdout.
- **SR-4 — fail closed, atomically.** `run` resolves *everything* before
  starting *anything*. No partial injection, no empty-string placeholder, no
  "warn and continue".
- **SR-5 — inject only what is named.** Exactly the manifest's entries are
  added/overlaid; there is no dump-a-namespace mode (contrast envchain).
- **SR-6 — output hygiene.** No secret value in any error, prompt echo,
  diagnostic, or verbose output — inherits the library's guarantee
  (design.md §4 "Error hygiene") and extends it to everything the CLI prints.
- **SR-7 — memory honesty.** Inherits design.md §8's stance: Dart GC-heap
  copies cannot be zeroed; the CLI does not pretend otherwise. It minimizes
  copies, and on the exec path the wrapper's image (and any heap copies) is
  replaced wholesale by the child.
- **SR-8 — zero network I/O.** The CLI makes no network calls, full stop —
  a checkable product guarantee. Enforcement is honest about its mechanism:
  the pinned dependency closure contains no networking code, and the CLI's
  own surface is small enough to audit for `Socket`/`HttpClient` use; there
  is no sandbox pretending to enforce it at runtime.
- **SR-9 — supply-chain parity with the core.** Runtime deps: `keyway`
  (exact pin) + `args`. Closure snapshot test in CI; OSV scanning; the same
  "a pin moves only by reviewed decision" rule (design.md §10).
- **SR-10 — mutation safety is inherited, not reimplemented.** Every store
  mutation goes through the library's verbs, which serialize writers across
  isolates and processes via the cross-writer `flock` (design.md §7). The
  CLI adds no locking, no lock files, and no mutating path outside those
  verbs; contention surfaces as `StoreBusy`, mapped per §17.
- **SR-11 — release identity.** macOS release binaries are Developer-ID
  signed and notarized. Not (only) for Gatekeeper: the login-keychain ACL on
  the store-key item binds to the acting binary's code identity (design.md
  §8), so an unstable identity means a re-prompt per upgrade — the category's
  best-known papercut (envchain). `doctor` surfaces identity problems;
  pub-channel installs carry the documented VM-trust-unit caveat.
- **SR-12 — prompts require a TTY.** Interactive value entry refuses
  redirected stdin (use `--stdin`); no prompt can hang a script.
- **SR-13 — no shell interpretation.** The child command is an argv vector
  executed directly; the CLI never invokes a shell on the user's behalf.
- **SR-14 — no downgrade, good guidance.** Unsupported platform / unreachable
  keystore surfaces the library's typed error plus CLI-level remediation
  (unlock keychain; SSH note; "use CI secrets in CI"). Never a weaker scheme.
- **SR-15 — manifest discovery is non-magical.** Default path is exactly
  `./.secrets.env`; no upward search, no home-dir fallback, no env-var
  override of the default (an env-controlled manifest path would let a
  polluted environment redirect resolution).

## 9. Threat model (delta over design.md §8)

The library's threat model covers secrets **at rest**. The CLI adds the
injection step, and the honest statement of the boundary is:

**What `run` protects:** the repository (nothing secret-derived is ever in
it); the disk (no plaintext `.env`); backup/sync/indexing/agent exposure of
the working tree; casual disclosure (argv, scrollback, shell history).

**What `run` does not protect:** once injected, the values are ordinary
environment variables of the child — visible to same-user process inspection
(`ps eww`/`sysctl` on macOS, `/proc/<pid>/environ` on Linux, same-UID only),
**inherited by every descendant** of the launched command (the postinstall
script, the telemetry agent, the compiler plugin — this inheritance is what
2025-era npm supply-chain worms harvested), and present in the child's crash
dumps or anything the child itself logs. On macOS, note the asymmetry: at
rest the store key is ACL-gated per binary, but a running child's env is
readable by any same-user process without a prompt.

The mitigation ladder, by strength, is a documented product stance:
**1)** direct library integration (secrets never enter any environment —
the preferred path for apps that can), **2)** `kw+file://` materialization
(v1.x — env carries a path, not a value; defeats inheritance and env
inspection), **3)** env injection (universal default). The CLI's docs and
`doctor` teach the ladder rather than implying env injection is more than
it is. Same-user malware, root, and the child's own conduct remain out of
scope at every tier.

## 10. DX requirements (normative)

- **DX-1 — zero-config happy path.** In a repo with `./.secrets.env`,
  `keyway run -- <cmd>` works with no flags, no config file, no init.
- **DX-2 — fast.** AOT binary; `run` overhead (parse + resolve + exec) under
  50 ms on a warm keystore. No daemon to make it faster; there is nothing to
  warm.
- **DX-3 — every error names the fix.** Each typed library error and each
  CLI error maps to remediation text with the literal command to run (§17).
- **DX-4 — onboarding is one command.** `check` output is the onboarding
  document; `fill` is the onboarding action.
- **DX-5 — plays well with scripts.** Stable stdout/stderr split (data vs.
  diagnostics); `--quiet`; meaningful exit codes (§6); `NO_COLOR`. Anything
  intended for machine consumption beyond exit codes waits for an explicit
  `--porcelain` (v1.x) rather than letting humans' output become an API.
- **DX-6 — the help teaches the model.** `--help` examples show manifest +
  `set` + `run` in ten lines; `init` output is self-documenting.

## 11. Distribution & release

1. **GitHub Releases (primary):** per-platform `dart compile exe` binaries
   from a CI matrix (macOS arm64/x64, Linux x64/arm64), macOS ones signed +
   notarized (SR-11), SHA-256 sums + build provenance attestation. Honest
   note: Dart AOT builds are not bit-reproducible; provenance is the
   compensating control.
2. **Homebrew tap** (`brew install danreynolds/tap/keyway`), day one;
   homebrew-core once traction justifies it. Scoop/winget when Windows lands.
3. **`dart install keyway_cli`** for the Dart-native audience, with the
   documented identity caveat (§5 `doctor`, design.md §8): a pub-channel
   install's keychain trust unit is the VM or an ad-hoc-signed binary, so
   ACL prompts may recur; the signed release binary is the promoted channel
   for everyone else. The "any language" positioning fails if the answer to
   "how do I install it" starts with "install Dart".
4. **Registrations:** see Appendix B's checklist — `keyway.dev`, GitHub
   org/repo rename, pub.dev names, the npm/PyPI reclamation filings, and
   scoped-org fallbacks.

Release train: the CLI pins the exact core version; a core release triggers a
reviewed CLI pin-bump release. Independent CHANGELOGs; per-package tags.

## 12. Testing

The core's bar applies: every claim exercised for real, not mocked
(README "Testing").

- **Unit tier:** manifest parser — table-driven spec tests plus a **fuzz
  harness** (arbitrary bytes → typed error or valid parse, never a crash;
  the container TLV precedent). Ref grammar; env composition (manifest-wins,
  multi-`-f` precedence); exit-code mapping; remediation-text mapping for
  every typed core error (§17).
- **Command tier:** every command against `SecretStorage.withBackend(fake)` —
  the exported test hatch exists for exactly this (design.md §4).
- **Leak tier (SR-2/SR-6):** plant sentinel values; drive every error path,
  prompt path, and `--quiet`/verbose permutation; assert the sentinel never
  appears in any stdout/stderr/exit output. A PTY harness verifies echo-off
  and echo-restoration on interrupt.
- **Integration tier:** real keystores in CI exactly like the core (macOS
  Keychain; Linux via `dbus-run-session` gnome-keyring in Docker):
  `set → run → child sees value → rm` round-trips; exec-path signal/exit
  fidelity (child SIGTERM → 128+15; exit codes forwarded); cross-writer
  serialization (two concurrent `set`s → no lost update, courtesy of the
  library's flock; a deliberately wedged holder → `StoreBusy` surfaced as
  exit 75 with retry text); locked-keystore guidance path.
- **E2E:** `tool/test_cli.sh` joining the existing `tool/` suite; the
  README quickstart executed verbatim on both platforms.
- **Supply chain:** the CLI's own dependency-closure snapshot test.

## 13. Phases

**C1 — engine + skeleton.** Workspace conversion; package scaffold; manifest
parser + fuzz + spec tests; ref/scope mapping; `set`/`get`/`rm`/`list`;
`run` on the spawn fallback; command tier green on the fake backend.
*Verify:* quickstart works end-to-end on macOS + Linux dev machines.

**C2 — hardening + the product feel.** FFI `execve` path + exit/signal
matrix; `flock`; leak tier; `check`/`fill`/`doctor`/`init`; remediation-text
mapping; completions; both integration legs in CI.
*Verify:* full §12 matrix green in CI; SR checklist audited item by item.

**C3 — release engineering.** Signing + notarization pipeline; GitHub
Releases with checksums + provenance; Homebrew tap; `dart install` path
validated from a clean machine; README/docs quickstart; Appendix B
registration checklist completed.
*Verify:* a person with no Dart toolchain installs and onboards a repo in
under five minutes on macOS and Linux.

**C4 — v1.x candidates (each a recorded design, not a promise):**
`kw+file://` materialization (0600 file in a per-run 0700 runtime dir —
`XDG_RUNTIME_DIR` / Darwin user temp — env carries the path, unlink after
exit, stale-dir sweep on next run); `--mask` with the documented TTY
trade-off; `--porcelain`; Windows (rides core Phase 5); keys-only enumeration
in core (design.md §13); npm wrapper channel; man pages.

## 14. Decision log

- **References-in-repo over ciphertext-in-repo (dotenvx's model).** Nothing
  secret-derived in git history; rotation is mundane; the cost — no value
  sync between teammates — is deliberate (§1 non-goals) and mitigated by
  `check`/`fill`. Positioning: solo devs, OSS bring-your-own-key repos,
  agent-safe working trees.
- **Explicit scope strings; no repo-identity inference.** Git-remote
  inference breaks on forks; path inference breaks on moves and worktrees.
  The committed ref *is* the identity (§3).
- **One appId, namespaced keys** — one keychain item and one ACL prompt, a
  working `list`, no faux isolation (§3).
- **Manifest wins over inherited env.** The contract beats the accident;
  divergence from node-dotenv documented (§6).
- **No shell hook mode.** Secrets in interactive shell env outlive and
  out-spread any single command; rejected on principle (§1).
- **No upward manifest search; no env-var default override** (SR-15).
- **`execve` over a wrapper process**, spawn as fallback: signal/TTY/exit
  fidelity by construction and no resident process holding values (§6).
- **`set` has no value-argument form** — argv is world-readable (SR-1).
- **Windows waits for `WinCredApi`.** No S4 interim (§1).
- **Masking and `_FILE` deferred with recorded designs**, not silently
  dropped (§1, §13).
- **The lock lives in the CLI, not the library.** *(Superseded the same
  day, 2026-07-12: core PR #3 reinstated the cross-writer `flock` inside
  the library — the first-write key race proved cheap to close and easy to
  hit. The CLI now inherits mutation locking and ships none of its own;
  §7, SR-10.)*
- **Name: `keyway` (2026-07-12).** Decision record in Appendix B. The
  library renames with it (one brand, two packages); public API identifiers
  (`SecretStorage`, the error types) are **not** renamed — this is a
  packaging rename, not an API rename — and the container's wire-format
  constants are **frozen** regardless of branding (§16).
- **Scheme: `kw://` (2026-07-12), replacing the draft `se://`.** Two
  characters, brand-evident in any manifest line, no compatibility concern
  (nothing shipped). Frozen with the name.
- **Manifest filename stays `.secrets.env`** — content-descriptive over
  tool-branded (§4).
- **appId: `keyway-cli`, not bare `keyway`** — a library consumer choosing
  `appId: 'keyway'` for their own app must not merge stores with the CLI
  (§3, §16).

## 15. Open questions

- `fill` vs `setup` as the onboarding verb (pick at C2 by writing the docs
  and seeing which reads better).
- `--label` default: none, or derive from the manifest variable name?
- Workspace layout (root package vs `packages/`), settled at C1 against
  pub's constraints.
- Whether `check` belongs in `run`'s failure output verbatim (probably: a
  failed `run` *is* a check report).
- `import` literal-vs-secret triage UX (per-entry interactive prompt is the
  leading candidate; decide at C2).

## 16. Frozen constants

Settled 2026-07-12; changing any of these after the first release is a
migration, not a rename.

| Constant | Value | Notes |
|---|---|---|
| Product / executable | `keyway` | the installed command |
| Library package | `keyway` | renamed from `secret_store`, pre-publish |
| CLI package | `keyway_cli` | pub.dev name confirmed free 2026-07-12 |
| Reference scheme | `kw://` | replaces draft `se://`; nothing shipped under the old scheme |
| CLI store `appId` | `keyway-cli` | derives container path + keystore service (design.md §3 rules) |
| Container path | `~/Library/Application Support/keyway-cli/secrets.enc` (macOS) · `${XDG_DATA_HOME:-~/.local/share}/keyway-cli/secrets.enc` (Linux) | derived by the library from `appId`; the library also maintains `<container>.lock` beside it (§7 — not a CLI concern) |
| Default manifest | `./.secrets.env` | content-descriptive, not tool-branded |

**Explicitly NOT renamed with the brand** (wire/storage compatibility — these
are format constants, not branding, and survive any future rename too):
the container magic `DSS1`; the HKDF `info` strings
`secret_store:v1:container` / `secret_store:v1:commit` (design.md §7); the
keystore *account* constant (`store-key`) and the DP-probe's internal service
string; the container filename `secrets.enc`. A change to any of these is a
container-format version bump, never a find-and-replace. Public API
identifiers (`SecretStorage`, `SecretStoreException`, …) also keep their
names — descriptive, and churning them buys nothing.

## 17. Library surface the CLI consumes

Everything the CLI needs, and the contract for what each failure means to a
user. Construction: `SecretStorage(appId: 'keyway-cli')` — once per process.
Verbs: `readAll()` (run/check/list — gated on
`backend.capabilities.enumeration`, true for both v1 platforms),
`writeString(key, value, label:)` (set/fill/import), `readString`/`read`
(get), `delete` (rm), `containsKey`, `describe()` (doctor).

Error → CLI behavior map (exhaustive over the exported taxonomy; the leak
tier drives every row):

| Typed error | Exit | CLI remediation text (gist) |
|---|---|---|
| `KeystoreLocked` | 69 | login keychain / Secret Service is locked — how to unlock; "over SSH this is expected: keyway is a dev-machine tool" |
| `KeystoreUnreachable` | 69 | no keystore here (headless/unsupported) — dev-machine tool; use the CI platform's secrets in CI |
| `StoreKeyMissing` | 69 | container exists but its key is gone from the keystore — unrecoverable without a key backup (design.md §7 matrix); `keyway doctor` for paths; re-provision via `keyway fill` |
| `ContainerMissing` | 69 | key exists, container file gone/moved — restore the file or re-provision |
| `WrongStoreKey` | 69 | container doesn't match this machine's key (swapped/copied between machines) — restore the matching pair or re-provision |
| `AuthenticationFailed` / `ContainerCorrupt` | 69 | container failed authentication / is corrupt — tamper or bit-rot; restore from backup |
| `MigrationRequired` | 69 | store-scheme change detected (design.md §12) — shouldn't occur for the unentitled CLI binary; explain rather than auto-migrate |
| `StoreTooLarge` | 69 | value/store exceeds the size envelope — this is a store for credentials, not blobs |
| `SecureFileError` | 69 | container/key/dir permissions are group/other-accessible — the library refuses loose modes (OpenSSH stance); print the `chmod` fix. Also raised when the filesystem cannot `flock` (fail-closed; local app-data storage always can) |
| `StoreBusy` | 75 | another keyway/library process or isolate holds the store write lock — a **live** peer, not a stale file (the OS releases a dead holder's lock); retry, and if it persists, find the wedged holder |
| `KeyInvalidated` | 69 | Android-only in practice; generic key-loss text if ever surfaced |
| `UnsupportedCapability` | 70 | internal bug (both v1 backends enumerate) — report upstream |
| `KeystoreOperationFailed` (catch-all) | 69 | the typed message + `keyway doctor` |

Manifest/usage failures are the CLI's own: parse errors and unresolved refs
→ 78 with the per-ref fix list; bad invocation → 2.

## 18. Implementation notes (gotchas, so they're hit once)

- **`execve` binding** is fixed-arity (3 pointer args) — none of the
  variadic-FFI trap that bit the core's `open()` on Apple arm64 (design.md
  §11). Build `argv`/`envp` as NULL-terminated `Pointer<Pointer<Utf8>>`
  arrays (`package:ffi` `malloc` + `toNativeUtf8`); on success it never
  returns, so leak-on-success is meaningless; on failure map `errno`:
  `ENOENT` → 127, `EACCES`/`ENOEXEC` → 126, message names the command.
- **PATH resolution is ours** (execvp semantics without libc's): walk
  `PATH` in order; **no implicit-cwd fallback** — a bare `cmd` never
  resolves to `./cmd` unless `.` is explicitly on the user's PATH. A
  script without a shebang gets 126 and a message, not a silent
  `/bin/sh` retry (SR-13).
- **Spawn fallback exit codes:** `dart:io` reports signal deaths as negative
  `exitCode` on POSIX — map `-n` → `128+n`. Forward `SIGINT`/`SIGTERM`/
  `SIGHUP` via `ProcessSignal.watch` to the child; with `inheritStdio` the
  foreground process group already routes Ctrl-C, so forwarding covers the
  non-TTY/backgrounded cases.
- **Prompt echo restoration:** set `stdin.echoMode = false`, restore in
  `finally` **and** in a `ProcessSignal.sigint.watch` handler (exit 130
  after restoring) — a Ctrl-C mid-prompt must not leave the user's terminal
  silent. PTY test asserts both paths.
- **`--stdin` byte handling:** read to EOF as bytes, strip exactly one
  trailing `\n` (and a preceding `\r` if present) unless `--keep-newline`;
  values are stored via `writeString` (UTF-8) — the env boundary is
  string-shaped anyway (env vars cannot carry NUL); document that binary
  secrets belong to the library tier, not the env tier.
- **Closure snapshot test:** replicate the core's `dart pub deps --json`
  snapshot for `keyway_cli`; the snapshot embeds package names, so it also
  pins the exact core version (§2's pin made testable).
- **`readAll` returns `Map<String, Uint8List>`** — decode values as UTF-8 at
  the env boundary; a value that fails UTF-8 decode is a typed CLI error
  naming the key (it was stored via the bytes API — point at `get`/the
  library tier), never a silent mangle.
- **Output discipline:** data → stdout, diagnostics → stderr, everywhere
  (`get` prints only the value to stdout; `import` prints only the manifest
  to stdout). This is what makes `keyway import .env > .secrets.env` safe.

## 19. Golden transcripts (acceptance sketches)

Condensed from the design walkthrough; C2 turns these into assertions.
Set + run, the happy path:

```console
$ keyway set acme-api/openai-api-key
Value for acme-api/openai-api-key (input hidden):
Stored.

$ keyway run -- npm start
> acme-api@1.0.0 start
listening on :3000

$ ps -o pid,ppid,command | grep node
81234  9021  node server.js          # parent is the shell — keyway exec'd away
```

Fail-closed run (SR-4, DX-3), which is also `check`'s shape:

```console
$ keyway run -- npm start
error: 2 of 3 references in .secrets.env are not set on this machine:

  DATABASE_PASSWORD    kw://acme-api/database-password
                       fix: keyway set acme-api/database-password
  STRIPE_KEY           kw://shared/stripe-test-key
                       fix: keyway set shared/stripe-test-key

Nothing was launched.
$ echo $?
78
```

Onboarding (DX-4):

```console
$ git clone git@github.com:acme/acme-api && cd acme-api && keyway fill
  ✓ kw://acme-api/openai-api-key      already set
  kw://acme-api/database-password — value (input hidden):
  kw://shared/stripe-test-key — value (input hidden):
Done — 3/3 references resolve.
```

`doctor`, macOS unentitled-CLI branch:

```console
$ keyway doctor
scheme:     encrypted file + login-Keychain key   (macOS, unentitled CLI)
level:      loginBound (S3)                        # measured, not assumed
container:  ~/Library/Application Support/keyway-cli/secrets.enc  (0600, 3 secrets)
keystore:   reachable, unlocked
identity:   /opt/homebrew/bin/keyway — Developer ID signed ✓ (keychain ACL stable)
```

## Appendix A — CLI landscape snapshot (2026-07)

Library-side comparison lives in
[ecosystem-comparison.md](ecosystem-comparison.md); this table is the
CLI-product landscape that motivated §0. Surveyed 2026-07-12.

| Tool | Values live in | Committable manifest | Local-only (no account/server) | Windows | Notes |
|---|---|---|---|---|---|
| 1Password `op run` | 1Password vault | ✅ `op://` refs — the UX this CLI adopts | ❌ paid account + app | ✅ | The polish bar. Masks child output. |
| envchain / envchain-xtra | OS keychain | ❌ namespaces outside the repo | ✅ | ❌ | Upstream dormant since 2024; fork markets the AI-agent angle. |
| envsec | OS keychain | ❌ profiles in `~/.envsec` | ✅ | ✅ | TypeScript, beta, 13★ (2026-04). |
| envguard | OS keychain | ❌ manifest gitignored | ✅ | ✅ | TypeScript, alpha, 2★. |
| dotenvx | ciphertext in repo; keys movable to OS keychain | ✅ (encrypted values) | ✅ | ✅ | The strongest free competitor; different model — ciphertext lives in git history forever. |
| teller / chamber / doppler / infisical / `bws` | hosted or cloud vaults | varies | ❌ | ✅ | Different category (server in the loop). |
| aws-vault | OS keychain | n/a (AWS creds only) | ✅ | ✅ | Proof the keychain→env→exec pattern is loved; single-provider. |

The unoccupied intersection this product targets: **committable reference
manifest + OS-native storage + run wrapper + no account/server/daemon + an
audited, minimal-dependency core.** Every neighbor misses at least two.

## Appendix B — naming decision record (2026-07-12)

**Decision: `keyway`.** The keyway is the shaped channel in a lock cylinder
that admits only the matching key — precisely this product: the one
sanctioned path by which keys reach a process. Chosen over ~30 vetted
candidates; final four:

| Finalist | Availability (pub / npm / brew / crates / PyPI / .dev) | Deciding factor |
|---|---|---|
| **keyway** ✅ | ✅ / squatted / ✅ / ✅ / squatted / ✅ (unregistered 2026-07-12) | Best metaphor and sound of the entire search; both squats are dead micro-projects; the brand collision (keyway.ai, AI-for-real-estate, ~$40M raised) is **out-of-category** |
| envkeep | all clean | Only true clean sweep, but permanently one letter from EnvKey — an **in-category** hosted secrets product; near-word-same-niche is the worse confusion profile |
| kove | all clean | Ownable coined word, but meaning-free (tagline must build it) and kove.com is an enterprise software mark |
| keyhold | clean except PyPI | Sturdy, flat; outclassed by keyway's semantics |

Notable kills, for posterity: `latch` (LatchBio owns PyPI; smart-lock company;
"latch" already means a concurrency primitive in software), `seclave`
(Swedish hardware password manager), `envault` (squatted + HashiCorp Vault
mark), `keybox` (GnuPG `.kbx` format, Android attestation keyboxes,
Bastillion-née-KeyBox), `quartz`/`slate`/`cove`/`ark`/`boreal`/`enclose`/
`geode`/`coffer`/`locket`/`kept`/`secretly` (registry squats and/or major
product collisions). Pattern worth remembering: real 4–6-letter nouns are
gone; only coined or compound names survive clean.

**Squat details** (both plausibly reclaimable; scoped fallback regardless):
npm `keyway` — a one-release 2022 toy ("the opposite of `Object.keys`");
PyPI `keyway` — a one-day-in-2023 "persistent environment variables"
project (ironically category-adjacent). File an npm abandoned-package
dispute and a PyPI PEP 541 request; the npm wrapper channel (§13 C4) works
as `@keyway/cli` either way.

**Registration checklist (owner actions, do the week of the rename):**
register `keyway.dev` (unregistered as of 2026-07-12); rename the GitHub
repo `danReynolds/secret_store` → `danReynolds/keyway` (GitHub redirects
the old URL; the pubspec `repository:` field is updated in the rename
commit and must match before pub publish); reserve the GitHub `keyway` org
name if available; publish stub/placeholder packages where free (crates) or
scoped (`@keyway` npm org); file the npm/PyPI reclamations; a five-minute
USPTO TESS sanity pass on "KEYWAY" for software goods.
