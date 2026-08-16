module StringArt

using Base.Threads: @threads
using LRUCache
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
end

const GIF_INTERVAL = 50
const RANDOMIZED_PIN_INTERVAL = 100
const SMALL_CHORD_CUTOFF = 0.10

# LRU chord cache. LRUCache.LRU has been thread-safe (internal SpinLock) since
# v1.4; @threads scoring is safe without an external lock.
# Sized for pins <= 500: C(500,2) = 124_750 unique chords.
const sparse_lru = LRU{Chord,SparseChord}(maxsize = 500 * 500)

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
export save_svg

# debug functions
export plot_pins
export plot_chords
export plot_color

""" Load and preprocess input image into per-channel grayscale layers. """
function load_image(
    path::String,
    size::Int,
    colors::Palette,
    mode::StringArtMode,
)::Vector{GrayImage}
    img = load_square(path, size)
    if mode == GrayscaleMode
        return [Gray{N0f8}.(img)]
    elseif mode == RgbMode
        return [red.(img), green.(img), blue.(img)]
    elseif mode == PaletteMode
        return _load_palette_layers(img, size, colors)
    end
    error("Unknown StringArtMode: $mode")
end

function _load_palette_layers(img, size::Int, colors::Palette)::Vector{GrayImage}
    lab_img = convert.(Lab{Float64}, img)
    lab_colors = convert.(Lab{Float64}, colors)
    map(lab_colors) do c
        layer = clamp01nan.(10.0 ./ (1.0 .+ color_distance.(lab_img, c)))
        complement.(layer)
    end
end

""" Main entry point. Returns (png, svg_string, gif_frames).
    `svg_string`/`gif_frames` are empty unless corresponding format is in `cfg.formats`. """
function render(input::Vector{GrayImage}, cfg::Config)::Tuple{RGBImage,String,GifFrames}
    sz = cfg.size
    pinset = build_pinset(cfg.pins, sz)
    want_svg = :svg in cfg.formats
    want_gif = :gif in cfg.formats

    # generate all chords, tagged with color-index
    chords = Tuple{Chord,Int}[]
    for (ci, (color, img)) in enumerate(zip(cfg.colors, input))
        @info cfg.timer() * "Iterating image with color: $(rgb_hex(color))"
        for chord in run_algorithm(img, pinset, cfg)
            push!(chords, (chord, ci))
        end
    end
    shuffle!(chords)

    frames = RGBImage[]
    svg = want_svg ? String[svg_open(sz, sz)] : String[]
    images = [zeros(N0f8, sz, sz) for _ in cfg.colors]

    @info cfg.timer() * "Rendering Chords"
    for (n, (chord, ci)) in enumerate(chords)
        apply_sparse_to_image!(images[ci], sparse_chord(chord, pinset, cfg))
        want_svg && push!(svg, draw_line(chord, pinset, cfg.colors[ci], cfg))
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
        for i in eachindex(img)
            intensity = Float64(img[i])
            r[i] += intensity * c.r
            g[i] += intensity * c.g
            b[i] += intensity * c.b
        end
    end

    max_val = max(quantile(vec(r), 0.99), quantile(vec(g), 0.99), quantile(vec(b), 0.99), 1)
    r ./= max_val
    g ./= max_val
    b ./= max_val
    return complement.(RGB.(clamp01nan.(r), clamp01nan.(g), clamp01nan.(b)))
end

""" Greedy chord-selection loop over a persistent sparse residual. """
function run_algorithm(input::GrayImage, pinset::PinSet, cfg::Config)::Vector{Chord}
    steps = div(cfg.steps, length(cfg.colors))
    npins = length(pinset.pts)

    residual = vec(Float32.(complement.(input)))
    output = Vector{Chord}()
    pin2chords = [Chord[chord_key(i, j) for j in pinset.nbrs[i]] for i = 1:npins]

    pin = rand(1:npins)
    scores = Float32[]
    for step = 1:steps
        if step % RANDOMIZED_PIN_INTERVAL == 0
            pin = rand(1:npins)
        end
        chords = pin2chords[pin]
        (cfg.exclude_repeated_pins && isempty(chords)) && break

        resize!(scores, length(chords))
        fill!(scores, Inf32)
        @threads for i in eachindex(chords)
            @inbounds scores[i] = score(sparse_chord(chords[i], pinset, cfg), residual)
        end
        chord = chords[argmin(scores)]

        apply!(sparse_chord(chord, pinset, cfg), residual)
        push!(output, chord)

        cfg.exclude_repeated_pins && filter!(c -> c != chord, pin2chords[pin])
        pin = chord[1] == pin ? chord[2] : chord[1]
    end
    return output
end

""" Sparse chord score against residual. Lower (more negative) = better. """
@inline function score(c::SparseChord, residual::Vector{Float32})::Float32
    s = 0.0f0
    @inbounds @simd for k in eachindex(c.idx)
        s -= c.w[k] * residual[c.idx[k]]
    end
    return s
end

""" Subtract chord weights from residual at chord pixel indices, clamped at 0. """
function apply!(c::SparseChord, residual::Vector{Float32})
    @inbounds for k in eachindex(c.idx)
        i = c.idx[k]
        v = residual[i] - c.w[k]
        residual[i] = v < 0.0f0 ? 0.0f0 : v
    end
end

""" Build or fetch sparse Xiaolin Wu antialiased chord (indices + subpixel weights). """
function sparse_chord(chord::Chord, pinset::PinSet, cfg::Config)::SparseChord
    get!(sparse_lru, chord) do
        strength = Float32(cfg.line_strength / 100)
        p, q = pinset.pts[chord[1]], pinset.pts[chord[2]]
        idx = Int32[]
        w = Float32[]
        wu_line!(
            idx,
            w,
            cfg.size,
            Float32(real(p)),
            Float32(imag(p)),
            Float32(real(q)),
            Float32(imag(q)),
            strength,
        )
        (idx = idx, w = w)
    end
end

@inline _lin_idx(row::Int, col::Int, sz::Int) = Int32((col - 1) * sz + row)

@inline function _wu_plot!(
    idx::Vector{Int32},
    w::Vector{Float32},
    sz::Int,
    x::Int,
    y::Int,
    weight::Float32,
    steep::Bool,
)
    weight > 0.0f0 || return
    # steep: image coord (y_img=x, x_img=y); non-steep: (y_img=y, x_img=x)
    row, col = steep ? (x, y) : (y, x)
    (1 <= row <= sz && 1 <= col <= sz) || return
    push!(idx, _lin_idx(row, col, sz))
    push!(w, weight)
end

""" Xiaolin Wu antialiased line rasterizer, sparse (idx, w) output.
    Coverage weight per pixel multiplied by `strength`. """
function wu_line!(
    idx::Vector{Int32},
    w::Vector{Float32},
    sz::Int,
    x0::Float32,
    y0::Float32,
    x1::Float32,
    y1::Float32,
    strength::Float32,
)
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
    dy = y1 - y0
    gradient = dx == 0.0f0 ? 1.0f0 : dy / dx

    # first endpoint
    xend = round(x0)
    yend = y0 + gradient * (xend - x0)
    xgap = 1.0f0 - ((x0 + 0.5f0) - floor(x0 + 0.5f0))
    xpxl1 = Int(xend)
    ypxl1 = Int(floor(yend))
    fy = yend - floor(yend)
    _wu_plot!(idx, w, sz, xpxl1, ypxl1,     strength * (1.0f0 - fy) * xgap, steep)
    _wu_plot!(idx, w, sz, xpxl1, ypxl1 + 1, strength * fy * xgap,           steep)
    intery = yend + gradient

    # second endpoint
    xend = round(x1)
    yend = y1 + gradient * (xend - x1)
    xgap = (x1 + 0.5f0) - floor(x1 + 0.5f0)
    xpxl2 = Int(xend)
    ypxl2 = Int(floor(yend))
    fy = yend - floor(yend)
    _wu_plot!(idx, w, sz, xpxl2, ypxl2,     strength * (1.0f0 - fy) * xgap, steep)
    _wu_plot!(idx, w, sz, xpxl2, ypxl2 + 1, strength * fy * xgap,           steep)

    # main loop
    @inbounds for x = (xpxl1 + 1):(xpxl2 - 1)
        iy = Int(floor(intery))
        fy = intery - floor(intery)
        _wu_plot!(idx, w, sz, x, iy,     strength * (1.0f0 - fy), steep)
        _wu_plot!(idx, w, sz, x, iy + 1, strength * fy,           steep)
        intery += gradient
    end
end

""" Sorted index pair identifying a chord regardless of endpoint order. """
@inline chord_key(i::Int, j::Int)::Chord = i < j ? (i, j) : (j, i)

""" Build PinSet: positions + per-pin neighbor index lists (distance-filtered). """
function build_pinset(n_pins::Int, canvas::Int)::PinSet
    pts = gen_pins(n_pins, canvas)
    threshold = canvas * SMALL_CHORD_CUTOFF
    nbrs = [
        Int[j for j = 1:n_pins if j != i && abs(pts[i] - pts[j]) > threshold] for
        i = 1:n_pins
    ]
    return PinSet(pts, nbrs)
end

""" Generate `n` evenly spaced points around a circle on a square canvas. """
function gen_pins(pins::Int, size::Int)::Vector{Point}
    center = (size / 2) + (size / 2) * 1im
    radius = 0.95 * (size / 2)
    phi = 2π .* (0:(pins-1)) ./ pins
    coords = radius .* exp.(phi .* 1im)
    return round.(coords .+ center)
end

""" Composite sparse chord into per-color accumulator, clamped at 1.0. """
function apply_sparse_to_image!(img::GrayImage, sc::SparseChord)
    @inbounds for k in eachindex(sc.idx)
        i = sc.idx[k]
        v = Float32(img[i]) + sc.w[k]
        img[i] = v > 1.0f0 ? N0f8(1.0f0) : N0f8(v)
    end
end

""" Write gif frames to disk. """
function save_gif(output::String, frames::GifFrames)
    isempty(frames) && return
    save(output, stack(frames; dims = 3), fps = 5)
end

""" Draw a line in SVG format. """
function draw_line(chord::Chord, pinset::PinSet, color::RGBColor, cfg::Config)::String
    p, q = pinset.pts[chord[1]], pinset.pts[chord[2]]
    x1, y1 = real(p), imag(p)
    x2, y2 = real(q), imag(q)
    width = @sprintf("%.2f", cfg.line_strength / 100)
    return """<line x1="$x1" x2="$x2" y1="$y1" y2="$y2" stroke="$(rgb_hex(color))" stroke-width="$width"/>"""
end

""" Write svg to disk. """
save_svg(output::String, svg::String) = write_svg(output, svg)

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
    for j in pinset.nbrs[1]
        apply_sparse_to_image!(input, sparse_chord(chord_key(1, j), pinset, cfg))
    end
    return clamp01nan.(input)
end

""" Visual debug: returns first grayscale channel. Stub for color support. """
plot_color(input::Vector{GrayImage}, cfg::Config)::GrayImage = input[1]

end
