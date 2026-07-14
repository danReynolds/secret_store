# keyway CLI (`keyway_cli`) — implementation plan

*Implementation contract for the `keyway_cli` package. It records the product
design, the DX and security requirements, the frozen constants, and the
implementation context, so the build and review proceed from conclusions
rather than re-deriving them. Where this file and the as-built code disagree,
the code wins and this file gets corrected.*

*Naming is settled (2026-07-12): the product and executable are **`keyway`**,
the CLI package is **`keyway_cli`**, and the library — formerly
`secret_store`, never published under that name — is renamed **`keyway`**.
The naming record is Appendix B; constants that froze with the name are §16.*

*v1 scope is settled: **five commands, mixed manifests** (literals +
`kw://` references). The command surface came out of a two-round
independent RFC review (2026-07-12); the manifest model was ratified
reference-only the same day and deliberately superseded by mixed on
2026-07-13 when the per-environment workflow was weighed (§14 records
both). The review's governing insight is recorded here because it should
govern future scope debates too: **omission is reversible; premature
surface area is not.** Cut features are recorded in §20 and Appendix C
with their reasoning — as evidence-gated ideas, not as a roadmap.*

*Reference identity is settled (2026-07-13): every key has one explicit,
mandatory namespace embedded in its reference. The namespace affects identity
only; it adds no flags, filtering, inference, storage isolation, or
authorization. All namespaces remain in one physical CLI store (§3).*

Governing rules, inherited from [implementation-plan.md](implementation-plan.md)
and extended: **one clear way to do things**; **the library stays the security
engine** (the CLI adds workflow, never crypto or storage policy); **fail
closed, never downgrade**; **in v1, no value resolved by Keyway is placed in
argv, a CLI-owned log or error, or a file the CLI writes**; **small code =
small attack surface** — the CLI must be auditable to the same standard as the
core. User-supplied child arguments and child output remain the caller's and
child's responsibility (§9). A recorded future design that deliberately
changes one of these invariants (Appendix C's file materialization) must reopen
the invariant explicitly; recording it is not an exception to the shipped
contract.

## 0. Product statement

**Keyway turns `.env` into one committable manifest: non-secret config stays
literal, secret values become `kw://` references, and `keyway run` injects
both into exactly one command.**

It is a secure, local replacement for plaintext `.env` files — for any
application in any language, not just Dart. One committed file per
environment (`.secrets.env` by default; `.secrets.staging.env` via `-f`)
carries the complete environment contract: non-secret literals plainly,
secrets as references. (Mixed manifests ratified 2026-07-13, superseding
the earlier reference-only ruling — §14.) What keyway refuses to become is
a dotenv *dialect* parser: literals carry no quoting, escaping, or
interpolation semantics, ever (§1, §4).

The repository commits a **manifest** (`.secrets.env`) holding non-secret
literals (`API_URL=https://…`) and secret **references**
(`OPENAI_API_KEY=kw://acme-payments/openai-api-key`). Real values live in the OS
keystore / encrypted container via the `keyway` library.
`keyway run -- npm start` resolves every reference, builds the child's
environment in memory, and executes the command. The child receives
ordinary environment variables; it needs no library, no Dart, no knowledge
of `kw://`.

What this buys, concretely:

- **Keyway-managed secret values stay out of the repository.** Unlike the
  encrypted-values-in-repo model (dotenvx), there is no ciphertext in git
  history to protect forever and no key file whose loss decrypts it all.
  Rotation is an ordinary `set`. Mixed manifests cannot prove a literal is
  non-secret; that classification remains visible and reviewable (§4, §9).
- **References are safe to hand to development tools.** An AI agent or
  indexer reading a correctly classified manifest sees
  `kw://acme-payments/openai-api-key` — a name, not a credential. That
  structural property applies to references; literals remain ordinary
  committed text.
- **The environment-variable workflow preserved.** One committed file
  documents exactly which secrets an app needs; a failed `run` lists every
  missing one with the command that fixes it.
- **No account, no server, no daemon, no network.** The entire product is a
  local binary over the already-audited library.

Positioning vs. the 2026 landscape is in Appendix A. The one-line version:
most free/local tools (envchain, envsec, envguard) keep secret *profiles
outside the repo* — no committable contract. SecretSpec is the closest
identified analogue: a committed declaration and project/profile-qualified
keyring storage, but with a provider matrix and broader command surface.
Keyway takes the austere path: an `.env`-shaped manifest, one storage model
per platform, five commands, and an audited minimal-dependency core.

## 1. Goals / non-goals

**Goals (v1)** — exactly five commands: `run`, `set`, `rm`, `list`,
`doctor` (§5); the mixed, explicitly namespaced manifest format specified
exactly (§4); macOS and Linux desktop; signed, notarized release binaries plus
`dart install`;
the whole CLI model understandable from one `--help` screen; two runtime
dependencies, both already audited (§2); zero library changes required.

**Non-goals (v1)** —

| Cut | Why |
|---|---|
| Dotenv-dialect compatibility (quotes, escapes, multiline, inline comments, interpolation) | Literal values are ASCII-trimmed after `=` and otherwise uninterpreted (§4). Keyway defines one strict format; it does not parse the dotenv dialect zoo, and a keyway manifest is not promised to round-trip through dotenv tools or vice versa. |
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

- **Repo layout (settled):** the existing `keyway` library stays at the
  repository root, which also becomes the pub workspace root;
  `packages/keyway_cli/` is the workspace member. Moving the established core
  would add churn without improving the package boundary. The workspace has
  one resolution and lockfile, shared CI, an exact core pin, and valid per-
  package pub.dev `repository:` links. The CLI package exposes only
  `bin/keyway.dart` through `executables: {keyway: keyway}`; it does not export
  a second Dart library API. Core publication uses a clean-checkout, explicit-
  allowlist staging directory that omits `packages/` and removes the repository-
  only `workspace:` field from the staged pubspec. This is necessary because a
  root `.pubignore` exclusion for `packages/` is inherited by workspace members
  and would also empty the separately published CLI archive.
- **CLI SDK floor:** Dart `^3.10.0`. The primary release binaries need no Dart
  installation; the Dart-native channel can therefore use the single current
  `dart install keyway_cli` spelling without carrying the pre-3.10 activation
  path as another documented workflow. The library keeps its independent,
  lower SDK floor.
- **Zero library changes, zero library asks.** `SecretStorage(appId:)`, the
  verbs, `readAll` (enumeration), `backend.describe()`, and the typed errors
  cover all five commands (§17). The CLI conforms to the small core; the core
  does not grow around CLI convenience. (Attributes-only `contains` shipped
  in core PR #3 independently; on the CLI's v1 platforms the file backend
  still decrypts the whole sealed container for any read, so one `readAll`
  per command remains the right pattern regardless.)
- **Dependency policy (normative):** runtime deps = `keyway` (exact pin) +
  `ffi` (exact pin — already inside the core's audited closure). **No
  `package:args`**: five commands with `--` required for `run` make the
  grammar small enough to hand-parse auditably (the repo's own
  hand-roll-over-depend precedent: the JNI shim, design.md §12). The core's
  dependency-closure snapshot test is replicated for the CLI package; CI
  fails if the tree changes.

## 3. Store mapping — one appId, mandatory namespaces

**One fixed `appId` for the whole CLI**: **`keyway-cli`** (frozen, §16).

**Every key has one explicit namespace embedded in its reference.** A
reference `kw://<namespace>/<key…>` maps directly to the library key
`<namespace>/<key…>`. The CLI accepts this narrower, shell-safe grammar:

```
[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*
```

with a 120-character cap on the complete key. At least two slash-separated
segments are required, and every segment starts with an alphanumeric
character. The same grammar is used by the manifest, `set`, and `rm`, so the
CLI can never create a key its manifest cannot reference; a single-segment
machine-global key such as `openai-api-key` is unrepresentable through the
CLI.

The first segment is the namespace. The documented convention is
`<organization>-<project>` (`acme-payments/openai-api-key`) for project values
and `<organization>-shared` (`acme-shared/openai-api-key`) for deliberate
cross-project reuse. The complete qualified name is the identity:
two repositories using the same full reference deliberately share one stored
value, while different namespaces resolve independently even when both inject
`OPENAI_API_KEY`. The namespace adds no `--scope` flag, filtering, discovery,
inference, storage isolation, or authorization. `list` remains global and
prints complete qualified names. The broader library grammar remains a
library concern; the fixed `keyway-cli` appId is owned by this CLI.

**Namespaces organize; they do not isolate.** Any same-user process able to
run Keyway can request any CLI key it can name. Qualification prevents
accidental identity collisions; it is not a confidentiality boundary (§9).

Why require a namespace: without it, two repositories independently choosing
the obvious `openai-api-key` would silently read, overwrite, and remove the
same entry. Requiring qualification makes accidental cross-project reuse
harder while preserving deliberate sharing. It is also the conservative
pre-1.0 choice: the grammar can be relaxed compatibly later, while requiring
qualification after bare keys ship would break existing manifests.

Why one appId: one container and **one** keystore item for the store key (the
Model-B consequence design.md §6 predicts: N secrets, one ACL-bearing item).
The core never initiates authentication UI: an identity mismatch fails typed
rather than prompting, and stable release signing keeps upgrades authorized to
the same item. Per-namespace containers would multiply store keys, recovery
states, and locking paths without creating an authorization boundary —
everything is same-user anyway (design.md §8). Physical sharding therefore
waits for store-size or recovery evidence (§20).

Why identity is never inferred from the repo: git-remote inference breaks
on forks; path inference breaks on moves and worktrees. The committed
reference *is* the identity — greppable, and the whole team resolves the
same names. Cross-project sharing is conspicuous and explicit:
`kw://acme-shared/foo`.

## 4. Manifest specification (`.secrets.env`)

The manifest is a **committable contract binding environment names to
non-secret literals and secret references.** The parser is strict and
total (arbitrary bytes → parse result or typed error, never a crash — the
container TLV precedent, fuzzed the same way).

The default filename is **`.secrets.env`**; per-environment manifests are
ordinary files selected with `-f`, with `.secrets.<env>.env` as the
documented convention. The documented idiom for describing a secret (what
it is, where to get it) is a plain comment above its line — human
documentation, never parser semantics (§14).

The complete grammar:

```
# comments and blank lines are allowed
# Stripe test-mode key — dashboard.stripe.com/test/apikeys
API_URL=https://staging.api.acme.dev
LOG_LEVEL=debug
OPENAI_API_KEY=kw://acme-payments/openai-api-key
DATABASE_URL=kw://acme-payments/database-url
# acme-shared deliberately reuses one value across repositories
STRIPE_KEY=kw://acme-shared/stripe-test-key
```

Normative rules:

- Strict UTF-8; **one** leading BOM is tolerated and stripped (Windows
  editors add them; tolerating one adds no user-facing concept). NUL bytes
  are an error. LF or CRLF. Manifest ≤ 1 MiB, line ≤ 64 KiB.
- Blank lines (empty or ASCII space/tab only) and lines whose first non-space/
  tab byte is `#` are ignored. Unicode whitespace has no special meaning.
  There are no inline comments — a `#` after `=` is part of the value.
- Entries are `NAME=VALUE`: `NAME` matches `[A-Za-z_][A-Za-z0-9_]*`,
  immediately followed by `=`; `VALUE` is everything after the first `=`
  with ASCII spaces and tabs trimmed at both ends. Anything else on a
  non-comment line is a hard error naming the line number and the rule.
- If the trimmed `VALUE` starts with `kw://`, it **must** parse as a
  reference whose key matches
  `[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*`
  and is at most 120 characters. Thus every segment starts alphanumeric and
  at least two segments are required; `kw://openai-api-key` is a hard error
  naming `kw://acme-payments/openai-api-key` as the shape of the fix. A
  typo'd reference never silently becomes a literal.
- Otherwise the trimmed `VALUE` is a **literal** with no further
  interpretation: no quote stripping, escapes, interpolation, `export`, or
  line continuation. An empty `VALUE` sets the variable to the empty string.
  Leading/trailing whitespace and embedded newlines are unsupported — that is
  application-config territory.
- Duplicate environment names are errors (silent last-wins hides mistakes).
  Multiple environment names may intentionally reference the same key.
- Environment names and keys are case-sensitive.
- **A literal is committed plaintext.** The grammar cannot verify that a
  literal is not a secret; that guard is review visibility (a high-entropy
  literal in a diff is a red flag) and documentation. The structural
  guarantee is narrower and still real: a `kw://` line never carries a
  value, and the reference grammar cannot be satisfied by one.
- Open the manifest once and read a bounded stream of at most 1 MiB + 1 byte;
  the extra byte triggers the size error. A separate metadata preflight is
  neither necessary nor accepted as enforcement because the file could change
  between checking and reading.
- Parse diagnostics never repeat the offending line or bytes. Mixed manifests
  can contain plaintext, so even malformed input is treated as potentially
  secret-bearing.

**The tool never writes a manifest** — or any other file in the repository
(SR-3).

## 5. Command surface

The entire surface. No command accepts a secret **value** as an argument
(SR-1); every failure names the next action (DX-3); the model fits on one
`--help` screen (DX-6). Global flags: `--help`, `--version`. Nothing else —
no color (so no `--no-color`/`NO_COLOR` machinery), no `--quiet` (success
is already quiet). CLI-owned data goes to stdout and diagnostics to stderr;
the child inherits its own stdout/stderr unchanged.

| Command | Behavior |
|---|---|
| `keyway run [-f FILE] -- COMMAND [ARGS…]` | The product. **Exactly one manifest**: explicit `-f FILE`, or the default `./.secrets.env` looked up in cwd only — no upward search (SR-15), no multi-file composition. `--` is **required**, making parsing unambiguous. Parse → resolve **every** reference → on any failure, list *every* missing key as a ready-to-run `keyway set KEY` line and exit 78 having launched nothing (SR-4) → overlay literals and resolved references onto the parent environment → `execve` (§6). A manifest with no references never constructs or reads `SecretStorage`; it executes with only the literal overlays. Two documented idioms replace cut commands: **`keyway run -- true`** is the check ("do all references resolve?" — exit 0 iff yes), and **`keyway run -- printenv ENV_NAME`** is the explicit reveal/debug escape hatch, deliberately spelled inside the run-scoped model rather than as a standing extraction command (§20 `get`). |
| `keyway set [--stdin] KEY` | `KEY` is the qualified key spelling only — the same at-least-two-segment grammar as a manifest reference, without `kw://` (`acme-payments/openai-api-key`). There is no scheme-bearing alias, and a single-segment key is a usage error. Value via interactive hidden prompt (echo off, TTY required), or `--stdin`: bounded by the core's 16 MiB store envelope, strict UTF-8, NUL rejected, exactly one trailing LF or CRLF stripped. No value argument exists (SR-1). No labels — on the v1 platforms the file backend renders them invisible anyway (§20). Prints `Stored.` to stderr after interactive input (the human typed blind and deserves an ack); silent with `--stdin`. |
| `keyway rm KEY` | `KEY` uses the same qualified grammar as `set`. Removal is idempotent and silent whether the key existed or not — matching the library's `delete` semantics and avoiding a check/delete race. |
| `keyway list` | One complete qualified key per line, sorted across the single CLI store. No values, labels, tables, namespaces-as-filters, or other filtering — stable for ordinary shell composition (`grep`, `wc -l`) without a formal porcelain API. |
| `keyway doctor` | Reports exactly what `backend.describe()` provides plus identity basics: scheme, measured `SecurityLevel`, available/locked, backend detail, CLI version, and **compiled binary vs. Dart VM** — the trust-unit warning (under `dart run`, the keychain ACL unit is the shared VM; design.md §8). It never equates "compiled" with a stable signature: codesign is not inspected. No container paths, secret counts, or codesign parsing (§20). Exit 0 iff the backend reports available and unlocked; otherwise print the health report and exit 69. |

## 6. `run` semantics

**Environment composition.** Child env = parent environment with **only the
manifest's named variables overlaid** — non-secret literals and resolved
references, one uniform rule. The manifest wins on collision — it is the
declared contract for those names. Nothing else is added, removed, or
rewritten.

**Execution (POSIX, the only implementation).** Build the child's `envp`
explicitly and replace the process image via FFI `execve`, with the deliberate
execvp-like PATH contract specified in §18:

- Signals, TTY, exit status, and process-group semantics are inherited by
  construction — no wrapper remains to forward anything, and no resident
  process holds resolved values (SR-7).
- The command is executed **verbatim as an argv vector — never through
  `/bin/sh -c`** (SR-13).
- The wrapper's own process environment is never mutated. Resolved values are
  encoded into the `envp` handed to `execve`, with the unavoidable transient
  Dart/native copies acknowledged by SR-7.
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

Each SR is a reviewable contract; §12 maps mechanically enforceable claims to
tests and §13 carries the release-only gates. Limits that cannot be proven by a
unit test are stated as such rather than converted into theater.

- **SR-1 — no resolved values in argv.** No Keyway command accepts a managed
  value as an option or positional (`set NAME VALUE` does not exist), and no
  value read from Keyway is synthesized into the child's argv. `COMMAND` and
  `ARGS` are user-supplied and forwarded verbatim; callers remain responsible
  for not putting secrets there. Process argv is broadly observable on the
  supported systems; environment values are still same-user-readable and are
  not treated as a secrecy boundary (§9).
- **SR-2 — no Keyway-managed plaintext persistence in v1.** The CLI writes no
  value resolved or entered through Keyway to any file: no temp files, no
  caches, no logs. A user-authored manifest literal is already plaintext on
  disk and outside this guarantee (§4, §9). Prompts run with echo off,
  restored on every supported completion, termination, and suspend path; the
  uncatchable OS/runtime limits are explicit in §18. Keyway creates no extra
  plaintext persistence: values necessarily transit terminal or pipe buffers,
  process memory, and (for `run`) the child's environment before the library
  persists only its encrypted representation.
- **SR-3 — the CLI never writes into the repository.** No manifest creation,
  mutation, or "helpful" rewriting.
- **SR-4 — fail closed, atomically.** `run` parses the whole manifest and
  resolves every reference before starting anything. No partial injection, no
  empty-string placeholder for a missing reference, no "warn and continue".
- **SR-5 — inject only what is named.** Exactly the manifest's environment
  names are overlaid; there is no dump-a-namespace mode (contrast envchain).
- **SR-6 — output hygiene.** No value resolved or entered by Keyway appears in
  a CLI-owned error, prompt echo, status, or diagnostic — inheriting the
  library's guarantee (design.md §4 "Error hygiene"). Child output is outside
  this guarantee (§9, §12).
- **SR-7 — memory honesty.** Inherits design.md §8's stance: Dart GC-heap
  copies cannot be zeroed; the CLI does not pretend otherwise. It minimizes
  copies, and on success the wrapper's image (heap included) is replaced
  wholesale by the child.
- **SR-8 — zero network I/O.** Before `execve`, the CLI makes no network calls,
  full stop — a checkable product guarantee. The executed child is outside
  that guarantee. Enforcement is honest about its mechanism:
  there are no network package dependencies, and the CLI's small source is
  audited for `Socket`/`RawSocket`/`HttpClient`/`WebSocket` use. `dart:io`
  necessarily contains networking APIs alongside the file/process APIs the
  CLI uses, so the dependency closure alone cannot prove this property; there
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
  §8). Because the core disables authentication UI, an identity mismatch fails
  typed rather than opening a prompt; stable identity prevents upgrades from
  losing access. `doctor` surfaces the VM-vs-compiled
  trust-unit state; pub-channel installs carry the documented caveat. Every
  release uses §16's frozen identifier and Developer ID team, and release QA
  verifies the designated requirement plus an upgrade that reads the existing
  keychain item without an authorization failure.
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
  at all (§18). Literal values have already passed the manifest's strict UTF-8
  and NUL checks (§4).

## 9. Threat model (delta over design.md §8)

The library's threat model covers secrets **at rest**. The CLI adds the
injection step, and the honest statement of the boundary is:

**What `run` protects:** values correctly represented as `kw://` references
remain absent from the repository, plaintext files, backups, sync, indexing,
and agent-visible working-tree content; Keyway also avoids casual disclosure
through its own argv, scrollback, and shell-history surface.

**Mixed-manifest boundary:** Keyway cannot determine whether a literal is
actually non-secret. If a credential is pasted as a literal, it is ordinary
committed plaintext and receives none of the repository protections above.
The format keeps that choice conspicuous in review, but review visibility is
not a technical secrecy boundary. Keyway does not claim otherwise and does
not add a heuristic scanner that could imply reliable classification.

**What `run` does not protect:** once injected, the values are ordinary
environment variables of the child — potentially visible to same-user process
inspection (`ps eww`/`sysctl` on macOS, `/proc/<pid>/environ` on Linux, subject
to OS policy), **inherited by every descendant** of the launched command (the
postinstall script, telemetry agent, compiler plugin), and present in the
child's crash dumps or anything the child itself logs. On macOS, note the
asymmetry: at rest the store key is ACL-gated per binary, while access to a
running child's environment does not trigger that keychain ACL.

**Authorization boundary:** a `kw://` name is a lookup reference, not a
capability. Because v1 deliberately has one CLI store and no per-namespace
approval database, any manifest can request any CLI-managed key whose name it
knows or guesses. Running `keyway run` therefore trusts the manifest and the
launched code as one unit; reference changes deserve the same review as code
changes. A namespace such as `acme-payments/` affects identity and
organization, not isolation. Per-repository ACLs, inferred identities, or
remembered approvals would add state and a second authorization model; they
are not silently approximated in v1.

The mitigation ladder is a documented product stance: **1)** direct library
integration (secrets never enter any environment — the preferred path for
apps that can), **2)** a future, application-cooperative password-file design
that can shorten value exposure when the receiving app reads and unlinks the
file promptly (Appendix C; not yet a proven Keyway tier), **3)** env injection
(the universal default this CLI ships). A path is still inherited and visible
to same-user inspection, so file materialization alone is not an isolation
boundary. The docs teach the ladder rather than implying env injection is more
than it is; `doctor` remains limited to storage/runtime facts. Same-user
malware, root, and the child's own conduct remain out of scope at every tier.

## 10. DX requirements (normative)

- **DX-1 — zero-config happy path.** In a repo with `./.secrets.env`,
  `keyway run -- <cmd>` works with no flags, no config, no init.
- **DX-2 — fast and measured.** AOT binary; benchmark Keyway-only `run`
  overhead (parse + resolve + pre-exec) on both release platforms with 1 and
  10 references. Initial release budgets: warm-store p50 ≤ 50 ms and p95 ≤
  100 ms on designated release hardware. Results are recorded; thresholds are
  not guessed from mocked keystores and are not enforced by a flaky generic-CI
  timing test. No daemon; nothing to warm.
- **DX-3 — every error names the next action.** Each typed library error and
  each CLI error maps to exact remediation (§17). Ordinary recovery includes
  the literal command; destructive abandonment of an unreadable store instead
  links to an explicit platform procedure and never emits a casual `rm -rf`.
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
   from a CI matrix (macOS arm64/x64, Linux x64/arm64), macOS ones Developer-ID
   signed with a secure timestamp and hardened runtime, and notarized as
   standalone Mach-O binaries (SR-11). Apple publishes an online ticket but
   cannot staple it to a raw executable; Keyway does not add an installer or
   app bundle solely to gain stapling. SHA-256 sums + build provenance
   attestation accompany every artifact.
   Honest note: Dart AOT builds are not bit-reproducible; provenance is the
   compensating control.
2. **Homebrew tap** (`brew install danreynolds/tap/keyway`), day one;
   the formula installs `libsecret` on Linux so the required `secret-tool`
   client is present; homebrew-core once traction justifies it. Scoop/winget
   when Windows lands.
3. **`dart install keyway_cli`** for the Dart-native audience, with the
   documented identity caveat (§5 `doctor`, design.md §8): a pub-channel
   install's keychain trust unit is the broadly shared VM or an ad-hoc-signed
   binary whose identity may churn, so existing-item access can fail typed;
   the signed release binary is the promoted channel for everyone else. The
   CLI's Dart SDK floor is 3.10, where `dart install`
   became available, so this channel has one documented installation spelling.
   The "any language" positioning fails if the answer to "how do I install
   it" starts with "install Dart".
4. **Identity surface:** the existing `danReynolds/keyway` repository, its
   repository-hosted GitHub Pages documentation, and the two real pub.dev
   packages are sufficient. No custom domain, separate GitHub organization, or
   placeholder package on an unused registry is part of v0.1. Add another
   identity only when a real distribution artifact needs one.

Release train: the CLI pins the exact core version; a core release triggers a
reviewed CLI pin-bump release. Independent CHANGELOGs; per-package tags. Pub.dev
requires each package's first version to be published manually. The one-time
v0.1.0 bootstrap is still signed-tag-bound and archive-validated; the core is
published first, and the CLI is published manually only after every native
release gate succeeds. Trusted OIDC publishing is mandatory thereafter.

## 12. Testing

The core's bar applies: claims that cross an OS boundary are exercised against
the real platform mechanism, while fakes are confined to pure command logic
(README "Testing").

- **Unit tier:** manifest parser — table-driven spec tests plus a **fuzz
  harness** (arbitrary bytes → typed error or valid parse, never a crash);
  the entry grammar including mandatory qualification, rejection of empty or
  single-segment keys, the 120-char cap, literal-edge cases (trimmed literal
  semantics, empty values, and `kw://`-prefixed hard errors), bounded reads,
  non-echoing diagnostics, and BOM/NUL/CRLF handling;
  env composition (named-vars-only overlay); exit-code mapping;
  remediation-text mapping for every typed core error (§17); UTF-8/NUL
  value validation (SR-16).
- **Command tier:** all five commands against
  `SecretStorage.withBackend(fake)` — the exported test hatch exists for
  exactly this (design.md §4). Cover the namespace contract explicitly:
  `set`/`rm` reject single-segment keys; two manifests using the same
  environment name but different namespaces resolve independently; two
  manifests using the same complete reference intentionally share one value;
  `list` returns complete qualified names from all namespaces. A literal-only
  manifest executes with a backend that fails the test if storage is touched.
- **Leak tier (SR-2/SR-6):** plant sentinel values in the store, stdin, and an
  invalid mixed manifest (including its literal portion); drive every error
  and prompt path; assert the sentinel never appears in **CLI-owned** prompts,
  status, diagnostics, or errors. Child stdout/stderr is inherited and is
  explicitly outside this assertion (a child can deliberately print its
  environment, as the `printenv ENV_NAME` escape hatch demonstrates). A PTY
  harness separately verifies echo-off and echo-restoration on every supported
  termination and suspend/resume path (§18).
- **Integration tier:** real keystores in CI exactly like the core (macOS
  Keychain; Linux via `dbus-run-session` gnome-keyring in Docker):
  `set → run → child sees value → rm` round-trips; exec-path PATH/exit/
  signal fidelity; cross-writer serialization (eight independent compiled
  `set` processes → every distinct name and value survives, courtesy of the
  library's flock; a deliberately wedged holder → `StoreBusy` as exit 75 with
  retry text); locked-keystore
  guidance path.
- **E2E:** `tool/test_cli.sh` joining the existing `tool/` suite; the
  native archive packaged, structurally verified, extracted, and its README
  quickstart executed verbatim against real Keychain/Secret Service storage on
  both platforms, including the fail-closed → set → run → remove → fail-closed
  lifecycle. A negative archive corpus proves duplicate, link, traversal,
  unexpected, missing, and corrupt members fail before extraction.
- **Supply chain:** the CLI's own dependency-closure snapshot test.

## 13. Phases

**Phase 1 — contract and pure logic.** Workspace conversion
(`packages/keyway_cli`); the five-command hand parser; the manifest parser
(mixed literals + qualified references) + fuzz harness; reference resolution
and environment
composition; `set`, idempotent `rm`, one-key-per-line `list`; exhaustive
fake-backend command tests and output-leak tests.
*Acceptance:* the entire CLI model can be understood from one help screen.

**Phase 2 — native process execution.** `execve` + final-environment PATH
resolution, tested across direct paths, PATH search, missing commands,
permissions, scripts, exit codes, signals, TTY inheritance, and UTF-8/NUL
rejection; hidden prompting with PTY echo-restoration tests; minimal
`doctor`; platform-specific unreadable-store recovery procedures and their
remediation-text tests; real macOS Keychain and Linux Secret Service round
trips; measured 1-reference and 10-reference overhead on designated macOS and
Linux release hardware against the DX-2 budgets.
*Acceptance:* `run` fails → lists missing keys → user runs `set` for each →
`run` succeeds. No separate onboarding workflow exists.

**Phase 3 — release.** Use the frozen macOS signing identifier and entitlement
set; compile, Developer-ID sign with a secure timestamp and hardened runtime,
notarize standalone macOS binaries, require an accepted online ticket and
empty issue log, and verify with Gatekeeper; verify the designated requirement,
exact entitlement set, and successful signed-binary upgrade access to an
existing keychain item;
build Linux artifacts; publish checksums + provenance; gate pub.dev on fresh
hosted runners installing the published Homebrew and Linux archive channels
without Dart; validate Homebrew, the GitHub archive, and `dart install` from
physical clean machines; execute the documented quickstart verbatim
on macOS and Linux; complete Appendix B's registration checklist.
*Acceptance:* a person with no Dart toolchain installs and onboards a repo
in under five minutes on macOS and Linux.

## 14. Decision log

- **References-in-repo over ciphertext-in-repo (dotenvx's model).** Managed
  secret values never enter git history; rotation is mundane; the cost — no
  value sync between teammates — is deliberate and served by the failed-run
  onboarding loop. Positioning: solo devs, OSS bring-your-own-key repos, and
  agent-safe working trees when literals are correctly classified.
- **Reference-only manifests — ratified by the owner, 2026-07-12.** The one
  scope decision treated as a product call, per two independent reviews
  (both ~60/40 for reference-only). Decisive argument: reversibility —
  literals can be added compatibly later; removing them would break every
  manifest. Consequences owned explicitly: keyway is not a dotenv
  replacement; one-file parity is a non-goal; migration guidance is "your
  `.env` keeps its non-secret lines and loses its secret ones."
  *(Superseded 2026-07-13 — see the mixed-manifests entry below; the
  compatible-to-add-later property is exactly what was exercised.)*
- **Mixed manifests — ratified by the owner, 2026-07-13, superseding
  reference-only.** The per-environment workflow decided it: under
  reference-only, environment files come in pairs (`.env.staging` +
  `.secrets.staging.env`), dotenv tooling survives alongside keyway,
  non-self-loading apps (Go/Rust/shell) get no literal story at all, and
  the paste-a-secret-at-2am risk is *displaced* into a companion plaintext
  file keyway never parses — not removed. One mixed file per environment
  can eliminate the companion `.env` and restores the full replacement
  workflow. Cost owned: the manifest-wide no-secret guarantee narrows from a
  structural property to a reviewable convention (a `kw://` line still never
  carries a value; a literal is visibly plaintext in review). Containment:
  literal values are ASCII-trimmed and otherwise uninterpreted — the dotenv
  dialect (quotes, escapes, interpolation) stays rejected (§1, §4).
- **Import is de-scoped from the initial build (2026-07-13).** It is not part
  of Phases 1–3. If usage evidence later justifies reconsidering it, the
  recorded design stays narrow: `keyway import` reads `.env`-family files —
  the incumbent being replaced — and nothing else. There is no provider
  concept to import *from*; `--stdin` is the universal adapter for every
  other source (`op read … | keyway set acme-payments/key --stdin`). With
  mixed manifests, import's output would be a *complete* replacement manifest
  (secret lines → refs, literal lines normalized to Keyway's grammar).
- **Profiles are files (2026-07-13).** The already-ratified `-f` flag is
  the entire mechanism: `.secrets.<env>.env` by convention, selected per
  invocation. No profile concept, no `--profile`, no user config — the
  dotenvx model, composing naturally with multi-segment namespaces
  (`kw://acme-payments/staging/database-url`).
- **Descriptions stay human-only (owner, 2026-07-13).** A plain comment
  above an entry is the documented idiom for what a secret is and where to
  get it. Machine-readable descriptions echoed by `run` (SecretSpec's
  `description` field) were considered and declined — convention over
  parser semantics.
- **Five-command surface (two-round RFC review, 2026-07-12).** Everything
  beyond `run`/`set`/`rm`/`list`/`doctor` is cut or deferred with recorded
  reasoning (§20). Review's framing, adopted as a standing rule: omission
  is reversible; premature surface area is not.
- **`get` rejected** — a standing plaintext-extraction command invites
  `export X=$(keyway get …)`, the exact pattern the shell-hook non-goal
  exists to prevent. The run-scoped idiom `keyway run -- printenv ENV_NAME` is
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
- **Mandatory explicit namespaces — ratified by the owner, 2026-07-13.**
  Every reference and every `set`/`rm` key requires at least two segments.
  This makes the obvious accidental collision — two repositories both
  choosing `openai-api-key` — unrepresentable through the CLI. The conservative
  direction is reversible: qualification can be relaxed compatibly later,
  while imposing it after bare keys ship would break manifests.
- **Namespace is identity, not a second authorization model.** The first
  segment is explicit and meaningful to people, but it adds no flags,
  filtering, inference, physical isolation, or access control. The full name
  maps directly to one opaque library key in one CLI store. Identical full
  references intentionally share; distinct namespaces resolve independently.
- **Labels cut** — on the v1 platforms the resolver always lands on the
  file backend, where labels surface in no UI at all.
- **One leading BOM tolerated** — friction removal without a user-facing
  concept.
- **`Stored.` after interactive `set`** — the human typed blind; one ack
  line is UX feedback, not API breadth. Silent with `--stdin`.
- **Appendix A corrected for SecretSpec (2026-07-13).** The initial survey
  missed the closest identified analogue: a committed declaration, local
  keyring provider, and run wrapper. Keyway's differentiation is stated as
  deliberate austerity rather than an empty market intersection.
- **Explicit namespaces; no repo-identity inference** (§3).
- **One appId, one physical store** (§3).
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

## 15. Resolved platform contracts

The product surface is frozen. Implementation exposed two platform-level
details, both ratified by the owner on 2026-07-13 under the same austerity rule:
prefer the smaller fail-safe contract when additional native or packaging code
does not materially improve the supported security model.

1. **Hidden-prompt `SIGQUIT` / `SIGTSTP`.** Dart AOT exposes `SIGINT`,
   `SIGTERM`, and `SIGHUP` streams on both v1 platforms, but not a portable
   macOS stream for `SIGQUIT` or job-control suspend/resume. Keyway temporarily
   ignores `SIGQUIT` and `SIGTSTP` only while echo is hidden, restores their
   prior dispositions afterward, and proves by PTY that neither can terminate
   the process with a silent terminal. No native signal bridge is added solely
   to preserve those two controls during the short prompt window.
2. **Standalone macOS notarization.** Apple accepts standalone Mach-O binaries
   for notarization but does not support stapling a ticket to the raw binary.
   The release path signs the standalone binary, submits it in a ZIP, requires
   an accepted ticket with no issues, and verifies it with `spctl`; it does not
   add an app bundle, disk image, or installer solely to gain stapling.

The key grammar, workspace layout, PATH behavior, doctor health exit, CLI SDK
floor, and macOS signing identifier remain frozen below or in their normative
sections. Reopening product scope still requires usage evidence (§20).

## 16. Frozen constants

Settled through 2026-07-13; changing any of these after the first release is a
migration, not a rename.

| Constant | Value | Notes |
|---|---|---|
| Product / executable | `keyway` | the installed command |
| Library package | `keyway` | renamed from `secret_store`, pre-publish |
| CLI package | `keyway_cli` | pub.dev name confirmed free 2026-07-12 |
| Reference scheme | `kw://` | replaces draft `se://`; nothing shipped under the old scheme |
| CLI store `appId` | `keyway-cli` | derives container path + keystore service (design.md §3 rules) |
| CLI key grammar | `[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*`, max 120 characters | same grammar for refs, `set`, and `rm`; at least two segments; every segment starts alphanumeric; no option-shaped or machine-global keys |
| Container path | `~/Library/Application Support/keyway-cli/secrets.enc` (macOS) · `${XDG_DATA_HOME:-~/.local/share}/keyway-cli/secrets.enc` (Linux) | derived by the library from `appId`; the library also maintains `<container>.lock` beside it (§7 — not a CLI concern) |
| Default manifest | `./.secrets.env` | content-descriptive, not tool-branded |
| CLI secret-input cap | 16 MiB | matches the core's maximum sealed-container envelope; the reader retains at most cap + 1 byte to reject oversized input without unbounded buffering |
| macOS codesign identifier | `dev.keyway.cli` | every signed release uses this identifier, the same Developer ID team, a secure timestamp + hardened runtime, and no Keychain Sharing entitlement |

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
user. When a command needs storage, construct
`SecretStorage(appId: 'keyway-cli')` once per process; a `run` whose manifest
contains no references never constructs it.
Verbs: `readAll()` (run/list — gated on
`backend.capabilities.enumeration`, true for both v1 platforms),
`writeString(key, value)` (set), `delete` (rm), `backend.describe()`
(doctor).

Error → CLI behavior map (exhaustive over the exported taxonomy; the leak
tier drives every row):

| Typed error | Exit | CLI remediation text (gist) |
|---|---|---|
| `KeystoreLocked` | 69 | login keychain / Secret Service is locked — how to unlock; "over SSH this is expected: keyway is a dev-machine tool" |
| `KeystoreUnreachable` | 69 | no keystore here (headless/unsupported) — dev-machine tool; use the CI platform's secrets in CI |
| `StoreKeyMissing` | 69 | container exists but its key was not returned — first unlock/reconnect the keystore and retry, because some Linux providers present a locked collection as missing; only after deliberately concluding the key is lost, restore the matching key/container pair or follow the linked platform procedure to preserve/move the unreadable container before re-provisioning (plain `keyway set` cannot heal this state) |
| `ContainerMissing` | 69 | key exists, container file gone/moved — restore the file, or deliberately re-provision with `keyway set` (the core safely heals this key-without-container state on a write) |
| `WrongStoreKey` | 69 | container does not match this machine's key — restore the matching pair; if abandoning it, follow the platform procedure to preserve/move the old container before re-provisioning |
| `AuthenticationFailed` / `ContainerCorrupt` | 69 | tamper, bit-rot, or malformed ciphertext — restore from backup; if abandoning the unreadable store, follow the platform procedure before setting replacement values |
| `MigrationRequired` | 69 | store-scheme change detected (design.md §12) — should not occur for the unentitled release CLI; explain the old/new schemes and link the deliberate platform migration procedure rather than auto-migrating |
| `StoreTooLarge` | 69 | value/store exceeds the size envelope — this is a store for credentials, not blobs |
| `SecureFileError` | 69 | for rejected group/other-accessible modes, print the exact restrictive `chmod` fix (OpenSSH stance); for syscall or `flock` failures, name the operation and direct the user to local app-data storage or the platform procedure — never weaken permissions or locking |
| `StoreBusy` | 75 | another keyway/library process or isolate holds the store write lock — a **live** peer, not a stale file (the OS releases a dead holder's lock); retry, and if it persists, find the wedged holder |
| `KeyInvalidated` | 69 | Android-only in practice; generic key-loss text if ever surfaced |
| `UnsupportedCapability` | 70 | internal bug (both v1 backends enumerate) — report upstream |
| `KeystoreOperationFailed` (catch-all) | 69 | the typed message + `keyway doctor` |

Manifest/usage failures are the CLI's own: parse errors and unresolved refs
→ 78 with the per-key fix list; manifest missing/unreadable/over-cap → 78;
bad invocation or invalid CLI key → 2. `doctor` returns 0 only for an
available, unlocked backend and 69 for a reported unhealthy state.

## 18. Implementation notes (gotchas, so they're hit once)

- **`execve` binding** is fixed-arity (3 pointer args) — none of the
  variadic-FFI trap that bit the core's `open()` on Apple arm64 (design.md
  §11). Build `argv`/`envp` as NULL-terminated `Pointer<Pointer<Utf8>>`
  arrays (`package:ffi` `malloc` + `toNativeUtf8`); on success it never
  returns, so leak-on-success is meaningless; on failure map `errno`:
  `ENOENT` → 127, `EACCES`/`ENOEXEC` → 126, message names the command.
- **PATH resolution is ours** (deliberately execvp-like, not identical). If
  `COMMAND` contains `/`, call `execve` on it directly. Otherwise read `PATH`
  from the **final composed child environment** and try its entries in order by
  calling `execve` directly — no `exists`/`access` preflight and therefore no
  check/use race. An absent or empty PATH yields 127 with guidance to use an
  absolute path. Empty PATH elements are ignored; no cwd entry is synthesized.
  Explicit relative elements (including `.` or `bin`) are honored exactly as
  written. Continue past `ENOENT`/`ENOTDIR`, remember `EACCES`, and if every
  candidate fails let any observed `EACCES` win as 126 over pure not-found as
  127. `ENOEXEC` is 126 and never triggers a `/bin/sh` retry; other syscall
  failures return 126 with the non-secret command and errno (SR-13).
- **Prompt echo restoration:** after the TTY check, remember the prior echo
  mode, set `stdin.echoMode = false`, and restore the exact prior mode in
  `finally` and before acting on Dart's portable terminal-facing termination
  signals on both v1 platforms (`SIGINT`, `SIGTERM`, `SIGHUP`). Cancel all
  subscriptions on normal completion. After restoration, exit with the
  conventional signal-derived status (130/143/129 respectively). While echo
  is hidden only, temporarily ignore `SIGQUIT` and `SIGTSTP`; restore their
  exact prior dispositions afterward. This deliberately trades two momentary
  job-control shortcuts for a smaller fail-safe implementation that cannot
  strand a silent terminal. `SIGKILL` and process/runtime crashes cannot be
  handled and are the explicit OS-level limits. PTY tests assert normal
  completion, every supported termination signal, temporary quit/suspend
  immunity, and disposition restoration.
- **Secret-input byte handling:** retain at most the core's 16 MiB sealed-store
  envelope + 1 byte; the extra byte triggers a size error rather than unbounded
  buffering. Within the cap, `--stdin` reads to EOF and the interactive path
  reads one line; strict UTF-8 decode (reject on failure); reject NUL; strip
  exactly one trailing LF or CRLF.
  Values are stored via `writeString` — the env boundary is string-shaped
  anyway (env vars cannot carry NUL); binary secrets belong to the library
  tier, not the env tier. Empty input is a valid empty secret; a lone trailing
  CR is data and is not stripped.
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
$ keyway set acme-payments/openai-api-key
Value for acme-payments/openai-api-key (input hidden):
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
error: 2 of 3 references in ./.secrets.env are not set on this machine:

  keyway set acme-payments/database-password
  keyway set acme-shared/stripe-test-key

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
scheme:   encrypted file
level:    loginBound
keystore: reachable, unlocked
detail:   container=absent key=absent via keystore
runtime:  compiled executable (signature not inspected)
keyway:   0.1.0
```

The `detail` presence words reflect the current store state and become
`present` after first use; `level` remains the measured S3/login-bound result.

## 20. Deferred and rejected surface (record, not roadmap)

Per the review framing adopted in §14: these are recorded as rejected or
unproven ideas. **Reconsider only with usage evidence.** None are v1.x
promises.

| Idea | Status | Reasoning |
|---|---|---|
| `get` | **Rejected** | A standing plaintext-extraction command creates the `$(keyway get …)` scripting path outside the run-scoped model. `keyway run -- printenv ENV_NAME` is the documented escape hatch. |
| `check` | **Rejected** | `keyway run -- true` is the check; a failed `run` is the report. |
| `fill` | Unproven | The failed-run loop covers onboarding at typical secret counts. |
| `import` | **De-scoped from initial build — design recorded** | Not part of Phases 1–3. If post-release usage evidence justifies reconsideration: dotenv-only source, interactive per-line secret/literal triage, output = one complete mixed manifest to stdout; `--stdin` covers every non-file source (§14). |
| `init` | Unproven | The grammar is three lines in the README. |
| `completion` | Unproven | Five commands; marginal value against permanent maintenance. |
| Labels | Rejected for v1 | Invisible on the v1 platforms (file backend; no keystore UI shows them). |
| Multiple manifests / composition | Unproven | Precedence rules are surface; one contract per invocation — `-f` selects, never merges. |
| Machine-readable descriptions | Rejected | Comments above an entry are the idiom (§4, §14); parser-echoed metadata declined by the owner. |
| Namespace as separate command surface (`--scope`, filtering, discovery, inference) | Rejected | Namespace is already explicit in every qualified key. A second mechanism would add state and ambiguity without changing identity. |
| Per-namespace physical sharding | Unproven | It would multiply keystore items, recovery states, and locking paths while providing no same-user authorization boundary. Reconsider only with store-size or recovery evidence. |
| JSON/porcelain output | Unproven | Exit codes + one-key-per-line suffice until someone's script says otherwise. |
| `doctor` signing inspection / container paths / counts | Unproven | `BackendInfo` + VM-vs-compiled covers the security-relevant part. |
| Output masking; `kw+file://` | Recorded designs | Appendix C — real threat-model responses preserved with their trade-offs. |

## Appendix A — CLI landscape snapshot (2026-07)

Library-side comparison lives in
[ecosystem-comparison.md](ecosystem-comparison.md); this table is the
CLI-product landscape that motivated §0. Surveyed 2026-07-12; corrected
2026-07-13 to include SecretSpec.

| Tool | Values live in | Committable manifest | Local-only (no account/server) | Windows | Notes |
|---|---|---|---|---|---|
| 1Password `op run` | 1Password vault | ✅ `op://` refs — the UX this CLI adopts | ❌ paid account + app | ✅ | The polish bar. Masks child output. |
| envchain / envchain-xtra | OS keychain | ❌ namespaces outside the repo | ✅ | ❌ | Upstream dormant since 2024; fork markets the AI-agent angle. |
| envsec | OS keychain | ❌ profiles in `~/.envsec` | ✅ | ✅ | TypeScript, beta, 13★ (2026-04). |
| envguard | OS keychain | ❌ manifest gitignored | ✅ | ✅ | TypeScript, alpha, 2★. |
| dotenvx | ciphertext in repo; keys movable to OS keychain | ✅ (encrypted values) | ✅ | ✅ | The strongest free competitor; different model — ciphertext lives in git history forever. |
| [SecretSpec](https://secretspec.dev/) | pluggable providers, including OS keyrings and hosted managers | ✅ (`secretspec.toml`) | ✅ with the keyring provider | ✅ | **Closest identified analogue.** Its [default keyring identity](https://secretspec.dev/providers/keyring/) includes project, profile, and key; it supports 11 providers and profiles. Broader and more flexible than Keyway by design. |
| teller / chamber / doppler / infisical / `bws` | hosted or cloud vaults | varies | ❌ | ✅ | Different category (server in the loop). |
| aws-vault | OS keychain | n/a (AWS creds only) | ✅ | ✅ | Proof the keychain→env→exec pattern is loved; single-provider. |

The closest identified analogue is SecretSpec: it also combines a committed
secret contract, project-qualified identity, a local keyring provider, and a
run wrapper. Keyway's differentiation is deliberate austerity: an
`.env`-shaped mixed manifest, one storage model per platform, five
commands, and an audited minimal-dependency core. SecretSpec's provider and
profile breadth is a strength for users who want that flexibility; Keyway
does not reproduce it.

## Appendix B — naming decision record (2026-07-12)

**Decision: `keyway`.** The keyway is the shaped channel in a lock cylinder
that admits only the matching key — precisely this product: the one
sanctioned path by which keys reach a process. Chosen over ~30 vetted
candidates; final four:

**2026-07-14 collision update.** A same-category product at
[`keyway.sh`](https://keyway.sh/) now actively ships a `keyway` secrets CLI,
including `keyway run`, plus its own Homebrew tap. This invalidates the earlier
"out-of-category collision only" conclusion. The Dart package and CLI names
remain unchanged in this implementation plan, but the owner must complete a
fresh trademark/confusion review before the first signed release. Public docs
use "Keyway for Dart" and state non-affiliation in the interim.

| Finalist | Availability (pub / npm / brew / crates / PyPI) | Deciding factor |
|---|---|---|
| **keyway** ✅ | ✅ / squatted / ✅ / ✅ / squatted | Best metaphor and sound in the original search; this row is superseded by the same-category collision update above. |
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

**Squat details** (historical research, not scheduled work):
npm `keyway` — a one-release 2022 toy ("the opposite of `Object.keys`");
PyPI `keyway` — a one-day-in-2023 "persistent environment variables"
project (ironically category-adjacent). Do not file reclamations or occupy
fallback scopes unless a real package for that ecosystem is approved.

**Registration checklist (owner actions):** ~~rename the GitHub repo~~
(done 2026-07-12 — `danReynolds/keyway`; pubspec updated); publish only the
actual `keyway` and `keyway_cli` packages on pub.dev; resolve the updated
same-category naming review above before signing either tag. The GitHub
repository and its repository-hosted Pages site are the canonical project
surfaces. There is deliberately no custom domain, separate organization, or
placeholder package on another registry for v0.1.

## Appendix C — recorded designs, not scheduled scope

*Preserved because each answers a named limitation in §9's threat model.
Reconsider only with usage evidence. Recording is not scheduling.*

**`kw+file://` materialization (the `*_FILE` convention).** For a manifest
entry like
`DATABASE_PASSWORD_FILE=kw+file://acme-payments/database-password`,
materialize the value into a `0600` file inside a per-run `0700` runtime
directory (`XDG_RUNTIME_DIR` on Linux; the Darwin per-user temp dir on
macOS), put only the *path* in the environment, unlink after the child
exits, and sweep stale run-dirs on the next invocation (crash cleanup).
This keeps the secret bytes out of ordinary environment dumps and can shorten
their exposure only when the receiving application reads and unlinks the file
promptly. It does **not** defeat descendant inheritance or same-user
inspection by itself: descendants inherit the path, and a same-UID process
that learns it can read a `0600` file while it exists. The Docker-official-
images ecosystem (`POSTGRES_PASSWORD_FILE`, …) already honors the convention,
but Keyway would need an explicit lifecycle contract to claim more than
env-byte hygiene. Costs: a secret touches the filesystem (`XDG_RUNTIME_DIR` is
often tmpfs-backed, but that is not guaranteed on either platform), Keyway
must remain a wrapper to clean up
after child exit (sacrificing §6's exec-and-vanish signal/process simplicity),
crash-window cleanup, a second reference scheme, and reopening SR-2. This is
preserved research, not yet a sound or scheduled stronger tier.

**Output masking (`op run` precedent).** Interpose pipes on the child's
stdout/stderr and redact any occurrence of a resolved secret value before
forwarding. Directly mitigates the child logging its own secrets. Costs:
the child no longer sees a TTY (`isatty=false` changes colors, prompts,
buffering), keyway becomes a resident wrapper again (undoing §6's
exec-and-vanish), and redaction is bypassable by any encoding of the value.
If ever built: opt-in `--mask`, never default, with the TTY trade-off
documented.
