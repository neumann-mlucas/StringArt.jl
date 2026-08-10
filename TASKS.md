# StringArt.jl — Task Ledger

Sequenced work items derived from `SPEC.md`. Each task lists the phase, the
minimum diff, the acceptance check, and dependencies. Merge order is the
task order.

Legend: **P** = performance, **D** = drawing, **C** = cleanup, **T** = test.

---

## Phase 1 — Foundations

### T1. Test harness + baseline
- Add `test/` per layout in `SPEC.md` §Test strategy → Harness structure.
- Copy the 11 fixtures listed in `SPEC.md` §Fixture set into
  `test/fixtures/`. Reuse `examples/einstein.png` and frame 0 of
  `examples/david.gif` where possible.
- `test_baseline.jl` records the six metrics from `SPEC.md` §Metrics
  (SSD, SSIM, coverage, overdraw p99, wall-clock, allocations, hash)
  into `test/baseline.json` keyed by `(fixture, phase="baseline")`.
- `test_correctness.jl` enforces the guardrails from `SPEC.md`
  §Guardrails against the previous phase's numbers.
- Fix `Random.seed!(42)` at the top of every entry point.
- Wire the CI matrix: fast-pass job (3 fixtures, N=256) on PR,
  nightly job for the full set.
- Acceptance: `julia --project test/runtests.jl` runs green, writes
  baseline metrics, produces `test/artifacts/` visual diffs.
- Depends on: none.

### C1. Port `Chord` to `Tuple{Int,Int}` key
- New `PinSet{pts,nbrs}` struct in `stringart.jl`.
- `chord_key(i,j)` returns sorted `Tuple{Int,Int}`.
- Update `to_chord`, `gen_chords`, cache key type. LRU key
  `Pair{Point,Point}` → `Tuple{Int,Int}`.
- Acceptance: existing examples reproduce bit-for-bit (rasterization
  unchanged in this phase).
- Depends on: T1.

---

## Phase 2 — Sparse chord core

### P1. Sparse chord representation
- New `SparseChord = @NamedTuple{idx::Vector{Int32}, w::Vector{Float32}}`.
- `score(c, residual)` and `apply!(c, residual)` operate on flat
  `Vector{Float32}`.
- Wire into a new `run_algorithm_fast`. Keep old `run_algorithm` in place
  behind a `--legacy` flag for A/B during this phase only.
- Acceptance: sparse and legacy paths produce visually equivalent output
  on grayscale einstein; sparse ≥10× faster on N=512 / steps=2000.
- Depends on: C1.

### P2. Xiaolin Wu line
- Replace `bresenham_line!` writing into an image with `wu_line!` writing
  into `(idx, w)` buffers.
- Deprecate `--blur` in `main.jl`: warn, ignore.
- Acceptance: no `imfilter` calls in hot path (`grep imfilter stringart.jl`
  reports none inside `run_algorithm_fast`).
- Depends on: P1.

### P4. Persistent residual + threaded findmin
- `residual::Vector{Float32}` initialized once.
- Per-thread `part_s`, `part_k` for reduction.
- Acceptance: no per-step allocation over 4 KB (measure via
  `@allocated` on a 100-step sample).
- Depends on: P1, P2.

### T2. Remove `--legacy` path
- Once P1+P2+P4 confirmed on all test images, delete old
  `run_algorithm`, `select_best_chord`, `gen_img`, `bresenham_line!`,
  `add_imgs!`.
- Acceptance: LOC delta negative; all tests pass.
- Depends on: P1, P2, P4.

---

## Phase 3 — Correctness fixes

### P6. exclude-repeated: `Set` + bug fix
- Replace `filter!` at old line 243 with `drawn::Set{Tuple{Int,Int}}`
  membership check.
- Acceptance: run with `--exclude-repeated-pins --steps 5000`; count
  unique chords in output equals total chord count (no duplicates).
- Depends on: T2.

### D4. Palette normalization
- Per-channel `maximum` divisor in `join_channels(::Val{PaletteMode})`.
- Acceptance: palette-mode on `test_images/parrot.jpg` — color histogram
  more balanced than baseline. Regenerate `examples/`.
- Depends on: T2.

---

## Phase 4 — Drawing quality

### D3. Negative-residual overdraw penalty
- Drop `max(0, ...)` in `apply!`.
- Acceptance: dense-region overdraw metric (mean pixel value across
  darkest 10% of target region after 2000 chords) improves ≥5% vs
  P4 baseline on portrait fixtures.
- Depends on: P4.

### D1. Dark-emphasis weighted error
- `score` uses `residual^2` weighting.
- Acceptance: SSD vs target improves ≥3% on portrait fixtures at fixed
  step budget.
- Depends on: P4.

### D5. Adaptive restart
- Compute per-step gain inside `apply!` (free).
- Replace fixed `RANDOMIZED_PIN_INTERVAL` with moving-window threshold.
- Acceptance: at same step budget, final SSD ≤ D1 baseline on ≥3 of
  4 portrait fixtures.
- Depends on: D1.

---

## Phase 5 — Concurrency + opt-in features

### P5. Parallel colors
- Guard `@threads` over color channels on `nthreads() ≥ 2·n_colors`.
- Acceptance: RGB mode runtime ≤ 60% of pre-P5 on 8-core machine.
- Depends on: T2.

### D2. Beam search flag
- New `--beam K` CLI flag (default 1).
- `beam_pick` implementation with `undo!`.
- Acceptance: `--beam 4` reduces SSD ≥8% on portrait fixtures at fixed
  step budget; runtime penalty ≤2.5×.
- Depends on: D5.

---

## Phase 6 — Cleanups

### C2. LRU maxsize
- Set to `n_pins*(n_pins-1)÷2` (all chords fit).
- Depends on: P1.

### C3. Remove `--blur`
- After one tagged release with the deprecation warning, delete the flag
  and the `blur` field from `args`.
- Depends on: P2 + release cadence.

### C4. README + examples regeneration
- Regenerate every image in `examples/` with the new pipeline.
- Update README performance numbers.
- Depends on: everything above.

---

## Test strategy (referenced by SPEC §Test plan)

Every phase must pass the harness (T1) on all fixture images before merge.
Guardrails:

- **Correctness.** SSD(target, output) must not regress > 3% vs the
  previous phase's numbers.
- **Speed.** Wall-clock must not regress vs the previous phase.
- **Memory.** Peak allocation not > 1.2× previous phase.
- **Determinism.** With fixed `Random.seed!`, same args produce
  identical output (byte-equal PNG).

Anything that regresses one guardrail must justify it in the PR body or
be reverted.
