# common.jl — vendored shared utilities.
# Kept in sync (by convention) between StringArt.jl/src/ and MonteCarloArt.jl/src/.
# Edits in one must be mirrored to the other. `just check-sync` fails on drift.

using ArgParse
using Clustering: kmeans
using Colors
using Dates
using FileIO
using Images
using Logging
using Printf
using Statistics

# --- output resolution ---------------------------------------------------

"""
    resolve_output(spec) -> Vector{Tuple{String,Symbol}}

Parse `-o` argument. `spec` may be comma-separated paths. The file extension
determines format (`:png`, `:svg`, `:gif`). Missing/unknown extension
defaults to `:png` and appends `.png` to the path.
"""
function resolve_output(spec::AbstractString)::Vector{Tuple{String,Symbol}}
    map(split(spec, ",")) do path
        p = String(strip(path))
        ext = lowercase(splitext(p)[2])
        fmt = ext == ".png" ? :png :
              ext == ".svg" ? :svg :
              ext == ".gif" ? :gif : nothing
        if fmt === nothing
            p *= ".png"
            fmt = :png
        end
        (p, fmt)
    end
end

# --- image helpers -------------------------------------------------------

""" Crop rectangular image to a centered square. """
function crop_to_square(img::AbstractMatrix)
    h, w = size(img)
    s = min(h, w)
    y0 = div(h - s, 2) + 1
    x0 = div(w - s, 2) + 1
    @views img[y0:(y0 + s - 1), x0:(x0 + s - 1)]
end

""" Load image, crop to centered square, resize to `size`x`size`. """
function load_square(path::AbstractString, size::Int)
    isfile(path) || error("Image file not found: $path")
    img = Images.load(path)
    Images.imresize(crop_to_square(img), size, size)
end

""" Load image and convert to Lab{Float64}. """
load_lab(path::AbstractString, size::Int)::Matrix{Lab{Float64}} =
    convert.(Lab{Float64}, load_square(path, size))

# --- color helpers -------------------------------------------------------

""" Parse comma-separated hex colors, e.g. "#FF0000,#00FF00". """
parse_hex_colors(spec::AbstractString)::Vector{RGB{N0f8}} =
    map(c -> parse(RGB{N0f8}, strip(c)), split(spec, ","))

@inline color_distance(c1::Lab, c2::Lab)::Float64 =
    sqrt((c1.l - c2.l)^2 + (c1.a - c2.a)^2 + (c1.b - c2.b)^2)

@inline mean_color(pixels)::Lab{Float64} = Lab{Float64}(
    mean(p.l for p in pixels),
    mean(p.a for p in pixels),
    mean(p.b for p in pixels),
)

""" K-means palette in Lab space; returns k Lab centroids. """
function kmeans_palette_lab(img_lab::AbstractMatrix{<:Lab}, k::Int; maxiter::Int=100)
    pixels = reshape(collect(channelview(img_lab)), 3, :)
    result = kmeans(pixels, k, maxiter=maxiter, display=:none)
    Lab{Float64}[Lab{Float64}(c...) for c in eachcol(result.centers)]
end

# --- SVG helpers ---------------------------------------------------------

svg_open(w::Real, h::Real) =
    """<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h">"""

const SVG_CLOSE = "</svg>"

rgb_hex(c::RGB) = "#" * hex(c)
rgb_hex(c::Lab) = rgb_hex(convert(RGB{N0f8}, c))

function write_svg(path::AbstractString, body::AbstractString)
    open(path, "w") do io
        write(io, body)
    end
end

# --- CLI helpers ---------------------------------------------------------

""" Register CLI args common to both projects (input/output/steps/verbose).
    Canvas size is per-project (only StringArt uses it).
    Per-project default output path via `output_default` kwarg. """
function add_common_args!(
    parser::ArgParseSettings;
    steps_default::Int=1000,
    output_default::AbstractString="output.png",
)
    @add_arg_table! parser begin
        "--input", "-i"
            help = "input image path"
            arg_type = String
            required = true
        "--output", "-o"
            help = "output path with extension (.png/.svg/.gif); comma-separate for multiple"
            arg_type = String
            default = output_default
        "--steps"
            help = "algorithm iteration count"
            arg_type = Int
            default = steps_default
        "--verbose", "-v"
            help = "verbose (debug) logging"
            action = :store_true
    end
end

""" Switch to Debug logging when `--verbose` set. """
function setup_logging(args::AbstractDict)
    if get(args, "verbose", false)
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    end
end

# --- log timing helper ---------------------------------------------------

""" Elapsed-time state for log prefixes. Call `timer()` to get \"12.34s (+0.56s) => \". """
mutable struct LogTimer
    start::Dates.DateTime
    last::Dates.DateTime
end
LogTimer() = (n = Dates.now(); LogTimer(n, n))

function (t::LogTimer)()
    now_dt = Dates.now()
    total = abs(Dates.value(now_dt - t.start) / 1e3)
    delta = abs(Dates.value(now_dt - t.last) / 1e3)
    t.last = now_dt
    return @sprintf("%6.2fs (%+5.2fs) => ", total, delta)
end
