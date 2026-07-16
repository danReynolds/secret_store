# Security policy

`keybay` stores credential material. Please treat vulnerabilities
accordingly.

## Reporting

Report suspected vulnerabilities privately to **me@danreynolds.ca** — do not open
a public issue for a security bug. Include a description, affected version, and a
reproduction if you have one. You'll get an acknowledgement within a few days.

## Threat model

The threat model — what Keybay protects against and, just as importantly, what
it does **not** — is summarized for the [SDK](doc/sdk.md#threat-model) and
[CLI](packages/keybay_cli/README.md#security-boundary), then derived in full in
[doc/design.md](doc/design.md). Read it before relying on Keybay: it is
deliberate about its limits (process-memory disclosure, rollback, same-user
malware while the keystore is unlocked, and timing side-channels are out of
scope, with rationale).

## Cryptography

- Container confidentiality/integrity: XChaCha20-Poly1305 (AEAD), via
  `package:cryptography`, exercised against RFC 8439 and draft-arciszewski
  vectors in this package's own test suite so incompatible behavior is caught
  before the exact dependency pin moves. These checks do not prove a dependency
  uncompromised.
- Key derivation: HKDF-SHA256, RFC 5869, vector-tested here.
- Randomness: `Random.secure()` (OS CSPRNG) only.

## Dependencies

Exactly one third-party runtime dependency (`cryptography`, exact-pinned), whose
transitive closure is entirely dart-lang official. A dependency-closure snapshot
test fails CI if the tree changes; CI also runs advisory scanning.
