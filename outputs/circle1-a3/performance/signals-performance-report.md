# Circle 1 A3 signal performance

## Method and correctness

The before source is the complete `outputs/circle1-a3/baseline/Ocean` snapshot; after is current `scripts/Ocean`. The benchmark imports the existing read-only Lupa helper from `tests/run_circle1_a2.py` and uses Lua 5.4. Each run uses normal `Runtime.New` initialization and regional population, departure `(0, 0)`, default ship level, 2,400 updates at `dt=0.05` with continuous north input (120 simulated seconds), and 1,200 getter/visitor pairs. It changes no fish population, position, signal setting, or tuning value. Signals are snapshotted every 0.25 seconds. Native engine FPS was not measured.

For each seed, the final run alternates three paired repetitions in this order: `before/after`, `after/before`, `before/after`. The complete per-run timing and memory rows, order indexes, hashes, and summaries are in [`signals-benchmark.json`](signals-benchmark.json). The previous block-ordered run is preserved as [`single-pass-blocked-order.json`](single-pass-blocked-order.json); the earlier pre-single-pass run is preserved as [`pre-single-membership-pass.json`](pre-single-membership-pass.json). Those earlier rounds are context only; their CPU times are not pooled with or attributed to the final interleaved run.

World and sampled signal SHA-256 digests match before/after for both seeds and each source is repeatable. The normal route produces 156 sardines and 28 tuna for seed 271828 (42 birds, 4 splashes), and 152 sardines and 28 tuna for seed 314159 (32 birds, 7 splashes). No fish or signal fixture is used; observed splashes come from the normal ecosystem.

## Final interleaved sample

Values below show every paired repeat from the required execution order. Times are Lua `os.clock()` CPU seconds converted to milliseconds. A negative delta means after ran faster in that pair.

| Seed | Pair order | Update before → after | Update delta | Getter before → after | Getter delta | Visitor after |
|---|---|---:|---:|---:|---:|---:|
| 271828 | 1: before/after | 3,184 → 5,239 ms | +64.5% | 210 → 301 ms | +43.3% | 200 ms |
| 271828 | 2: after/before | 5,494 → 4,755 ms | -13.4% | 189 → 142 ms | -24.9% | 173 ms |
| 271828 | 3: before/after | 4,321 → 4,344 ms | +0.5% | 201 → 140 ms | -30.3% | 135 ms |
| 314159 | 1: before/after | 6,053 → 6,235 ms | +3.0% | 253 → 303 ms | +19.8% | 250 ms |
| 314159 | 2: after/before | 5,845 → 6,332 ms | +8.3% | 260 → 279 ms | +7.3% | 235 ms |
| 314159 | 3: before/after | 6,079 → 6,004 ms | -1.2% | 283 → 251 ms | -11.3% | 207 ms |

Timing spread remains large even with paired order: seed 271828 update runs range 3.184–5.494 s before and 4.344–5.239 s after; getter runs range 189–210 ms before and 140–301 ms after. Seed 314159 update runs range 5.845–6.079 s before and 6.004–6.332 s after; getter runs range 253–283 ms before and 251–303 ms after. The three paired deltas are mixed. The single-pass membership check has removed one redundant cache traversal, but these timings do not establish a reliable CPU gain or regression for it. Getter/update CPU remains unresolved; do not claim a performance fix from these samples.

## Allocation and retained memory

For each getter/visitor batch the harness forces a full collection, stops automatic GC, performs 1,200 read pairs, samples heap growth, forces a full collection again, then records retained heap. This separates temporary allocation traffic from objects still live after collection.

| Seed | Getter pre-GC allocation, before → after | Getter retained after full GC, before → after | Visitor after: pre-GC / post-GC | Full 120s route retained delta, before → after |
|---|---:|---:|---:|---:|
| 271828 | 20,907.92 → 20,382.95 KiB (-525 KiB) | 18.42 → 17.36 KiB (-1.06 KiB) | 0.25 / 0.125 KiB | +4,750.00 → +4,750.86 KiB (+0.85 KiB) |
| 314159 | 17,495.42 → 16,970.45 KiB (-525 KiB) | 15.58 → 14.52 KiB (-1.06 KiB) | 0.25 / 0.125 KiB | +4,145.64 → +4,146.49 KiB (+0.85 KiB) |

Getter batches still allocate detached cue records and copied positions. Reusing the query workspace saves about 525 KiB of transient traffic per 1,200 getter pairs. Scalar visitors create no detached result rows; visitor CPU is mixed across the two samples but its GC-stopped allocation remains 0.25 KiB total. The roughly 0.85 KiB full-run retained difference is stable across seeds and consistent with workspace/cache state, not a growing leak. Full-route totals include the same normal regional fish population before/after. The old A2 `memoryDeltaKiB` was an uncollected net heap delta from a different 12-second, zero-splash route; it is not retained live memory. The separate old-World retention issue is addressed by `World:Retire()` and validated by lifecycle tests, not inferred from this benchmark.

## Implementation and tradeoffs

- Stable fish membership now checks the freshly collected scratch list once against the canonical ID map. Since that map is rebuilt only from scratch on membership changes and world entity IDs are unique, equal lengths plus matching ID references proves the current set is unchanged. A change still sorts and rebuilds both cache and map. This removes the redundant second membership traversal without caching same-frame eligibility.
- Signal readers reuse a caller-owned water-query workspace refreshed from the current world. Bird and splash qualification is still checked against current source and water state; splash position is also checked for finiteness and legal water. Getters remain detached snapshots.
- `VisitBirds` and `VisitSplashes` supply scalar values and a count, so rendering can avoid result-row and point-copy allocations while preserving current-state validation.
- The visitor did not exist in the A3 baseline, so its measurement is after-only. Baseline getter runs cannot be compared to a pre-visitor implementation on the same API. Stable source validation still traverses live fish once; water-query refresh still scans current world entities.

The exact harness is [`run_signals_benchmark.py`](run_signals_benchmark.py). All raw final per-run readings and the two preserved earlier JSON files are available beside this report.
