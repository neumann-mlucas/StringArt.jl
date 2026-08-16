# StringArt.jl — Task Ledger

Sequenced work items derived from `SPEC.md`. Each task lists the phase, the
minimum diff, the acceptance check, and dependencies. Merge order is the
task order.

Legend: **P** = performance, **D** = drawing, **C** = cleanup, **T** = test.

> **Path note.** Code now lives under `src/StringArt.jl` with vendored
> helpers in `src/common.jl`. CLI entry `main.jl` builds a `StringArt.Config`
> and calls `StringArt.render` (was `.run`). Removed post-refactor:
> `SafeLRU` (LRU is thread-safe already), `Val{Mode}` dispatch (replaced
> with `if`/`elseif`), args-bag `Dict{String,Any}` (replaced with `Config`),
> `--svg`/`--gif` CLI flags (format inferred from `-o` extension), the
> `Colors` type alias (renamed `Palette` to unshadow the `Colors` module).

---

## Phase 1 — Foundations

### T1. Test harness + baseline ✓ done
- Add `test/` per layout in `SPEC.md` §Test strategy → Harness structure.
- Copy the 12 fixtures into `test/fixtures/`.
- `test_baseline.jl` records SSD, coverage, wall-clock, allocations, and
  sha256 hash into `test/baseline.toml` (stdlib TOML — no JSON dep).
  SSIM skipped (no `ImageQualityIndexes` in manifest). Overdraw p99
  deferred (needs residual-side instrumentation post-P1/P4).
- `test_correctness.jl` enforces SSD guardrail vs previous phase's
  numbers. `test_perf.jl` gates wall-clock and allocation bytes.
- Fix `Random.seed!(42)` at the top of every entry point.
- Wire the CI matrix: fast-pass job (3 fixtures, N=256) on PR,
  nightly job for the full set. Fixture fetch step commented out
  until `test/fixtures/fetch.sh` is committed.
- Acceptance: `julia --startup-file=no test/runtests.jl` runs green,
  writes baseline metrics, produces `test/artifacts/` visual diffs.
- Depends on: none.

### C1. Port `Chord` to `Tuple{Int,Int}` key ✓ done
- New `PinSet` struct in `src/StringArt.jl` with `pts` and `nbrs` fields.
- `chord_key(i,j)` returns sorted `Tuple{Int,Int}`.
- Deleted `to_chord`, `gen_chords`; `build_pinset` computes neighbor
  index lists once. Cache key type `Pair{Point,Point}` → `Tuple{Int,Int}`.
- Acceptance: existing examples reproduce bit-for-bit (36/36 sha256
  hashes match pre-C1 on multi-thread full-tier run).
- Depends on: T1.

---

## Phase 2 — Sparse chord core

### P1. Sparse chord representation ✓ done
- New `SparseChord = @NamedTuple{idx::Vector{Int32}, w::Vector{Float32}}`.
- `score(c, residual)` and `apply!(c, residual)` operate on flat
  `Vector{Float32}`. Persistent residual and threaded scan folded in
  (P4 partially absorbed).
- Wired into `run_algorithm`. Legacy `run_algorithm` + `select_best_chord`
  gated behind `--legacy` initially, dropped in the follow-up cleanup.
- Acceptance: sparse hits ≥10× wall-clock speedup on fast tier
  (measured 10-52× per fixture; SSD improved 3-4× vs C1 baseline).
- Depends on: C1.

### P2. Xiaolin Wu line ✓ done
- `wu_line!` replaces `bresenham_sparse!`, writes `(idx, w)` with subpixel
  coverage weights (2 pixels per column). Endpoint xgap handling per
  standard Wu algorithm. Bounds check per push (Wu can spill 1 pixel past
  the endpoint clamp Bresenham enforced).
- Acceptance: no `imfilter` in hot path (was already gone since T2). Chord
  weight sum tracks line length × strength (spot check: pin1↔pin90 at
  N=256 emits 488 idx, sum=61.0 ≈ 243·0.25).

### P4. Persistent residual + threaded findmin ✓ partially done
- `residual::Vector{Float32}` initialized once — done in P1 rewrite.
- Threaded scan: currently uses shared `scores` array + `argmin`; SPEC
  calls for per-thread `part_s` / `part_k` partial-min reduction. TODO.
- Alloc gate: no separate 100-step allocation check yet.
- Depends on: P1, P2.

### T2. Remove `--legacy` path ✓ done
- Deleted `run_algorithm` (legacy), `select_best_chord`, `gen_img`,
  `bresenham_line!`, `add_imgs!`, image LRU cache, `GifWrapper` struct,
  `svg_header`, `--blur` flag, `--legacy` flag. Compositor moved to
  `apply_sparse_to_image!` writing sparse chord weights straight into
  the per-color accumulator.
- Acceptance: LOC delta strongly negative (-97 refactor + -37 gif).
- Depends on: P1, P2 (still awaiting Wu antialiasing).

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

### C3. Remove `--blur` ✓ done (early, skipped deprecation window)
- Flag and every `blur` reference removed in the T2 cleanup pass.
- SVG loses the `<filter>` element that referenced it.
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
