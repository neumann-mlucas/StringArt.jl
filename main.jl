module StringArtMain

include("src/StringArt.jl")

using .StringArt

using ArgParse
using FileIO
using Images
using Random

function main()
    Random.seed!(42)
    args = parse_cmd()
    StringArt.setup_logging(args)

    cfg, outputs, input_path = build_config(args)
    ts = cfg.timer

    @info ts() * "Loading input image '$input_path'"
    inp = StringArt.load_image(input_path, cfg.size, cfg.colors, cfg.mode)

    @info ts() * "Running StringArt algorithm..."
    png, svg, gif = StringArt.render(inp, cfg)

    for (path, fmt) in outputs
        @info ts() * "Saving output '$path' ($fmt)"
        if fmt == :png
            save(path, png)
        elseif fmt == :svg
            StringArt.save_svg(path, svg)
        elseif fmt == :gif
            StringArt.save_gif(path, gif)
        end
    end

    @info ts() * "Done"
end

function parse_cmd()
    parser = ArgParseSettings(
        description = "StringArt - Convert images to string art",
        epilog = "Example: julia main.jl -i input.jpg -o output.png",
    )
    StringArt.add_common_args!(parser)
    @add_arg_table! parser begin
        "--size", "-s"
        help = "output canvas size in pixels"
        arg_type = Int
        default = 512
        "--pins", "-n"
        help = "number of pins to use in canvas"
        arg_type = Int
        default = 180
        "--line-strength"
        help = "line intensity ranging from 1-100"
        arg_type = Int
        default = 25
        "--rgb"
        help = "use basic RGB color mode (default: red, green, blue)"
        action = :store_true
        "--custom-colors"
        help = "comma-separated HEX color codes for custom color strands (e.g. #FF0000,#00FF00)"
        arg_type = String
        default = nothing
        "--palette"
        help = "number of colors to extract as a palette from the input image (k-means clustering)"
        arg_type = Int
        default = nothing
        "--exclude-repeated-pins"
        help = "skip chords already drawn (yields noisier / more diffuse output)"
        action = :store_true
    end
    parse_args(parser)
end

function build_config(args::Dict{String,Any})
    outputs = StringArt.resolve_output(args["output"])
    formats = Set(fmt for (_, fmt) in outputs)
    colors, mode = resolve_palette(args)

    cfg = StringArt.Config(
        size = args["size"],
        pins = args["pins"],
        steps = args["steps"],
        line_strength = args["line-strength"],
        mode = mode,
        colors = colors,
        exclude_repeated_pins = args["exclude-repeated-pins"],
        formats = formats,
    )
    return cfg, outputs, args["input"]
end

function resolve_palette(args::Dict{String,Any})
    if !isnothing(args["palette"])
        return get_palette(args["input"], args["palette"]), StringArt.PaletteMode
    elseif !isnothing(args["custom-colors"])
        return StringArt.parse_hex_colors(args["custom-colors"]), StringArt.PaletteMode
    elseif args["rgb"]
        return StringArt.parse_hex_colors("#FF0000,#00FF00,#0000FF"), StringArt.RgbMode
    end
    return StringArt.parse_hex_colors("#000000"), StringArt.GrayscaleMode
end

function get_palette(path::String, k::Int)::Vector{RGB{N0f8}}
    @assert isfile(path) "Image file not found: $path"
    img_lab = convert.(Lab{Float64}, Images.load(path))
    lab_centers = StringArt.kmeans_palette_lab(img_lab, k)
    convert.(RGB{N0f8}, lab_centers)
end

end

StringArtMain.main()
