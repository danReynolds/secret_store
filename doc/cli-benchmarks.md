# Keybay CLI run overhead

The Phase 2 budget is Keybay-only warm-store overhead: p50 ≤ 50 ms and p95 ≤
100 ms for manifests with one and ten references. Measurements invoke the same
`/usr/bin/true` child directly and through an AOT-compiled CLI harness, then
subtract the direct child median. They use a real login Keychain or Secret
Service store; mocked timings are not accepted.

Reproduce on a disposable release test account:

```sh
KEYBAY_BENCHMARK=1 ./tool/benchmark_cli.sh
```

## Recorded results

### macOS arm64 — 2026-07-13

- Hardware: MacBook Pro 16-inch (2021), Apple M1 Pro, 10 cores, 16 GB
- OS: macOS 26.2 (25C56)
- Build: Dart AOT arm64, 100 warm-store iterations, real login Keychain

| References | Direct-child p50 | Compiled run p50 | Compiled run p95 | Keybay overhead p50 | Keybay overhead p95 |
|---:|---:|---:|---:|---:|---:|
| 1 | 2.329 ms | 40.237 ms | 62.851 ms | **37.908 ms** | **60.522 ms** |
| 10 | 2.263 ms | 39.094 ms | 51.089 ms | **36.831 ms** | **48.825 ms** |

Both reference counts pass the 50 ms p50 / 100 ms p95 overhead budget.

### Linux x64 CI diagnostic — 2026-07-13

- Runner: GitHub-hosted `ubuntu-latest`, x86_64, CI run
  [29271730211](https://github.com/danReynolds/keybay/actions/runs/29271730211)
- Build: Dart AOT x64, 100 warm-store iterations, real Secret Service under
  `dbus-run-session`

| References | Direct-child p50 | Compiled run p50 | Compiled run p95 | Keybay overhead p50 | Keybay overhead p95 |
|---:|---:|---:|---:|---:|---:|
| 1 | 0.545 ms | 16.069 ms | 16.601 ms | **15.525 ms** | **16.056 ms** |
| 10 | 0.545 ms | 16.245 ms | 16.727 ms | **15.700 ms** | **16.182 ms** |

Both reference counts are well below the budget in CI. This is a real-store
cross-platform diagnostic, not a substitute for the implementation plan's
designated Linux release-hardware receipt; that release gate remains pending.
