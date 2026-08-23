module StringArt

using Base.Threads: @threads
using Random

include("common.jl")

const Point = ComplexF64
const Chord = Tuple{Int,Int}
const GrayImage = Matrix{N0f8}
const RGBColor = RGB{N0f8}
const RGBImage = Matrix{RGBColor}
const Palette = Vector{RGBColor}
const SparseChord = @NamedTuple{idx::Vector{Int32}, w::Vector{Float32}}
const GifFrames = Vector{RGBImage}

struct PinSet
    pts::Vector{Point}
    nbrs::Vector{Vector{Int}}
    chords::Dict{Chord,SparseChord}
end

const GIF_INTERVAL = 50
# Adaptive restart: track EMA of per-step gain; jump to best-residual pin
# when EMA drops below RESTART_RATIO of initial gain. Min-interval guard
# prevents thrashing between neighboring restart candidates.
const RESTART_EMA_ALPHA = 0.05f0
const RESTART_RATIO = 0.30f0
const MIN_RESTART_INTERVAL = 20
# short chords add near-zero signal; skip to shrink per-pin neighbor list
const SMALL_CHORD_CUTOFF = 0.10

@enum StringArtMode GrayscaleMode RgbMode PaletteMode

Base.@kwdef struct Config
    size::Int = 512
    pins::Int = 180
    steps::Int = 1000
    line_strength::Int = 25
    mode::StringArtMode = GrayscaleMode
    colors::Palette = [RGBColor(0, 0, 0)]
    exclude_repeated_pins::Bool = false
    formats::Set{Symbol} = Set{Symbol}()
    timer::LogTimer = LogTimer()
end

export Config
export StringArtMode, GrayscaleMode, RgbMode, PaletteMode
export load_image
export render
export save_gif

# debug functions
export plot_pins
export plot_chords

""" Load and preprocess input image into per-channel grayscale layers.
    Grayscale + palette layers are histogram-equalized individually.
    RGB is equalized via a shared luminance gain to preserve hue —
    per-channel eq decorrelates R/G/B and shifts skin tones / whites. """
function load_image(
    path::String,
    size::Int,
    colors::Palette,
    mode::StringArtMode,
)::Vector{GrayImage}
    img = load_square(path, size)
    if mode == GrayscaleMode
        eq = adjust_histogram(Gray{N0f8}.(img), Equalization())
        return [GrayImage(eq)]
    elseif mode == RgbMode
        return _load_rgb_layers(img)
    elseif mode == PaletteMode
        # No equalization: palette layers are gaussian selectivity maps in
        # [0,1]; equalization would spread sparse membership across full range
        # and blur color assignment.
        return _load_palette_layers(img, size, colors)
    end
    error("Unknown StringArtMode: $mode")
end

# Luminance-gain equalization: preserves hue by scaling R/G/B uniformly per
# pixel by y_eq/y. Gain capped at RGB_GAIN_MAX to stop shadow-pixel blowout
# where tiny y produces huge gain and channels clamp to white.
const RGB_GAIN_MAX = 4.0f0
function _load_rgb_layers(img)::Vector{GrayImage}
    rgb = RGB{N0f8}.(img)
    y = Gray{N0f8}.(rgb)
    y_eq = adjust_histogram(y, Equalization())
    gain = min.(Float32.(y_eq) ./ max.(Float32.(y), 1.0f-3), RGB_GAIN_MAX)
    scale_ch(ch) = GrayImage(N0f8.(clamp01nan.(Float32.(ch) .* gain)))
    [scale_ch(red.(rgb)), scale_ch(green.(rgb)), scale_ch(blue.(rgb))]
end

# Palette layer weight: gaussian in Lab distance. Sigma auto-tuned from
# palette geometry — 0.5 × median pairwise ΔE — so tight palettes get
# selective layers and sparse palettes get overlapping ones.
const PALETTE_SIGMA_FALLBACK = 15.0
function _load_palette_layers(img, size::Int, colors::Palette)::Vector{GrayImage}
    lab_img = convert.(Lab{Float64}, img)
    lab_colors = convert.(Lab{Float64}, colors)
    sigma = _palette_sigma(lab_colors)
    two_sigma_sq = 2.0 * sigma^2
    map(lab_colors) do c
        d2 = color_distance.(lab_img, c) .^ 2
        weight = exp.(-d2 ./ two_sigma_sq)
        complement.(clamp01nan.(weight))
    end
end

function _palette_sigma(lab_colors::Vector{Lab{Float64}})::Float64
    n = length(lab_colors)
    n < 2 && return PALETTE_SIGMA_FALLBACK
    dists = Float64[
        color_distance(lab_colors[i], lab_colors[j]) for i = 1:n for j = (i+1):n
    ]
    max(0.5 * median(dists), 1.0)
end

""" Main entry point. Returns (png, svg_string, gif_frames).
    `svg_string`/`gif_frames` are empty unless corresponding format is in `cfg.formats`. """
function render(input::Vector{GrayImage}, cfg::Config)::Tuple{RGBImage,String,GifFrames}
    sz = cfg.size
    pinset = build_pinset(cfg.pins, sz)
    want_svg = :svg in cfg.formats
    want_gif = :gif in cfg.formats

    # each color layer picks its own line strength based on target darkness;
    # keep it per-chord so the compositor draws with the same strength the
    # algorithm scored against.
    chords = Tuple{Chord,Int,Float32}[]
    for (ci, (color, img)) in enumerate(zip(cfg.colors, input))
        @info cfg.timer() * "Iterating image with color: $(rgb_hex(color))"
        picks, strength = run_algorithm(img, pinset, cfg)
        for chord in picks
            push!(chords, (chord, ci, strength))
        end
    end
    shuffle!(chords)

    frames = RGBImage[]
    svg = want_svg ? String[svg_open(sz, sz)] : String[]
    images = [zeros(N0f8, sz, sz) for _ in cfg.colors]

    @info cfg.timer() * "Rendering Chords"
    for (n, (chord, ci, strength)) in enumerate(chords)
        apply_sparse_to_image!(images[ci], sparse_chord(chord, pinset), strength)
        want_svg && push!(svg, draw_line(chord, pinset, cfg.colors[ci], strength))
        if want_gif && n % GIF_INTERVAL == 0
            push!(frames, join_channels(images, cfg.colors, cfg.mode))
        end
    end
    want_svg && push!(svg, SVG_CLOSE)

    png = join_channels(images, cfg.colors, cfg.mode)
    return (png, join(svg, "\n"), frames)
end

""" Composite per-color grayscale accumulators into a display RGB image. """
function join_channels(
    images::Vector{GrayImage},
    colors::Palette,
    mode::StringArtMode,
)::RGBImage
    if mode == GrayscaleMode
        return complement.(images[1] .* RGB(1, 1, 1))
    elseif mode == RgbMode
        return complement.(RGB.(images[1], images[2], images[3]))
    elseif mode == PaletteMode
        return _join_palette(images, colors)
    end
    error("Unknown StringArtMode: $mode")
end

function _join_palette(images::Vector{GrayImage}, colors::Palette)::RGBImage
    height, width = size(images[1])
    r = zeros(Float32, height, width)
    g = zeros(Float32, height, width)
    b = zeros(Float32, height, width)

    for (color, img) in zip(colors, images)
        c = complement(color)
        intensity = Float32.(img)
        r .+= intensity .* Float32(c.r)
        g .+= intensity .* Float32(c.g)
        b .+= intensity .* Float32(c.b)
    end

    # Per-channel 0.99 quantile normalization: shared divisor lets the
    # dominant channel dim the others. 0.99 (not max) stays robust to
    # bright-specular outliers that would otherwise crush contrast.
    r ./= max(quantile(vec(r), 0.99), 1.0f0)
    g ./= max(quantile(vec(g), 0.99), 1.0f0)
    b ./= max(quantile(vec(b), 0.99), 1.0f0)
    return complement.(RGB.(clamp01nan.(r), clamp01nan.(g), clamp01nan.(b)))
end

""" Greedy chord-selection loop over a persistent sparse residual.
    Returns (chosen chords, strength used) so the compositor can render with
    the same strength the algorithm optimized against. """
function run_algorithm(
    input::GrayImage,
    pinset::PinSet,
    cfg::Config,
)::Tuple{Vector{Chord},Float32}
    steps = cfg.steps  # per-color budget: color modes need full pass, not STEPS/n_colors
    npins = length(pinset.pts)
    sz = cfg.size

    residual = vec(Float32.(complement.(input)))
    strength = adaptive_strength(residual, cfg.line_strength)

    output = Vector{Chord}()
    pin2chords = [Chord[chord_key(i, j) for j in pinset.nbrs[i]] for i = 1:npins]

    pin = rand(1:npins)
    scores = Float32[]
    ema_gain = 0.0f0
    initial_gain = 0.0f0
    last_restart = 0
    just_restarted = false
    for step = 1:steps
        chords = pin2chords[pin]
        (cfg.exclude_repeated_pins && isempty(chords)) && break

        resize!(scores, length(chords))
        fill!(scores, Inf32)
        @threads for i in eachindex(chords)
            @inbounds scores[i] = score(sparse_chord(chords[i], pinset), residual)
        end
        best_idx = argmin(scores)
        best_score = scores[best_idx]
        # score is `-Σ w·residual·|residual|`; positive = best chord puts more
        # ink into oversaturated pixels than needy ones. Local dead-end at
        # current pin → jump to best-residual pin. Only break if restart's
        # pin is ALSO positive → globally converged. Warmup 50 steps.
        if step > 50 && best_score >= 0.0f0
            if just_restarted
                @info "early-stop at step $step / $steps (converged)"
                break
            end
            pin = best_residual_pin(residual, pinset, sz)
            last_restart = step
            ema_gain = initial_gain
            just_restarted = true
            continue
        end
        just_restarted = false
        chord = chords[best_idx]

        gain = -best_score
        if step == 1
            initial_gain = gain
            ema_gain = gain
        else
            ema_gain = RESTART_EMA_ALPHA * gain + (1 - RESTART_EMA_ALPHA) * ema_gain
        end

        apply!(sparse_chord(chord, pinset), residual, strength)
        push!(output, chord)

        cfg.exclude_repeated_pins && filter!(c -> c != chord, pin2chords[pin])
        stalled =
            step - last_restart >= MIN_RESTART_INTERVAL &&
            ema_gain < RESTART_RATIO * initial_gain
        if stalled
            pin = best_residual_pin(residual, pinset, sz)
            last_restart = step
            ema_gain = initial_gain  # reset so we don't immediately re-trigger
        else
            pin = chord[1] == pin ? chord[2] : chord[1]
        end
    end
    return (output, strength)
end

""" Per-image line strength. Bright targets (few dark pixels) need each
    chord to count → higher strength. Dark targets (many dark pixels) want
    finer control across many chord crossings → lower strength.
    `base` is `cfg.line_strength` (0..100); returned as [0..1] Float32. """
const TARGET_MEAN_DARK = 0.35f0
@inline function adaptive_strength(residual::Vector{Float32}, base::Int)::Float32
    base_f = Float32(base) / 100.0f0
    mean_dark = max(mean(residual), 1.0f-3)
    scale = clamp(TARGET_MEAN_DARK / mean_dark, 0.5f0, 2.0f0)
    return base_f * scale
end

""" Sparse chord score against residual. Lower (more negative) = better.
    Weight is `residual * |residual|` — magnitude-squared with sign preserved,
    so dark (large-residual) pixels dominate ranking while oversaturated
    (negative-residual) pixels still repel via the early-stop sign check. """
@inline function score(c::SparseChord, residual::Vector{Float32})::Float32
    s = 0.0f0
    @inbounds @simd for k in eachindex(c.idx)
        r = residual[c.idx[k]]
        s -= c.w[k] * r * abs(r)
    end
    return s
end

""" Subtract `strength * w` from residual at chord pixel indices.
    Residual is allowed to go negative — oversaturated pixels contribute a
    positive term to `score()`, discouraging further chords through them. """
function apply!(c::SparseChord, residual::Vector{Float32}, strength::Float32)
    @inbounds for k in eachindex(c.idx)
        residual[c.idx[k]] -= strength * c.w[k]
    end
end

""" Sparse gaussian chord lookup. Precomputed at `build_pinset` time so the
    scoring loop is a pure read (no lock, no cache miss). """
@inline sparse_chord(chord::Chord, pinset::PinSet)::SparseChord = pinset.chords[chord]

function _build_sparse_chord(chord::Chord, pts::Vector{Point}, sz::Int)::SparseChord
    p, q = pts[chord[1]], pts[chord[2]]
    idx = Int32[]
    w = Float32[]
    bresenham_sparse!(
        idx,
        w,
        sz,
        round(Int, real(p)),
        round(Int, imag(p)),
        round(Int, real(q)),
        round(Int, imag(q)),
    )
    (idx=idx, w=w)
end

""" Bresenham + 5-tap gaussian dilate perpendicular to the major axis.
    Emulates the sigma=1 gaussian blur c1-tuple/pre-p1 applied post-raster,
    so per-pixel peak matches (~0.10 at strength=0.25) and stroke energy
    spreads over 5 rows — restores density on 512-canvas full-tier fixtures. """
const GAUSS5 = (0.06f0, 0.24f0, 0.40f0, 0.24f0, 0.06f0)
function bresenham_sparse!(
    idx::Vector{Int32},
    w::Vector{Float32},
    sz::Int,
    x0::Int,
    y0::Int,
    x1::Int,
    y1::Int,
)
    x0 = clamp(x0, 1, sz)
    y0 = clamp(y0, 1, sz)
    x1 = clamp(x1, 1, sz)
    y1 = clamp(y1, 1, sz)
    steep = abs(y1 - y0) > abs(x1 - x0)
    if steep
        x0, y0 = y0, x0
        x1, y1 = y1, x1
    end
    if x0 > x1
        x0, x1 = x1, x0
        y0, y1 = y1, y0
    end
    dx = x1 - x0
    dy = abs(y1 - y0)
    err = div(dx, 2)
    y_step = y0 < y1 ? 1 : -1
    y = y0
    for x = x0:x1
        # column-major: linear index for M[row, col] is (col-1)*nrows + row
        # kernel offsets -2..+2 perpendicular to major axis
        for k = 1:5
            yk = y + (k - 3)
            (yk < 1 || yk > sz) && continue
            if steep
                push!(idx, Int32((yk - 1) * sz + x))   # M[x, yk]
            else
                push!(idx, Int32((x - 1) * sz + yk))   # M[yk, x]
            end
            push!(w, GAUSS5[k])
        end
        err -= dy
        if err < 0
            y += y_step
            err += dx
        end
    end
end

@inline chord_key(i::Int, j::Int)::Chord = i < j ? (i, j) : (j, i)

# Half-side of pin-restart scan box (pixels).
const RESTART_BOX_R = 20

""" Pin whose local (R×R) residual sum is highest — jumps the algorithm to
    where more ink still needs to go instead of uniform random exploration. """
function best_residual_pin(residual::Vector{Float32}, pinset::PinSet, sz::Int)::Int
    best_p = 1
    best_s = -Inf32
    R = RESTART_BOX_R
    @inbounds for p in eachindex(pinset.pts)
        pt = pinset.pts[p]
        px = round(Int, real(pt))
        py = round(Int, imag(pt))
        s = 0.0f0
        for dx = (-R):R
            x = px + dx
            (x < 1 || x > sz) && continue
            col = (x - 1) * sz
            for dy = (-R):R
                y = py + dy
                (y < 1 || y > sz) && continue
                s += residual[col+y]
            end
        end
        if s > best_s
            best_s = s
            best_p = p
        end
    end
    return best_p
end

""" Build PinSet: positions + per-pin neighbor index lists (distance-filtered)
    + precomputed sparse chord for every neighbor pair. Precompute runs once
    per pinset so the parallel scoring loop can be pure Dict reads. """
function build_pinset(n_pins::Int, canvas::Int)::PinSet
    pts = gen_pins(n_pins, canvas)
    threshold = canvas * SMALL_CHORD_CUTOFF
    nbrs = [
        Int[j for j = 1:n_pins if j != i && abs(pts[i] - pts[j]) > threshold] for
        i = 1:n_pins
    ]
    chords = Dict{Chord,SparseChord}()
    for i = 1:n_pins, j in nbrs[i]
        c = chord_key(i, j)
        haskey(chords, c) || (chords[c] = _build_sparse_chord(c, pts, canvas))
    end
    return PinSet(pts, nbrs, chords)
end

function gen_pins(pins::Int, size::Int)::Vector{Point}
    center = (size / 2) + (size / 2) * 1im
    radius = 0.95 * (size / 2)
    phi = 2π .* (0:(pins-1)) ./ pins
    coords = radius .* exp.(phi .* 1im)
    return round.(coords .+ center)
end

""" Composite sparse chord into per-color accumulator at the given `strength`,
    clamped at 1.0. """
function apply_sparse_to_image!(img::GrayImage, sc::SparseChord, strength::Float32)
    @inbounds for k in eachindex(sc.idx)
        i = sc.idx[k]
        v = Float32(img[i]) + strength * sc.w[k]
        img[i] = v > 1.0f0 ? N0f8(1.0f0) : N0f8(v)
    end
end

""" Write gif frames to disk. """
function save_gif(output::String, frames::GifFrames)
    isempty(frames) && return
    save(output, stack(frames; dims=3), fps=5)
end

# Match raster: Bresenham + GAUSS5 dilation gives ~3 px of full-opacity
# coverage (middle taps 0.24/0.40/0.24) with 0.40 peak. Emit SVG stroke as
# a 3-wide line at opacity = strength * peak so per-chord density matches.
const SVG_STROKE_WIDTH = 3.0
const SVG_GAUSS_PEAK = 0.40f0
function draw_line(chord::Chord, pinset::PinSet, color::RGBColor, strength::Float32)::String
    p, q = pinset.pts[chord[1]], pinset.pts[chord[2]]
    x1, y1 = real(p), imag(p)
    x2, y2 = real(q), imag(q)
    opacity = @sprintf("%.3f", clamp(strength * SVG_GAUSS_PEAK, 0.0f0, 1.0f0))
    return """<line x1="$x1" x2="$x2" y1="$y1" y2="$y2" stroke="$(rgb_hex(color))" stroke-width="$SVG_STROKE_WIDTH" stroke-opacity="$opacity"/>"""
end

### DEBUGGING UTILITIES

""" Visual debug: overlay pin locations on image. """
function plot_pins(input::GrayImage, cfg::Config)::GrayImage
    LEN = 4
    pins = gen_pins(cfg.pins, cfg.size)
    height, width = size(input)
    for pin in pins
        x = round(Int, real(pin))
        y = round(Int, imag(pin))
        lbx, ubx = clamp(x - LEN, 1, width), clamp(x + LEN, 1, width)
        lby, uby = clamp(y - LEN, 1, height), clamp(y + LEN, 1, height)
        input[lbx:ubx, lby:uby] .= 0
    end
    return input
end

""" Visual debug: draw all chords from the first pin. """
function plot_chords(input::GrayImage, cfg::Config)::GrayImage
    pinset = build_pinset(cfg.pins, cfg.size)
    strength = Float32(cfg.line_strength / 100)
    for j in pinset.nbrs[1]
        apply_sparse_to_image!(input, sparse_chord(chord_key(1, j), pinset), strength)
    end
    return clamp01nan.(input)
end

end
