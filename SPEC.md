# StringArt.jl — Improvement Spec

Design notes for performance and drawing-quality upgrades. Each section states
the problem, the change, the file/lines touched, and the expected impact.

## Baseline

- Greedy per-pin chord selection minimizing SSD vs residual target.
- `select_best_chord` scores every candidate over full N×N SSD.
- `gen_img` rasterizes chord as N×N `N0f8` matrix, then `imfilter` gaussian.
- LRU (`SafeLRU`) caches rasterized chord images, keyed by `Pair{Point,Point}`.
- Per-color pass runs sequentially; inner error scan is threaded.

## Target invariants (must not regress)

- Deterministic given fixed seed / same args.
- CLI surface stays backwards compatible (deprecations allowed with warning).
- Grayscale, RGB, Palette modes all still produce a PNG. SVG + GIF output
  paths still functional.
- Multi-color still parallelizable safely.

---

## P1. Sparse chord representation + local error

**Problem.** `select_best_chord` (`stringart.jl:276`) computes `Images.ssd`
across the full N×N residual for every candidate chord. Cost per step:
`O(n_pins · N²)`. Chord touches ~N pixels; the other N²−N contribute nothing
to the ranking (they are identical across all candidates).

**Change.** Represent each chord as `(idx::Vector{Int32}, w::Vector{Float32})`
— pixel indices touched by the chord and their intensity weights. Score
against a flat `residual::Vector{Float32}`:

```
score = -Σ w[k] · residual[idx[k]]         # more negative = better
```

`apply!` subtracts `w` from `residual` in place at those indices. LRU keys
switch to `Tuple{Int,Int}` (pin index pair).

**Files.** `stringart.jl` — new `SparseChord`, `score`, `apply!`, replace
`gen_img` and `select_best_chord` internals. Cache type changes.

**Impact.** Per-step scan: `O(n_pins · N)` instead of `O(n_pins · N²)`.
Expected ~200–500× speedup on the hot loop at N=512. Cache memory drops
from N² × N0f8 per entry to ~2N floats — ~100× smaller.

---

## P2. Xiaolin Wu anti-aliased line

**Problem.** `bresenham_line!` (`stringart.jl:313`) writes a single pixel per
column at fixed strength. `imfilter(Kernel.gaussian(blur))` at
`stringart.jl:308` is applied per chord to fake antialiasing — a full 2D
convolution over N×N.

**Change.** Xiaolin Wu writes two pixels per column with subpixel weights.
Antialiasing is native to the rasterization. Removes `imfilter` from the hot
path. Weights fold directly into `SparseChord.w`.

**Files.** `stringart.jl` — replace `bresenham_line!` with `wu_line!` writing
into the sparse buffer. `--blur` CLI flag deprecated (warn if set,
ignore value).

**Impact.** Removes per-chord `imfilter` cost entirely. Output crisper (no
gaussian bleed). Cache entry becomes strictly sparse.

---

## P3. Int-tuple chord key

**Problem.** Chord identified by `Pair{ComplexF64,ComplexF64}` of rounded
pin coordinates. Four floats per key; hashing and equality both float-based.

**Change.** Store pins in a `PinSet{pts,nbrs}` struct indexed by pin id.
Chord key = `(min(i,j), max(i,j))::Tuple{Int,Int}`.

**Files.** `stringart.jl` — new `PinSet`, `build_pinset`, `chord_key`.
Consumers of `Chord` (SVG writer, gif rendering) receive `(i,j)` and resolve
to points via the pinset.

**Impact.** Cheaper hashing, no float precision risk, half the key bytes.
Also prerequisite for the exclude-repeated Set (P6).

---

## P4. Persistent residual, no per-step complement

**Problem.** `select_best_chord` calls `complement.(img)` every step
(`stringart.jl:277`) — N² allocation per step. `add_imgs!` walks the whole
image to composite. Total: two full N² passes per step, ignoring the fact
that only chord pixels change.

**Change.** Compute `residual = vec(Float32.(complement.(input)))` once.
`apply!` mutates only chord indices. Score reads only chord indices.
Threaded findmin uses per-thread partial mins (no shared best-so-far race).

**Files.** `stringart.jl` — new `run_algorithm_fast`. Old `run_algorithm`
removed (or delegated).

**Impact.** Zero per-step N² work outside the actual chord footprint.
Combines with P1 for the full asymptotic win.

---

## P5. Parallel colors

**Problem.** `run` at `stringart.jl:122` iterates colors sequentially. Inner
scan already threaded, but on small pin counts inner parallelism is thin.

**Change.** When `nthreads() ≥ 2·n_colors`, run color channels in parallel
via `@threads`. Otherwise keep serial to avoid oversubscription.

**Files.** `stringart.jl` — `run` outer loop.

**Impact.** ~2–3× speedup on RGB and palette modes when core count exceeds
color count.

**Risk.** Thread-safe cache (`SafeLRU`) already handled at `stringart.jl:27`.

---

## P6. exclude-repeated: bug fix + O(1) dedup

**Problem.** `stringart.jl:243` removes drawn chord from `pin2chords[pin]`
only. The same chord still lives in `pin2chords[other_endpoint]` — so it can
be re-selected from the other side. Silent correctness bug in
`--exclude-repeated-pins`.

**Change.** Maintain a `drawn::Set{Tuple{Int,Int}}` of chord keys. Skip
candidates whose key is in the set. Removes both the bug and the O(n)
`filter!`.

**Files.** `stringart.jl` — `run_algorithm_fast` inner loop.

**Impact.** Correct exclusion behavior; O(1) dedup per candidate.

---

## D1. Dark-emphasis weighted error

**Problem.** SSD-based error treats a marginal darkening of a light pixel
the same as of a dark pixel. Result: budget spent smoothing already-light
regions.

**Change.** Score weights residual by `residual^2`:

```
score -= w[k] · residual[idx[k]]^2
```

Dark pixels (where residual is large) dominate the ranking.

**Files.** `stringart.jl` — `score`.

**Impact.** Sharper subject reproduction, especially on portraits. One
extra multiply per pixel — negligible.

---

## D2. Beam search (opt-in)

**Problem.** Greedy is myopic — a good local pick can dead-end the walk.

**Change.** New `--beam=K` flag (default 1 = current behavior). At each
step, take top-K by first-step score, simulate `apply!`, score best
next-step, `undo!`. Pick the K with best `(s1 + s2)`.

**Files.** `stringart.jl` — `beam_pick`, `undo!`. CLI in `main.jl`.

**Impact.** ~2× slower per step at K=4. Empirically ~10–15% error
reduction on portraits. Off by default.

---

## D3. Negative-allowed residual (overdraw penalty)

**Problem.** `apply!` clamps residual at 0 — no cost to drawing a second
chord across an already-dark region. Result: blob-like buildup.

**Change.** Drop the `max(0, ...)` clamp in `apply!`. Residual can go
negative. Score naturally penalizes drawing again over that region
(negative residual → positive score contribution).

**Files.** `stringart.jl` — `apply!`.

**Impact.** Reduced clumping in dense areas. One-line change.

---

## D4. Per-channel palette normalization

**Problem.** `join_channels(::Val{PaletteMode})` at `stringart.jl:199`
normalizes R, G, B by a single `max(quantile(...))` divisor. Dominant
channel dims the others.

**Change.** Normalize each channel by its own max:

```julia
r ./= max(maximum(r), 1f0)
g ./= max(maximum(g), 1f0)
b ./= max(maximum(b), 1f0)
```

**Files.** `stringart.jl:199-202`.

**Impact.** Correct color balance in palette mode. Also faster (no
quantiles). Behavior change — regenerate palette-mode examples.

---

## D5. Adaptive random restart

**Problem.** `RANDOMIZED_PIN_INTERVAL = 100` forces a random pin every 100
steps regardless of whether the walk is stuck. Discards good greedy state.

**Change.** Track incremental gain per step (computed for free inside
`apply!`). Restart from a random pin only when a moving-window mean gain
drops below a threshold fraction of the initial gain.

**Files.** `stringart.jl` — `run_algorithm_fast`.

**Impact.** Fewer wasted steps after restart. Modest quality gain.

---

## Cleanups (drive-by)

- **LRU sizing.** With sparse rep, `maxsize` can safely be
  `n_pins·(n_pins-1)/2` — all possible chords fit. No eviction.
- **`--blur` deprecation.** Warn and ignore; remove after one release.
- **Chord key ordering.** `to_chord` sort by `(real, imag)` replaced by
  `min(i,j), max(i,j)` on indices.

## Explicit non-goals

- Not changing SVG output format.
- Not switching to CUDA/GPU (out of scope; separate spike).
- Not tuning k-means palette extraction (`main.jl:126`).
- Not changing the GIF pipeline (only the rendered content changes).

## Merge order

`P3 → P1+P2 → P4 → P6 → D3 → D4 → P5 → D1 → D5 → D2.`
Cleanups fold in at the end of each phase.

---

## Test strategy

Each phase must pass this harness before merge. Same fixtures, same seed,
same guardrails phase over phase — regression bugs surface as numeric
drops, quality bugs surface as visual regressions on targeted fixtures.

### Fixture set — what to test and why

Each image targets a specific failure mode. Add to `test/fixtures/`.
Store as PNG, ≤ 1 MB each, license permitting redistribution (public
domain / CC0 only).

| Fixture              | Category            | Targets                          | Why it discriminates                                                              |
|----------------------|---------------------|----------------------------------|-----------------------------------------------------------------------------------|
| `einstein.png`       | high-contrast face  | baseline, P1/P2, D1              | Sharp edges + fine hair/eyes. If Wu line loses sharpness vs Bresenham+blur, seen here first. |
| `portrait_soft.png`  | low-contrast face   | D1 (dark-emphasis)               | Subtle gradients. Weighted error should improve visible mid-tone reproduction.    |
| `david.gif` frame 0  | dark-on-light       | D3 (overdraw), P6                | Deep shadow regions. Overdraw penalty must reduce clumping in shadow.             |
| `moon_dark_bg.png`   | light-on-dark       | residual direction               | Inverts the usual target. Catches sign errors in complement/residual math.        |
| `checkerboard.png`   | geometric           | line aliasing                    | Wu vs Bresenham diverge cleanly on axis-aligned edges. Catches integer-rounding bugs. |
| `text.png`           | high-frequency      | D2 (beam), D5                    | Small strokes. Greedy fails; beam search benefit should show.                     |
| `gradient.png`       | smooth gradient     | D3 (clumping regression)         | Any blob artifact stands out immediately.                                         |
| `parrot.jpg`         | vivid multi-color   | D4 (palette normalization)       | Palette mode balance test. Broken normalization dulls the reds or greens.         |
| `flowers.jpg`        | muted multi-color   | D4, palette k-means              | Nearby colors in palette → tests palette-mode discrimination.                     |
| `tiny_128.png`       | small N             | scaling                          | Rounding / off-by-one at low resolution.                                          |
| `large_1024.png`     | large N             | scaling, cache pressure          | Ensures LRU sizing and threading hold at 4× canvas area.                          |

`einstein.png` and `david.gif` already ship in `examples/` — copy the
first frame of the gif and reuse.

### Metrics — recorded per fixture per phase

Store all metrics in `test/baseline.json`, keyed by `(fixture, phase)`.

- **SSD.** `sum((target .- output).^2)`. Primary correctness signal.
- **SSIM.** Structural similarity vs target. Cheap perceptual proxy;
  captures blur / clumping SSD misses. Use `ImageQualityIndexes.jl` if
  already in the manifest; else skip until it earns its keep.
- **Coverage.** Fraction of pixels in the darkest 10% of the target
  reached to within 20% of target intensity.
- **Overdraw histogram.** Chord-count per pixel; report the 99th
  percentile. Catches D3 regressions.
- **Wall-clock.** `@elapsed` of `run(inp, args)`.
- **Allocations.** `@allocated` on a 100-step slice of the inner loop.
- **Output hash.** `sha256` of the PNG bytes for determinism check.

### Guardrails

Merge blocked if any guardrail fires without explicit justification in
the PR body:

- SSD not > 1.03× previous phase (per fixture).
- SSIM not < 0.97× previous phase (per fixture).
- Wall-clock not > 1.0× previous phase, except phases explicitly
  documented as slower (D2 opt-in beam search).
- Peak allocations not > 1.2× previous phase.
- Determinism: with fixed `Random.seed!(42)`, PNG hash matches its own
  prior run bit-for-bit.

### Harness structure

```
test/
  runtests.jl              # entry, dispatches to files below
  test_baseline.jl         # runs all fixtures, records metrics
  test_correctness.jl      # SSD / SSIM guardrails, determinism, exclude-repeated dedup
  test_perf.jl             # wall-clock + allocations, tolerances
  test_visual_diff.jl      # writes side-by-side PNGs to test/artifacts/ for eyeball review
  fixtures/                # the images above
  baseline.json            # phase-tagged metrics
  artifacts/               # generated PNGs, .gitignored
```

Config per fixture (image path, mode, colors, seed, step budget) lives
in a `TESTS::Vector{NamedTuple}` at the top of `test_baseline.jl`.
Extending the fixture set = adding one entry.

### Determinism setup

- Fix `Random.seed!(42)` at the start of every test run.
- Pin manifest (commit `Manifest.toml`).
- Run single-threaded (`JULIA_NUM_THREADS=1`) in the determinism check;
  multi-threaded run is a separate case.

### CI matrix

- **Per-PR fast pass.** 3 fixtures (`einstein`, `checkerboard`,
  `gradient`), N=256, steps=500, single-threaded. ≤ 30 s target.
- **Nightly full pass.** All fixtures, N=512, steps=2000, threaded.
  ~5 min target.
- **Weekly scaling pass.** `large_1024.png` at N=1024, steps=4000.
  Catches memory or cache-size regressions the smaller passes miss.

### Visual diff workflow

`test_visual_diff.jl` writes:
- `<fixture>_target.png` — the input
- `<fixture>_output.png` — the phase's output
- `<fixture>_diff.png` — `abs.(target .- output)`, contrast-stretched

into `test/artifacts/`. Reviewer eyeballs any fixture whose SSD moved
> 1% in either direction, even within tolerance. Cheap human-in-the-loop
sanity check for cases the numbers miss.

### Manual acceptance for perceptual changes

D1, D3, D4, D5 change look, not just numbers. For each:
- Regenerate all `examples/` outputs.
- Diff against the pre-change commit visually.
- Note the perceptual change in the PR body ("shadows less clumpy",
  "red channel restored").

Numbers alone do not gate merge for perceptual changes — SSD can
improve while output looks worse (see: over-emphasized dark
regions). Reviewer sign-off on the artifact required.
