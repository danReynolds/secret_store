# keyway CLI (`keyway_cli`) — implementation plan

*Plan for a package that does not yet exist. It records the product design,
the DX and security requirements, the frozen constants, and the
implementation context, so the build starts from conclusions rather than
re-deriving them. Once code exists, the usual rule applies: where this file
and the code disagree, the code wins and this file gets corrected.*

*Naming is settled (2026-07-12): the product and executable are **`keyway`**,
the CLI package is **`keyway_cli`**, and the library — formerly
`secret_store`, never published under that name — is renamed **`keyway`**.
The naming record is Appendix B; constants that froze with the name are §16.*

*v1 scope is settled (2026-07-12) after a two-round independent RFC review:
**five commands, reference-only manifests** — the latter explicitly ratified
by the owner as a product decision, not a parser simplification. The
review's governing insight is recorded here because it should govern future
scope debates too: **omission is reversible; premature surface area is
not.** Cut features are recorded in §20 and Appendix C with their
reasoning — as evidence-gated ideas, not as a roadmap.*

Governing rules, inherited from [implementation-plan.md](implementation-plan.md)
and extended: **one clear way to do things**; **the library stays the security
engine** (the CLI adds workflow, never crypto or storage policy); **fail
closed, never downgrade**; **no secret value ever touches argv, a log, an
error, or a file the CLI writes**; **small code = small attack surface** —
the CLI must be auditable to the same standard as the core.

## 0. Product statement

**Keyway stores named secrets and injects the references in `.secrets.env`
into exactly one command.**

It is a secure, local replacement for the **secret-bearing portion** of
`.env` files — for any application in any language, not just Dart. Keyway
owns secrets, not general configuration: non-secret config stays in
application config, the inherited environment, or a plain `.env` the
application loads itself (which composes cleanly with `keyway run`).
Full-dotenv replacement and one-file parity are explicit non-goals (§1) —
ratified, with literals recorded as a compatible future extension gated on
usage evidence (§14, §20).

The repository commits a **manifest** (`.secrets.env`) binding environment
names to **references** (`OPENAI_API_KEY=kw://acme/openai-api-key`). Real
values live in the OS keystore / encrypted container via the `keyway`
library. `keyway run -- npm start` resolves every reference, builds the
child's environment in memory, and executes the command. The child receives
ordinary environment variables; it needs no library, no Dart, no knowledge
of `kw://`.

What this buys, concretely:

- **Nothing secret-derived in the repository, ever.** Unlike the
  encrypted-values-in-repo model (dotenvx), there is no ciphertext in git
  history to protect forever and no key file whose loss decrypts it all.
  Rotation is an ordinary `set`.
- **A repo that is safe to hand to development tools.** An AI agent or
  indexer reading the workspace sees `kw://acme/openai-api-key` — a name,
  not a credential. Robust by construction, not by advisory ignore-files.
- **The environment-variable workflow preserved.** One committed file
  documents exactly which secrets an app needs; a failed `run` lists every
  missing one with the command that fixes it.
- **No account, no server, no daemon, no network.** The entire product is a
  local binary over the already-audited library.

Positioning vs. the 2026 landscape is in Appendix A. The one-line version:
the free/local tools (envchain, envsec, envguard) keep secret *profiles
outside the repo* — no committable contract; the committable-manifest UX
exists only in 1Password's paid `op run`. This CLI is that UX, local-only,
on an audited core.

## 1. Goals / non-goals

**Goals (v1)** — exactly five commands: `run`, `set`, `rm`, `list`,
`doctor` (§5); the reference-only manifest specified exactly (§4); macOS
and Linux desktop; signed, notarized release binaries plus `dart install`;
the whole CLI model understandable from one `--help` screen; two runtime
dependencies, both already audited (§2); zero library changes required.

**Non-goals (v1)** —

| Cut | Why |
|---|---|
| General configuration loading / literal manifest values | Ratified (owner, 2026-07-12): keyway owns secrets, not config. Literals would make it a strict dotenv variant with quoting/precedence surface forever; adding them later is compatible, removing them later never is. Non-secret config composes from app config, inherited env, or the app's own dotenv. |
| Onboarding/convenience commands (`get`, `check`, `fill`, `import`, `init`, `completion`) | Recorded with individual reasoning in §20. The failed `run` *is* the onboarding workflow (§13 Phase 2 acceptance). |
| Windows | Rides the core `WinCredApi` backend ([implementation-plan.md](implementation-plan.md) Phase 5). No interim key-on-disk scheme — that would be S4 storage behind a product that promises S3+ (design.md §9), violating fail-closed. |
| Headless / CI operation | The library fails closed there by design (design.md §12). The CLI's job is a **good error**: this is a dev-machine tool; CI should use the CI platform's secret store. |
| Secret sync / team sharing | The model is per-developer values behind a shared contract. Sharing values is 1Password/Doppler territory — a different product with a server in it. |
| Shell hook / auto-env (direnv-style) | Rejected on principle: exporting secrets into an interactive shell leaks them to *every* subsequently launched process for the session. Run-scoped injection is the model. |
| Output masking; `kw+file://` materialization | Real threat-model responses, deferred with full recorded designs in Appendix C — not scheduled scope. |
| Value interpolation / templating | Injection-shaped surface; a manifest line is a name and a reference, nothing else. |

## 2. Architecture & packaging

Two packages, one repository, per the standing decision (design.md §1 —
the library is a small security primitive; the CLI brings parsing, TTY,
and process concerns that must not enlarge the library's audit surface):

```
keyway_cli   (product: manifest, five commands, prompting, exec)
    │  exact-pinned dependency (pre-1.0)
keyway       (engine: platform storage, container, typed errors — unchanged;
              renamed from secret_store 2026-07-12, pre-publish)
```

- **Repo layout (settled):** pub workspace with `keyway_cli` under
  `packages/`; whether the library also moves under `packages/` is decided
  during the conversion against pub's constraints — the requirements are one
  repo, shared CI, the exact pin, and a valid pub.dev `repository:` link.
- **Zero library changes, zero library asks.** `SecretStorage(appId:)`, the
  verbs, `readAll` (enumeration), `describe()`, and the typed errors cover
  all five commands (§17). The CLI conforms to the small core; the core does
  not grow around CLI convenience. (Attributes-only `contains` shipped in
  core PR #3 independently; on the CLI's v1 platforms the file backend still
  decrypts the whole sealed container for any read, so one `readAll` per
  command remains the right pattern regardless.)
- **Dependency policy (normative):** runtime deps = `keyway` (exact pin) +
  `ffi` (exact pin — already inside the core's audited closure). **No
  `package:args`**: five commands with `--` required for `run` make the
  grammar small enough to hand-parse auditably (the repo's own
  hand-roll-over-depend precedent: the JNI shim, design.md §12). The core's
  dependency-closure snapshot test is replicated for the CLI package; CI
  fails if the tree changes.

## 3. Store mapping — one appId, opaque keys

**One fixed `appId` for the whole CLI**: **`keyway-cli`** (frozen, §16).

**There is no "scope" concept.** A reference `kw://<key>` maps directly to
the library key `<key>`. Keys are opaque slash-separated strings under the
library's existing grammar (`[A-Za-z0-9._/-]{1,120}`, design.md §4) —
`acme/database-password` is organization by convention, not a CLI concept.
No `--scope` flags, no global-vs-scoped semantics, no inference.

Why one appId: one container and **one** keystore item for the store key,
so macOS users see one ACL prompt total (the Model-B consequence design.md
§6 predicts: N secrets, one keychain item); `list` enumerates everything
the CLI manages; and per-project containers would fake an isolation
boundary that doesn't exist — everything is same-user anyway (design.md §8).

Why identity is never inferred from the repo: git-remote inference breaks
on forks; path inference breaks on moves and worktrees. The committed
reference *is* the identity — greppable, and the whole team resolves the
same names. Cross-project sharing is spelled by convention:
`kw://shared/foo`.

## 4. Manifest specification (`.secrets.env`)

The manifest is a **committable contract binding environment names to
secret references — nothing else.** The parser is strict and total
(arbitrary bytes → parse result or typed error, never a crash — the
container TLV precedent, fuzzed the same way).

The complete grammar:

```
# comments and blank lines are allowed
OPENAI_API_KEY=kw://acme/openai-api-key
DATABASE_URL=kw://acme/database-url
```

Normative rules:

- Strict UTF-8; **one** leading BOM is tolerated and stripped (Windows
  editors add them; tolerating one adds no user-facing concept). NUL bytes
  are an error. LF or CRLF. Manifest ≤ 1 MiB, line ≤ 64 KiB.
- Blank lines and lines whose first non-whitespace byte is `#` are ignored.
  There are no inline comments.
- Every other line must match, exactly and with no internal whitespace:

  ```
  [A-Za-z_][A-Za-z0-9_]*=kw://[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*
  ```

  with the key part (after `kw://`) also respecting the library's
  120-character cap, enforced at parse time.
- No literals, no quotes, no escapes, no `export`, no interpolation.
- Duplicate environment names are errors (silent last-wins hides mistakes).
  Multiple environment names may intentionally reference the same key.
- Environment names and keys are case-sensitive.
- Anything else on a non-comment line is a **hard error** naming the line
  and the rule — there is no "treat it as a literal" fallback to hide a
  typo'd reference.

**The tool never writes a manifest** — or any other file in the repository
(SR-3).

## 5. Command surface

The entire surface. No command accepts a secret **value** as an argument
(SR-1); every failure names the exact fix (DX-3); the model fits on one
`--help` screen (DX-6). Global flags: `--help`, `--version`. Nothing else —
no color (so no `--no-color`/`NO_COLOR` machinery), no `--quiet` (success
is already quiet). Data goes to stdout, diagnostics to stderr, everywhere.

| Command | Behavior |
|---|---|
| `keyway run [-f FILE] -- COMMAND [ARGS…]` | The product. **Exactly one manifest**: `-f FILE` or the default `./.secrets.env` — cwd only, no upward search (SR-15), no multi-file composition. `--` is **required**, making parsing unambiguous. Parse → resolve **every** reference → on any failure, list *every* missing key as a ready-to-run `keyway set KEY` line and exit 78 having launched nothing (SR-4) → overlay only the named variables onto the parent environment → `execve` (§6). Two documented idioms replace cut commands: **`keyway run -- true`** is the check ("do all references resolve?" — exit 0 iff yes), and **`keyway run -- printenv KEY`** is the explicit reveal/debug escape hatch, deliberately spelled inside the run-scoped model rather than as a standing extraction command (§20 `get`). |
| `keyway set [--stdin] KEY` | `KEY` is the bare key spelling only (no `kw://` alias — one spelling). Value via interactive hidden prompt (echo off, TTY required), or `--stdin`: strict UTF-8, NUL rejected, exactly one trailing LF or CRLF stripped. No value argument exists (SR-1). No labels — on the v1 platforms the file backend renders them invisible anyway (§20). Prints `Stored.` after interactive input (the human typed blind and deserves an ack); silent with `--stdin`. |
| `keyway rm KEY` | Idempotent, silent whether the key existed or not — matching the library's `delete` semantics and avoiding a check/delete race. |
| `keyway list` | One key per line, sorted. No values, labels, tables, or filtering — stable for ordinary shell composition (`grep`, `wc -l`) without a formal porcelain API. |
| `keyway doctor` | Reports exactly what `describe()` provides plus identity basics: scheme, measured `SecurityLevel`, available/locked, backend detail, CLI version, and **compiled binary vs. Dart VM** — the trust-unit warning (under `dart run`, the keychain ACL unit is the shared VM; design.md §8). No container paths, secret counts, or codesign parsing (§20). |

## 6. `run` semantics

**Environment composition.** Child env = parent environment with **only the
manifest's named variables overlaid** (the resolved references). The
manifest wins on collision — it is the declared contract for those names.
Nothing else is added, removed, or rewritten.

**Execution (POSIX, the only implementation).** Build the child's `envp`
explicitly and replace the process image via FFI `execve`, with our own
PATH resolution (execvp semantics, §18):

- Signals, TTY, exit status, and process-group semantics are inherited by
  construction — no wrapper remains to forward anything, and no resident
  process holds resolved values (SR-7).
- The command is executed **verbatim as an argv vector — never through
  `/bin/sh -c`** (SR-13).
- The wrapper's own environment is never mutated; secrets exist only in the
  `envp` array handed to `execve`.
- **There is no spawn fallback.** On the supported platforms `execve`
  suffices, and an untested second execution path is speculative surface.
  Windows builds its own execution path when it lands with `WinCredApi`.

**Exit codes** (spec, tested):

| Code | Meaning |
|---|---|
| child's code | the child *is* the process once `execve` succeeds |
| 2 | usage error |
| 78 (EX_CONFIG) | manifest invalid, or references unresolved |
| 69 (EX_UNAVAILABLE) | keystore unreachable / locked / store unusable / unsupported platform |
| 70 (EX_SOFTWARE) | internal invariant violated (bug) |
| 75 (EX_TEMPFAIL) | store write lock held by a live peer (`StoreBusy`) — retry |
| 126 / 127 | command found-but-not-executable / not found (pre-exec, from keyway) |
| 128+n | child killed by signal n — reported by the shell, since the child replaced keyway |

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
supersedes that (§14). Read paths (`run`, `list`) remain lock-free by the
library's design — atomic replace guarantees a reader sees a complete old
or complete new store — so a wedged writer can never block launches. The
CLI's only lock-related surface is UX: mapping `StoreBusy` to exit 75 with
retry guidance (§17).

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
  mutation, or "helpful" rewriting.
- **SR-4 — fail closed, atomically.** `run` resolves *everything* before
  starting *anything*. No partial injection, no empty-string placeholder, no
  "warn and continue".
- **SR-5 — inject only what is named.** Exactly the manifest's environment
  names are overlaid; there is no dump-a-namespace mode (contrast envchain).
- **SR-6 — output hygiene.** No secret value in any error, prompt echo, or
  diagnostic — inherits the library's guarantee (design.md §4 "Error
  hygiene") and extends it to everything the CLI prints.
- **SR-7 — memory honesty.** Inherits design.md §8's stance: Dart GC-heap
  copies cannot be zeroed; the CLI does not pretend otherwise. It minimizes
  copies, and on success the wrapper's image (heap included) is replaced
  wholesale by the child.
- **SR-8 — zero network I/O.** The CLI makes no network calls, full stop —
  a checkable product guarantee. Enforcement is honest about its mechanism:
  the pinned dependency closure contains no networking code, and the CLI's
  own surface is small enough to audit for `Socket`/`HttpClient` use; there
  is no sandbox pretending to enforce it at runtime.
- **SR-9 — supply-chain parity with the core.** Runtime deps: `keyway` +
  `ffi`, both exact-pinned. Closure snapshot test in CI; OSV scanning; the
  same "a pin moves only by reviewed decision" rule (design.md §10).
- **SR-10 — mutation safety is inherited, not reimplemented.** Every store
  mutation goes through the library's verbs, which serialize writers across
  isolates and processes via the cross-writer `flock` (design.md §7). The
  CLI adds no locking, no lock files, and no mutating path outside those
  verbs; contention surfaces as `StoreBusy`, mapped per §17.
- **SR-11 — release identity.** macOS release binaries are Developer-ID
  signed and notarized. Not (only) for Gatekeeper: the login-keychain ACL on
  the store-key item binds to the acting binary's code identity (design.md
  §8), so an unstable identity means a re-prompt per upgrade — the category's
  best-known papercut (envchain). `doctor` surfaces the VM-vs-compiled
  trust-unit state; pub-channel installs carry the documented caveat.
- **SR-12 — prompts require a TTY.** Interactive value entry refuses
  redirected stdin (use `--stdin`); no prompt can hang a script.
- **SR-13 — no shell interpretation.** The child command is an argv vector
  executed directly; the CLI never invokes a shell on the user's behalf.
- **SR-14 — no downgrade, good guidance.** Unsupported platform / unreachable
  keystore surfaces the library's typed error plus CLI-level remediation
  (unlock keychain; SSH note; "use CI secrets in CI"). Never a weaker scheme.
- **SR-15 — manifest discovery is non-magical.** Exactly one manifest per
  invocation: `-f` or `./.secrets.env`. No upward search, no home-dir
  fallback, no env-var override of the default (a polluted environment must
  not be able to redirect resolution), no multi-file composition.
- **SR-16 — env values are validated before `envp`.** A referenced value
  must decode as UTF-8 and contain no NUL (a NUL would silently truncate
  the `envp` entry — an injection-shaped bug). Violations are typed errors
  naming the key, never a silent mangle; only referenced values are decoded
  at all (§18).

## 9. Threat model (delta over design.md §8)

The library's threat model covers secrets **at rest**. The CLI adds the
injection step, and the honest statement of the boundary is:

**What `run` protects:** the repository (nothing secret-derived is ever in
it); the disk (no plaintext secret `.env` lines); backup/sync/indexing/agent
exposure of the working tree; casual disclosure (argv, scrollback, shell
history).

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
(Appendix C — env carries a path, not a value; defeats inheritance and env
inspection), **3)** env injection (the universal default this CLI ships).
The docs and `doctor` teach the ladder rather than implying env injection
is more than it is. Same-user malware, root, and the child's own conduct
remain out of scope at every tier.

## 10. DX requirements (normative)

- **DX-1 — zero-config happy path.** In a repo with `./.secrets.env`,
  `keyway run -- <cmd>` works with no flags, no config, no init.
- **DX-2 — fast.** AOT binary; `run` overhead (parse + resolve + exec) under
  50 ms on a warm keystore. No daemon; nothing to warm.
- **DX-3 — every error names the fix.** Each typed library error and each
  CLI error maps to remediation text with the literal command to run (§17).
- **DX-4 — onboarding is the failed run.** `run` fails → it prints every
  `keyway set KEY` needed → the user runs them → `run` succeeds. No separate
  onboarding workflow exists, and none is needed.
- **DX-5 — plays well with scripts.** Stable stdout/stderr split; meaningful
  exit codes (§6); `list` is one-key-per-line. Machine consumption beyond
  that waits for evidence (§20).
- **DX-6 — the whole model fits on one help screen.** Five commands, two
  global flags, one manifest grammar. This is an acceptance criterion, not
  an aspiration (§13 Phase 1).

## 11. Distribution & release

1. **GitHub Releases (primary):** per-platform `dart compile exe` binaries
   from a CI matrix (macOS arm64/x64, Linux x64/arm64), macOS ones signed +
   notarized + stapled (SR-11), SHA-256 sums + build provenance attestation.
   Honest note: Dart AOT builds are not bit-reproducible; provenance is the
   compensating control.
2. **Homebrew tap** (`brew install danreynolds/tap/keyway`), day one;
   homebrew-core once traction justifies it. Scoop/winget when Windows lands.
3. **`dart install keyway_cli`** for the Dart-native audience, with the
   documented identity caveat (§5 `doctor`, design.md §8): a pub-channel
   install's keychain trust unit is the VM or an ad-hoc-signed binary, so
   ACL prompts may recur; the signed release binary is the promoted channel
   for everyone else. The "any language" positioning fails if the answer to
   "how do I install it" starts with "install Dart".
4. **Registrations:** Appendix B's checklist — `keyway.dev`, pub.dev names,
   npm/PyPI reclamation filings, scoped-org fallbacks. (The GitHub repo
   rename to `danReynolds/keyway` is done, 2026-07-12.)

Release train: the CLI pins the exact core version; a core release triggers a
reviewed CLI pin-bump release. Independent CHANGELOGs; per-package tags.

## 12. Testing

The core's bar applies: every claim exercised for real, not mocked
(README "Testing").

- **Unit tier:** manifest parser — table-driven spec tests plus a **fuzz
  harness** (arbitrary bytes → typed error or valid parse, never a crash);
  the entry regex including the 120-char cap and BOM/NUL/CRLF handling;
  env composition (named-vars-only overlay); exit-code mapping;
  remediation-text mapping for every typed core error (§17); UTF-8/NUL
  value validation (SR-16).
- **Command tier:** all five commands against
  `SecretStorage.withBackend(fake)` — the exported test hatch exists for
  exactly this (design.md §4).
- **Leak tier (SR-2/SR-6):** plant sentinel values; drive every error path
  and prompt path; assert the sentinel never appears in any output. A PTY
  harness verifies echo-off and echo-restoration on interrupt.
- **Integration tier:** real keystores in CI exactly like the core (macOS
  Keychain; Linux via `dbus-run-session` gnome-keyring in Docker):
  `set → run → child sees value → rm` round-trips; exec-path PATH/exit/
  signal fidelity; cross-writer serialization (two concurrent `set`s → no
  lost update, courtesy of the library's flock; a deliberately wedged
  holder → `StoreBusy` as exit 75 with retry text); locked-keystore
  guidance path.
- **E2E:** `tool/test_cli.sh` joining the existing `tool/` suite; the
  README quickstart executed verbatim on both platforms.
- **Supply chain:** the CLI's own dependency-closure snapshot test.

## 13. Phases

**Phase 1 — contract and pure logic.** Workspace conversion
(`packages/keyway_cli`); the five-command hand parser; the reference-only
manifest parser + fuzz harness; reference resolution and environment
composition; `set`, idempotent `rm`, one-key-per-line `list`; exhaustive
fake-backend command tests and output-leak tests.
*Acceptance:* the entire CLI model can be understood from one help screen.

**Phase 2 — native process execution.** `execve` + final-environment PATH
resolution, tested across direct paths, PATH search, missing commands,
permissions, scripts, exit codes, signals, TTY inheritance, and UTF-8/NUL
rejection; hidden prompting with PTY echo-restoration tests; minimal
`doctor`; real macOS Keychain and Linux Secret Service round trips.
*Acceptance:* `run` fails → lists missing keys → user runs `set` for each →
`run` succeeds. No separate onboarding workflow exists.

**Phase 3 — release.** Freeze the macOS signing identifier and entitlement
set; compile, sign, notarize, staple macOS binaries; Linux artifacts;
checksums + provenance; Homebrew and `dart install` validated from clean
machines; the documented quickstart executed verbatim on macOS and Linux;
Appendix B registration checklist completed.
*Acceptance:* a person with no Dart toolchain installs and onboards a repo
in under five minutes on macOS and Linux.

## 14. Decision log

- **References-in-repo over ciphertext-in-repo (dotenvx's model).** Nothing
  secret-derived in git history; rotation is mundane; the cost — no value
  sync between teammates — is deliberate and served by the failed-run
  onboarding loop. Positioning: solo devs, OSS bring-your-own-key repos,
  agent-safe working trees.
- **Reference-only manifests — ratified by the owner, 2026-07-12.** The one
  scope decision treated as a product call, per two independent reviews
  (both ~60/40 for reference-only). Decisive argument: reversibility —
  literals can be added compatibly later; removing them would break every
  manifest. Consequences owned explicitly: keyway is not a dotenv
  replacement; one-file parity is a non-goal; migration guidance is "your
  `.env` keeps its non-secret lines and loses its secret ones."
- **Five-command surface (two-round RFC review, 2026-07-12).** Everything
  beyond `run`/`set`/`rm`/`list`/`doctor` is cut or deferred with recorded
  reasoning (§20). Review's framing, adopted as a standing rule: omission
  is reversible; premature surface area is not.
- **`get` rejected** — a standing plaintext-extraction command invites
  `export X=$(keyway get …)`, the exact pattern the shell-hook non-goal
  exists to prevent. The run-scoped idiom `keyway run -- printenv KEY` is
  the documented escape hatch.
- **`check` rejected as a command** — a failed `run` is a complete check
  report, and `keyway run -- true` is the exit-code form. Documented, not
  shipped.
- **`rm` is idempotent and silent** — matches the library's `delete`
  semantics and removes a check/delete race.
- **No `package:args`** — the grammar is small enough to hand-parse
  auditably; `--` required on `run` keeps it unambiguous.
- **No spawn fallback** — untested second execution path = speculative
  surface; Windows builds its own when it exists.
- **No scope concept** — `kw://<key>` maps to the opaque library key;
  slashes are convention, not semantics.
- **Labels cut** — on the v1 platforms the resolver always lands on the
  file backend, where labels surface in no UI at all.
- **One leading BOM tolerated** — friction removal without a user-facing
  concept.
- **`Stored.` after interactive `set`** — the human typed blind; one ack
  line is UX feedback, not API breadth. Silent with `--stdin`.
- **Explicit scope strings; no repo-identity inference** (§3).
- **One appId, opaque namespaced keys** (§3).
- **Manifest references win over inherited env for the named variables** —
  the declared contract beats the accident.
- **No shell hook mode; no upward manifest search; no env-var default
  override** (§1, SR-15).
- **`execve` only; never a shell; `set` has no value-argument form.**
- **Windows waits for `WinCredApi`.** No S4 interim.
- **The lock lives in the CLI, not the library.** *(Superseded the same
  day, 2026-07-12: core PR #3 reinstated the cross-writer `flock` inside
  the library. The CLI inherits mutation locking and ships none of its
  own; §7, SR-10.)*
- **`deleteAll()` questions leave this RFC** — raised during review, then
  withdrawn as CLI fallout on the correct grounds that "unused by this CLI"
  is not a reason to change a library API. The genuine library question
  (healthy-store wipe convenience vs. a deliberately-named destructive
  reset that can recover an *unreadable* store — today's `deleteAll` begins
  with `readAll()` and cannot) is recorded in
  [research-agenda.md](research-agenda.md) §15 for its own review.
- **Name: `keyway`; scheme `kw://`; appId `keyway-cli`; manifest filename
  `.secrets.env`** (2026-07-12; §16, Appendix B).

## 15. Open questions

None at this time. The next decision point is the Phase 1 completion
review.

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
Verbs: `readAll()` (run/list — gated on
`backend.capabilities.enumeration`, true for both v1 platforms),
`writeString(key, value)` (set), `delete` (rm), `describe()` (doctor).

Error → CLI behavior map (exhaustive over the exported taxonomy; the leak
tier drives every row):

| Typed error | Exit | CLI remediation text (gist) |
|---|---|---|
| `KeystoreLocked` | 69 | login keychain / Secret Service is locked — how to unlock; "over SSH this is expected: keyway is a dev-machine tool" |
| `KeystoreUnreachable` | 69 | no keystore here (headless/unsupported) — dev-machine tool; use the CI platform's secrets in CI |
| `StoreKeyMissing` | 69 | container exists but its key is gone from the keystore — unrecoverable without a key backup (design.md §7 matrix); re-provision with `keyway set` |
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
→ 78 with the per-key fix list; bad invocation → 2.

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
- **Prompt echo restoration:** set `stdin.echoMode = false`, restore in
  `finally` **and** in a `ProcessSignal.sigint.watch` handler (exit 130
  after restoring) — a Ctrl-C mid-prompt must not leave the user's terminal
  silent. PTY test asserts both paths.
- **`--stdin` byte handling:** read to EOF as bytes; strict UTF-8 decode
  (reject on failure); reject NUL; strip exactly one trailing LF or CRLF.
  Values are stored via `writeString` — the env boundary is string-shaped
  anyway (env vars cannot carry NUL); binary secrets belong to the library
  tier, not the env tier.
- **`readAll()` handling (SR-16):** decode **only the referenced values**
  from the returned `Map<String, Uint8List>`; a referenced value that fails
  UTF-8 decode or contains NUL is a typed CLI error naming the key (it was
  stored via the bytes API — point at the library tier), never a silent
  mangle. Unreferenced values are never decoded.
- **Closure snapshot test:** replicate the core's `dart pub deps --json`
  snapshot for `keyway_cli`; the snapshot embeds package names, so it also
  pins the exact core version (§2's pin made testable).
- **Output discipline:** data → stdout, diagnostics → stderr, everywhere
  (`list` prints only keys to stdout). This is what makes shell composition
  safe without a porcelain mode.

## 19. Golden transcripts (acceptance sketches)

Phase 2 turns these into assertions. Set + run, the happy path:

```console
$ keyway set acme/openai-api-key
Value for acme/openai-api-key (input hidden):
Stored.

$ keyway run -- npm start
> acme-api@1.0.0 start
listening on :3000

$ ps -o pid,ppid,command | grep node
81234  9021  node server.js          # parent is the shell — keyway exec'd away
```

Fail-closed run (SR-4, DX-3/DX-4) — this *is* the onboarding workflow:

```console
$ keyway run -- npm start
error: 2 of 3 references in .secrets.env are not set on this machine:

  keyway set acme/database-password
  keyway set shared/stripe-test-key

Nothing was launched.
$ echo $?
78
```

The check idiom (exit 0 iff every reference resolves):

```console
$ keyway run -- true && echo ready
ready
```

`doctor`, macOS unentitled-CLI branch:

```console
$ keyway doctor
scheme:     encrypted file + login-Keychain key   (macOS, unentitled CLI)
level:      loginBound (S3)                        # measured, not assumed
keystore:   reachable, unlocked
binary:     compiled executable (stable keychain identity)
keyway:     0.1.0
```

## 20. Deferred and rejected surface (record, not roadmap)

Per the review framing adopted in §14: these are recorded as rejected or
unproven ideas. **Reconsider only with usage evidence.** None are v1.x
promises.

| Idea | Status | Reasoning |
|---|---|---|
| `get` | **Rejected** | A standing plaintext-extraction command creates the `$(keyway get …)` scripting path outside the run-scoped model. `keyway run -- printenv KEY` is the documented escape hatch. |
| `check` | **Rejected** | `keyway run -- true` is the check; a failed `run` is the report. |
| `fill` | Unproven | The failed-run loop covers onboarding at typical secret counts. |
| `import` | Unproven | With reference-only manifests its job shrinks to "set the secret lines"; the manual flow is acceptable and dodges literal/secret triage UX. |
| `init` | Unproven | The grammar is three lines in the README. |
| `completion` | Unproven | Five commands; marginal value against permanent maintenance. |
| Labels | Rejected for v1 | Invisible on the v1 platforms (file backend; no keystore UI shows them). |
| Multiple manifests / composition | Unproven | Precedence rules are surface; one contract per invocation. |
| Literal manifest values | **Owner-rejected for v1** | The ratified product decision (§14). Compatible to add later if migration evidence demands. |
| Scope as a concept / `--scope` filtering | Rejected | Slashes are convention; a second naming concept buys nothing. |
| JSON/porcelain output | Unproven | Exit codes + one-key-per-line suffice until someone's script says otherwise. |
| `doctor` signing inspection / container paths / counts | Unproven | `BackendInfo` + VM-vs-compiled covers the security-relevant part. |
| Output masking; `kw+file://` | Recorded designs | Appendix C — real threat-model responses preserved with their trade-offs. |

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
dispute and a PyPI PEP 541 request; a future npm wrapper channel works as
`@keyway/cli` either way.

**Registration checklist (owner actions):** ~~rename the GitHub repo~~
(done 2026-07-12 — `danReynolds/keyway`; pubspec updated); register
`keyway.dev` (unregistered as of 2026-07-12); reserve the GitHub `keyway`
org name if available; publish stub/placeholder packages where free
(crates) or scoped (`@keyway` npm org); file the npm/PyPI reclamations; a
five-minute USPTO TESS sanity pass on "KEYWAY" for software goods.

## Appendix C — recorded designs, not scheduled scope

*Preserved because each answers a named limitation in §9's threat model.
Reconsider only with usage evidence. Recording is not scheduling.*

**`kw+file://` materialization (the `*_FILE` convention).** For a manifest
entry like `DATABASE_PASSWORD_FILE=kw+file://acme/database-password`,
materialize the value into a `0600` file inside a per-run `0700` runtime
directory (`XDG_RUNTIME_DIR` on Linux; the Darwin per-user temp dir on
macOS), put only the *path* in the environment, unlink after the child
exits, and sweep stale run-dirs on the next invocation (crash cleanup).
Defeats both env inheritance to descendants and same-user env inspection —
the two sharpest limits of tier 3 — and the Docker-official-images
ecosystem (`POSTGRES_PASSWORD_FILE`, …) already honors the convention.
Costs: a secret touches the filesystem (tmpfs-backed on Linux; not
guaranteed on macOS), crash-window cleanup, and a second reference scheme
to explain.

**Output masking (`op run` precedent).** Interpose pipes on the child's
stdout/stderr and redact any occurrence of a resolved secret value before
forwarding. Directly mitigates the child logging its own secrets. Costs:
the child no longer sees a TTY (`isatty=false` changes colors, prompts,
buffering), keyway becomes a resident wrapper again (undoing §6's
exec-and-vanish), and redaction is bypassable by any encoding of the value.
If ever built: opt-in `--mask`, never default, with the TTY trade-off
documented.
