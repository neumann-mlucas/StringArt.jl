module StringArt

using Base.Threads: @threads, nthreads
using Dates
using FileIO
using Images
using LRUCache
using Logging
using Printf
using Random
using Statistics

const Point = ComplexF64
const Chord = Tuple{Int,Int}
const GrayImage = Matrix{N0f8}
const SparseChord = @NamedTuple{idx::Vector{Int32}, w::Vector{Float32}}

struct PinSet
    pts::Vector{Point}
    nbrs::Vector{Vector{Int}}
end
const RGBColor = RGB{N0f8}
const RGBImage = Matrix{RGBColor}
const Colors = Vector{RGBColor}
const DefaultArgs = Dict{String,Any}

const GIF_INTERVAL = 50
const RANDOMIZED_PIN_INTERVAL = 100
const SMALL_CHORD_CUTOFF = 0.10

# Thread-safe LRU wrapper: gen_img is called from @threads and LRUCache.LRU
# is not guaranteed thread-safe across all published versions.
struct SafeLRU{K,V}
    lru::LRU{K,V}
    lock::ReentrantLock
end
SafeLRU{K,V}(; maxsize) where {K,V} = SafeLRU{K,V}(LRU{K,V}(maxsize=maxsize), ReentrantLock())

function Base.get!(f::Function, s::SafeLRU{K,V}, key::K) where {K,V}
    lock(s.lock) do
        get!(f, s.lru, key)
    end
end

# cache needed to store generated chords (very expensive to compute)
const lru = SafeLRU{Chord, GrayImage}(maxsize=180 * 180)
const sparse_lru = SafeLRU{Chord, SparseChord}(maxsize=180 * 180)

@enum StringArtMode GrayscaleMode RgbMode PaletteMode

export StringArtMode
export load_image
export run
export save_gif
export save_svg
export loghelper

# debug functions
export plot_pins
export plot_chords
export plot_color

mutable struct GifWrapper
    frames::Array{RGBColor}
    count::Int
end

# A wrapper that dispatches based on the OperationType
function load_image(image_path::String, size::Int, colors::Colors, mode:: StringArtMode)::Vector{GrayImage}
    load_image(image_path, size, colors, Val(mode))
end

""" Load, crop-to-square, and resize an image from disk. """
function load_and_prep(image_path::String, size::Int)
    @assert isfile(image_path) "Image file not found: $image_path"
    img = Images.load(image_path)
    img = crop_to_square(img)
    Images.imresize(img, size, size)
end

""" Load and preprocess a grayscale image: crop to square and resize. """
function load_image(image_path::String, size::Int, colors::Colors, mode:: Val{GrayscaleMode})::Vector{GrayImage}
    img = load_and_prep(image_path, size)
    return [convert(Matrix{N0f8}, Gray{N0f8}.(img))]
end

""" Load and decompose color image into grayscale channels based on given RGB filters. """
function load_image(image_path::String, size::Int, colors::Colors, mode:: Val{RgbMode})::Vector{GrayImage}
    img = load_and_prep(image_path, size)
    return [red.(img), green.(img), blue.(img)]
end

""" Load an image and create a set of grayscale images representing how well each pixel matches the colors in the palette. """
function load_image(image_path::String, size::Int, colors::Colors, mode:: Val{PaletteMode})::Vector{GrayImage}
    img = load_and_prep(image_path, size)

    # Convert the Image and colors to Lab space for better color comparison
    img = convert.(Lab{Float64}, img)
    colors = convert.(Lab{Float64}, colors)

    function distance(pixel_lab::Lab{Float64}, target_lab::Lab{Float64})::Float64
        return sqrt((pixel_lab.l - target_lab.l)^2 + (pixel_lab.a - target_lab.a)^2 + (pixel_lab.b - target_lab.b)^2)
    end

    # Create separate grayscale layer for each color
    layers = [zeros(Float64, size, size) for _ in eachindex(colors)]
    for (idx, color) in enumerate(colors)
        layers[idx] = clamp01nan.(10.0 ./ (1.0 .+ distance.(img, color)))
    end
    return [complement.(layer) for layer in layers]
end

""" Crop rectangular image to a centered square. """
function crop_to_square(image::Matrix)::Matrix
    # Calculate the size of the square
    height, width = size(image)
    crop_size = min(height, width)
    # Calculate the starting coordinates for the crop
    start_h = div(height - crop_size, 2) + 1
    start_w = div(width - crop_size, 2) + 1
    # Crop the image to a square shape
    @views image[start_h:(start_h+crop_size-1), start_w:(start_w+crop_size-1)]
end

""" Main function to generate string art image. Returns final image in png, svg and gif formats. """
function run(input::Vector{GrayImage}, args::DefaultArgs)::Tuple{RGBImage,String,GifWrapper}
    pinset = build_pinset(args["pins"], args["size"])

    # generate all chords to be draw in the canvas
    chords = Tuple[]
    for (color, img) in zip(args["colors"], input)
        @info loghelper(args) * "Iterating image with color: #$(hex(color))"
        for chord in run_algorithm_fast(img, pinset, args)
            push!(chords, (chord, color))
        end
    end
    shuffle!(chords)

    # initialize output image
    png = zeros(RGBColor, args["size"], args["size"])
    # create struct that holds gif frames
    gif = gen_gif_wrapper(args)
    # initialize svg content
    svg = [svg_header(args)]
    # initialize an image for each color
    images = Dict(color=>zeros(N0f8, args["size"], args["size"]) for color in args["colors"])

    @info loghelper(args) * "Rendering Chords"
    for (n, (chord, color)) in enumerate(chords)
        # add chord to png image
        img = gen_img(chord, pinset, args)
        add_imgs!(images[color], img)

        # draw svg shape
        if args["svg"]
            push!(svg, draw_line(chord, pinset, color, args))
        end
        # save gif frame
        if args["gif"] && n % GIF_INTERVAL == 0
            png = join_channels(images, args["mode"])
            save_frame(png, gif)
        end
    end
    push!(svg, "</svg>")

    png = join_channels(images, args["mode"])
    return (png, join(svg, "\n"), gif)
end


# A wrapper that dispatches based on the OperationType
function join_channels(images::Dict{RGBColor,GrayImage}, mode:: StringArtMode)::RGBImage
    return join_channels(images, Val(mode))
end

""" Join GrayImage channels into a single RGBImage based on the specified mode. """
function join_channels(images::Dict{RGBColor,GrayImage}, mode::Val{GrayscaleMode})::RGBImage
    return complement.(images[RGB(0,0,0)] .* RGB(1,1,1))
end

""" Join RGB channels into a single RGBImage. """
function join_channels(images::Dict{RGBColor,GrayImage}, mode::Val{RgbMode})::RGBImage
    r, g, b = images[RGB(1,0,0)], images[RGB(0,1,0)], images[RGB(0,0,1)]
    return complement.(RGB.(r, g, b))
end

""" Add multiple color channels to create a composite RGB image with proper color blending. """
function join_channels(images::Dict{RGBColor,GrayImage}, mode::Val{PaletteMode})::RGBImage
    # Get dimensions from the first image
    height, width = size(first(values(images)))

    r = zeros(Float32, height, width)
    g = zeros(Float32, height, width)
    b = zeros(Float32, height, width)

    # Add each color layer with its respective intensity
    for (color, img) in images
        color = complement.(color)
        for i in eachindex(img)
            intensity = Float64(img[i])
            r[i] += intensity * color.r
            b[i] += intensity * color.b
            g[i] += intensity * color.g
        end
    end

    # Normalize the RGB values to the range [0, 1]
    max_val = max(quantile(vec(r), 0.99), quantile(vec(g), 0.99), quantile(vec(b), 0.99), 1)
    r ./= max_val
    g ./= max_val
    b ./= max_val
    return complement.(RGB.(clamp01nan.(r), clamp01nan.(g), clamp01nan.(b)))
end

""" Fast sparse-residual variant of run_algorithm (P1). """
function run_algorithm_fast(input::GrayImage, pinset::PinSet, args::DefaultArgs)::Vector{Chord}
    steps = div(args["steps"], length(args["colors"]))
    exclude_repeated = get(args, "exclude-repeated-pins", false)
    npins = length(pinset.pts)

    # persistent residual: complement(input) as flat Float32
    residual = vec(Float32.(complement.(input)))
    output = Vector{Chord}()
    pin2chords = [Chord[chord_key(i, j) for j in pinset.nbrs[i]] for i in 1:npins]

    pin = rand(1:npins)
    scores = Float32[]
    for step = 1:steps
        if step % RANDOMIZED_PIN_INTERVAL == 0
            pin = rand(1:npins)
        end
        chords = pin2chords[pin]
        (exclude_repeated && isempty(chords)) && break

        resize!(scores, length(chords))
        fill!(scores, Inf32)
        @threads for i in eachindex(chords)
            @inbounds scores[i] = score(sparse_chord(chords[i], pinset, args), residual)
        end
        _, idx = findmin(scores)
        chord = chords[idx]

        apply!(sparse_chord(chord, pinset, args), residual)
        push!(output, chord)

        exclude_repeated && filter!(c -> c != chord, pin2chords[pin])
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

""" Subtract chord weights from residual at chord pixel indices. Clamped at 0 (D3 removes clamp). """
function apply!(c::SparseChord, residual::Vector{Float32})
    @inbounds for k in eachindex(c.idx)
        i = c.idx[k]
        v = residual[i] - c.w[k]
        residual[i] = v < 0f0 ? 0f0 : v
    end
end

""" Build or fetch sparse Bresenham chord (indices + constant weights). """
function sparse_chord(chord::Chord, pinset::PinSet, args::DefaultArgs)::SparseChord
    get!(sparse_lru, chord) do
        sz = args["size"]
        strength = Float32(args["line-strength"] / 100)
        p, q = pinset.pts[chord[1]], pinset.pts[chord[2]]
        idx = Int32[]
        w = Float32[]
        bresenham_sparse!(idx, w, sz,
                          round(Int, real(p)), round(Int, imag(p)),
                          round(Int, real(q)), round(Int, imag(q)),
                          strength)
        (idx=idx, w=w)
    end
end

""" Bresenham that pushes column-major linear indices instead of writing to an image. """
function bresenham_sparse!(idx::Vector{Int32}, w::Vector{Float32}, sz::Int,
                            x0::Int, y0::Int, x1::Int, y1::Int, strength::Float32)
    x0 = clamp(x0, 1, sz); y0 = clamp(y0, 1, sz)
    x1 = clamp(x1, 1, sz); y1 = clamp(y1, 1, sz)
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
    for x in x0:x1
        # column-major: linear index for M[row, col] is (col-1)*nrows + row
        if steep
            push!(idx, Int32((y - 1) * sz + x))  # M[x, y]
        else
            push!(idx, Int32((x - 1) * sz + y))  # M[y, x]
        end
        push!(w, strength)
        err -= dy
        if err < 0
            y += y_step
            err += dx
        end
    end
end

""" Sorted index pair identifying a chord regardless of endpoint order. """
@inline chord_key(i::Int, j::Int)::Chord = i < j ? (i, j) : (j, i)

""" Build PinSet: positions + per-pin neighbor index lists (distance-filtered). """
function build_pinset(n_pins::Int, canvas::Int)::PinSet
    pts = gen_pins(n_pins, canvas)
    threshold = canvas * SMALL_CHORD_CUTOFF
    nbrs = [Int[j for j in 1:n_pins if j != i && abs(pts[i] - pts[j]) > threshold]
            for i in 1:n_pins]
    return PinSet(pts, nbrs)
end

""" Generate `n` evenly spaced points around a circle on a square canvas. """
function gen_pins(pins::Int, size::Int)::Vector{Point}
    center = (size / 2) + (size / 2) * 1im
    radius = 0.95 * (size / 2)
    # evenly spaced angles [0, 2π) — no duplicate at 2π
    phi = 2π .* (0:pins-1) ./ pins
    coords = radius .* exp.(phi .* 1im)
    return round.(coords .+ center)
end

""" Generate grayscale image representing a line between two pins. """
function gen_img(chord::Chord, pinset::PinSet, args::DefaultArgs)::GrayImage
    get!(lru, chord) do
        # extract parameters from cli args
        size, blur = args["size"], args["blur"]
        strength = convert(N0f8, args["line-strength"] / 100)

        # resolve pin indices to points
        p = pinset.pts[chord[1]]
        q = pinset.pts[chord[2]]

        # create an empty image with pre-allocated zeros
        m = zeros(Gray{N0f8}, size, size)

        # Draw the line using Bresenham's algorithm
        bresenham_line!(m,
                        round(Int, real(p)), round(Int, imag(p)),
                        round(Int, real(q)), round(Int, imag(q)),
                        strength)

        # gaussian filter to smooth the line
        return imfilter(m, Kernel.gaussian(blur))
    end
end

""" Draw a line between two points using Bresenham's line algorithm. """
function bresenham_line!(img::Matrix{Gray{N0f8}}, x0::Int, y0::Int, x1::Int, y1::Int, strength::N0f8)
    # Ensure coordinates are within image bounds
    height, width = size(img)
    x0 = clamp(x0, 1, width)
    y0 = clamp(y0, 1, height)
    x1 = clamp(x1, 1, width)
    y1 = clamp(y1, 1, height)

    # Calculate line parameters
    steep = abs(y1 - y0) > abs(x1 - x0)

    # If the line is steep, transpose the image and coordinates
    if steep
        x0, y0 = y0, x0
        x1, y1 = y1, x1
    end

    # Ensure x0 <= x1
    if x0 > x1
        x0, x1 = x1, x0
        y0, y1 = y1, y0
    end

    # Calculate deltas and initial error
    dx = x1 - x0
    dy = abs(y1 - y0)
    err = div(dx, 2)

    # Determine step direction
    y_step = y0 < y1 ? 1 : -1
    y = y0

    # endpoints are already clamped; interior interpolated y stays in
    # [min(y0,y1), max(y0,y1)] so per-pixel bounds check is redundant
    for x in x0:x1
        if steep
            @inbounds img[x, y] = strength
        else
            @inbounds img[y, x] = strength
        end

        err -= dy
        if err < 0
            y += y_step
            err += dx
        end
    end

    return img
end

""" Safely inplace add two grayscale images, handling overflow for N0f8 values. """
function add_imgs!(dst::GrayImage, src::GrayImage)
    @fastmath @inbounds @simd for i in eachindex(dst, src)
        val = Float32(dst[i]) + Float32(src[i])
        dst[i] = val > 1.0f0 ? Gray{N0f8}(1.0f0) : Gray{N0f8}(val)
    end
    return dst
end


""" Add a frame to the gif sequence. """
function save_frame(img::RGBImage, gif::GifWrapper)
    gif.frames[:, :, gif.count] .= img
    gif.count += 1
end

""" Write gif frames to disk. """
function save_gif(output::String, gif::GifWrapper)
    gif_frames = gif.frames[:, :, 1:(gif.count-1)]
    save(output * ".gif", gif_frames, fps=5)
end

""" Initialize gif wrapper for given step count and color mode. """
function gen_gif_wrapper(args::Dict)::GifWrapper
    if !args["gif"]
        return GifWrapper(Array{RGBColor}(undef, 0, 0, 0), 0)
    end
    # exact frame count: run_algorithm produces div(steps, n_colors) chords per
    # color, save_frame fires every GIF_INTERVAL chords across the shuffled union
    n_colors = length(args["colors"])
    total_chords = n_colors * div(args["steps"], n_colors)
    n_frames = div(total_chords, GIF_INTERVAL)
    frames = Array{RGBColor}(undef, args["size"], args["size"], n_frames)
    return GifWrapper(frames, 1)
end

""" Generate SVG header with specified size. """
function svg_header(args::DefaultArgs)::String
    size = args["size"]
    blur = args["blur"]
    return """<svg xmlns="http://www.w3.org/2000/svg" width="$size" height="$size" viewBox="0 0 $size $size">
    <filter id="blur">
        <feGaussianBlur stdDeviation="$blur" />
    </filter>"""
end

""" Draw a line in SVG format. """
function draw_line(chord::Chord, pinset::PinSet, color::RGBColor, args::DefaultArgs)::String
    p, q = pinset.pts[chord[1]], pinset.pts[chord[2]]
    x1, y1 = real(p), imag(p)
    x2, y2 = real(q), imag(q)
    width = @sprintf("%.2f", args["line-strength"] / 100)
    return """<line x1="$x1" x2="$x2" y1="$y1" y2="$y2" stroke="#$(hex(color))" stroke-width="$width" filter="url(#blur)"/>"""
end

""" Write svg to disk. """
function save_svg(output::String, svg::String)
    open(output * ".svg", "w") do f
        write(f, svg)
    end
end

### DEBUGGING UTILITIES

""" Visual debug: overlay pin locations on image. """
function plot_pins(input::GrayImage, args::DefaultArgs)::GrayImage
    LEN = 4

    @debug "Generating pins positions"
    pins = gen_pins(args["pins"], args["size"])

    @debug "Plotting pins positions"
    width, height = size(input)
    for pin in pins
        lbx, ubx = Int(max(real(pin) - LEN, 0)), Int(min(real(pin) + LEN, width))
        lby, uby = Int(max(imag(pin) - LEN, 0)), Int(min(imag(pin) + LEN, height))
        input[lbx:ubx, lby:uby] .= 0
    end

    @debug "Done"
    return input
end

""" Visual debug: draw all chords from the first pin. """
function plot_chords(input::GrayImage, args::DefaultArgs)::GrayImage
    @debug "Generating chords"
    pinset = build_pinset(args["pins"], args["size"])

    @debug "Plotting chords"
    for j in pinset.nbrs[1]
        add_imgs!(input, gen_img(chord_key(1, j), pinset, args))
    end

    @debug "Done"
    return clamp01nan.(input)
end

""" Visual debug: returns first grayscale channel. Stub for color support. """
function plot_color(input::Vector{GrayImage}, args::DefaultArgs)::GrayImage
    return input[1]
end

function loghelper(args::DefaultArgs)
    now = Dates.now()
    total = abs(Dates.value(now - get!(args, "start_elapsed", now)) / 1e3)
    delta = abs(Dates.value(now - get!(args, "last_log_elapsed", now)) / 1e3)
    args["last_log_elapsed"] = now

    return @sprintf("%6.2fs (%+5.2fs) => ", total, delta)
end

end
