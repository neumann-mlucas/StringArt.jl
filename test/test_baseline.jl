module TestBaseline

using Random
using SHA
using TOML
using Statistics
using FileIO
using Images
using Logging

Random.seed!(42)

include(joinpath(@__DIR__, "..", "src", "StringArt.jl"))
using .StringArt

const HERE = @__DIR__
const ROOT = normpath(joinpath(HERE, ".."))
const PHASE = get(ENV, "PHASE", "pre-p1")
const TIER = Symbol(get(ENV, "TIER", "fast"))
const BASELINE_TOML = joinpath(HERE, "baseline.toml")
const ARTIFACT_DIR = joinpath(HERE, "artifacts", PHASE)

# Per-fixture config. `modes` filtered per tier.
# ponytail: modes+tier hard-coded here; extract to config file when it grows a third dimension.
const FIXTURES = [
    (name = "marcus-aurelius", file = "marcus-aurelius.png", tags = [:portrait, :fast]),
    (name = "moon", file = "moon.jpg", tags = [:contrast, :fast]),
    (name = "great-wave", file = "great_wave.jpg", tags = [:detail, :fast]),
    (name = "aristotle", file = "aristotle.png", tags = [:portrait]),
    (name = "girl-pearl", file = "girl_pearl.jpg", tags = [:portrait_soft]),
    (name = "van-gogh-self", file = "van_gogh_self.jpg", tags = [:dark_on_light]),
    (name = "mona-lisa", file = "mona_lisa.jpg", tags = [:portrait]),
    (name = "starry-night", file = "starry_night.jpg", tags = [:complex]),
    (name = "parrots", file = "parrots.png", tags = [:multicolor]),
    (name = "flowers", file = "flowers.png", tags = [:muted_color]),
    (name = "mandrill", file = "mandrill.tiff", tags = [:detail_color]),
    (name = "hats", file = "hats.png", tags = [:generic]),
]

const TIER_CFG = Dict(
    :fast => (
        size = 256,
        pins = 180,
        steps = 500,
        modes = [:grayscale],
        filter = f -> :fast in f.tags,
    ),
    :full => (
        size = 512,
        pins = 240,
        steps = 1500,
        modes = [:grayscale, :rgb, :palette6],
        filter = f -> true,
    ),
    :high => (
        size = 512,
        pins = 320,
        steps = 3000,
        modes = [:grayscale, :rgb, :palette6],
        filter = f -> true,
    ),
    :ultra => (
        size = 1024,
        pins = 480,
        steps = 6000,
        modes = [:grayscale, :rgb, :palette6],
        filter = f -> true,
    ),
)

function build_cfg(mode::Symbol, cfg, src::String; steps::Int = cfg.steps)::StringArt.Config
    colors, sa_mode = if mode == :grayscale
        ([RGB{N0f8}(0, 0, 0)], StringArt.GrayscaleMode)
    elseif mode == :rgb
        ([RGB{N0f8}(1, 0, 0), RGB{N0f8}(0, 1, 0), RGB{N0f8}(0, 0, 1)], StringArt.RgbMode)
    elseif mode == :palette6
        # k-means from image (seeded, deterministic). Fixed primaries produced
        # rainbow noise on natural images — see test_baseline.jl history.
        Random.seed!(42)
        img_lab = convert.(StringArt.Lab{Float64}, Images.load(src))
        lab_centers = StringArt.kmeans_palette_lab(img_lab, 6)
        (convert.(RGB{N0f8}, lab_centers), StringArt.PaletteMode)
    else
        error("unknown mode $mode")
    end
    StringArt.Config(
        size = cfg.size,
        pins = cfg.pins,
        steps = steps,
        line_strength = 25,
        mode = sa_mode,
        colors = colors,
    )
end

# Load target as grayscale in same geometry the algorithm sees.
function load_target_gray(path::String, sz::Int)
    img = Images.load(path)
    img = StringArt.crop_to_square(img)
    img = Images.imresize(img, sz, sz)
    return Float32.(Gray.(img))
end

function compute_metrics(target_gray::Matrix{Float32}, png)
    out_gray = Float32.(Gray.(png))
    ssd = Float64(sum((target_gray .- out_gray) .^ 2))
    dark_thresh = quantile(vec(target_gray), 0.10)
    dark_mask = target_gray .<= dark_thresh
    n_dark = count(dark_mask)
    coverage =
        n_dark == 0 ? 0.0 :
        sum(abs.(out_gray[dark_mask] .- target_gray[dark_mask]) .< 0.20) / n_dark
    return ssd, Float64(coverage)
end

function png_hash(path::String)
    return open(path) do io
        bytes2hex(sha2_256(io))
    end
end

function run_one(fixture, mode::Symbol, cfg)
    key = "$(fixture.name)::$(mode)"
    @info "[$PHASE][$TIER] $key"

    src = joinpath(HERE, "fixtures", fixture.file)
    isfile(src) || (@warn "missing fixture $src, skip"; return nothing)

    sa_cfg = build_cfg(mode, cfg, src)
    Random.seed!(42)
    input = StringArt.load_image(src, sa_cfg.size, sa_cfg.colors, sa_cfg.mode)

    Random.seed!(42)
    wall_s = @elapsed png, _, _ = StringArt.render(input, sa_cfg)

    target_gray = load_target_gray(src, cfg.size)
    ssd, coverage = compute_metrics(target_gray, png)

    out_png = joinpath(ARTIFACT_DIR, "$(fixture.name)__$(mode)_output.png")
    mkpath(dirname(out_png))
    FileIO.save(out_png, png)
    h = png_hash(out_png)

    return Dict{String,Any}(
        "fixture" => fixture.name,
        "mode" => String(mode),
        "phase" => PHASE,
        "tier" => String(TIER),
        "size" => cfg.size,
        "pins" => cfg.pins,
        "steps" => cfg.steps,
        "ssd" => ssd,
        "coverage" => coverage,
        "wall_clock_s" => wall_s,
        "sha256" => h,
    )
end

function run_all()
    cfg = TIER_CFG[TIER]
    entries = filter(cfg.filter, FIXTURES)
    @info "phase=$PHASE tier=$TIER — $(length(entries)) fixtures × $(length(cfg.modes)) modes"

    data = isfile(BASELINE_TOML) ? TOML.parsefile(BASELINE_TOML) : Dict{String,Any}()
    phase_bucket = get!(data, PHASE, Dict{String,Any}())

    for fixture in entries
        for mode in cfg.modes
            rec = run_one(fixture, mode, cfg)
            rec === nothing && continue
            phase_bucket["$(fixture.name)::$(mode)"] = rec
        end
    end

    open(BASELINE_TOML, "w") do io
        TOML.print(io, data)
    end
    @info "baseline written: $BASELINE_TOML"
    return data
end

const RESULTS = run_all()

end # module
