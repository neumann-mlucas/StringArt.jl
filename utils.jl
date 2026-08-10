module StringArtUtils

include("stringart.jl")

using .StringArt

using ArgParse
using Images
using Logging
using Random

Random.seed!(42)

const DefaultArgs = Dict{String,Any}((
    "blur" => 1,
    "line-strength" => 25,
    "pins" => 180,
    "size" => 500,
    "steps" => 1000,
    "gif" => false,
    "svg" => false,
))

function main()
    args = parse_cmd()

    if args["verbose"]
        ENV["JULIA_DEBUG"] = Main
    end

    args = merge(DefaultArgs, args)
    input, output = args["input"], args["output"]

    colors = parse_colors(args["colors"])
    fn_name = args["function"]

    @info "Loading input image: '$input'"

    if fn_name == "plot_color"
        args["colors"] = colors
        inp = StringArt.load_image(input, args["size"], colors, StringArt.RgbMode)
        @info "Running $fn_name..."
        out = StringArt.plot_color(inp, args)
    elseif fn_name == "plot_pins"
        args["colors"] = [RGB{N0f8}(0,0,0)]
        inp = StringArt.load_image(input, args["size"], args["colors"], StringArt.GrayscaleMode)[1]
        @info "Running $fn_name..."
        out = StringArt.plot_pins(inp, args)
    elseif fn_name == "plot_chords"
        args["colors"] = [RGB{N0f8}(0,0,0)]
        inp = StringArt.load_image(input, args["size"], args["colors"], StringArt.GrayscaleMode)[1]
        @info "Running $fn_name..."
        out = StringArt.plot_chords(inp, args)
    else
        error("Unknown --function '$fn_name' (expected: plot_pins, plot_chords, plot_color)")
    end

    @info "Saving final output image to: '$output'"
    save(output * ".png", Gray.(out))

    @info "Done"
end

function parse_cmd()
    parser = ArgParseSettings(
        description="StringArt Utilities - Debug and visualization tools",
        epilog="Example: julia utils.jl -f plot_pins -i input.jpg -o debug"
    )
    @add_arg_table parser begin
        "--function", "-f"
        help = "util function to execute (plot_pins, plot_chords, plot_color)"
        arg_type = String
        required = true
        "--input", "-i"
        help = "input image path"
        arg_type = String
        required = true
        "--output", "-o"
        help = "output image path without extension"
        arg_type = String
        default = "output"
        "--size", "-s"
        help = "output image size in pixels"
        arg_type = Int
        default = 512
        "--pins", "-n"
        help = "number of pins to use in canvas"
        arg_type = Int
        default = 180
        "--steps"
        help = "number of algorithm iterations"
        arg_type = Int
        default = 1000
        "--line-strength"
        help = "line intensity ranging from 1-100"
        arg_type = Int
        default = 25
        "--blur"
        help = "gaussian blur kernel size"
        arg_type = Int
        default = 1
        "--colors"
        help = "HEX code of colors to use for plot_color (comma-separated)"
        default = "#FF0000,#00FF00,#0000FF"
        "--gif"
        help = "Save output as a GIF"
        action = :store_true
        "--verbose"
        help = "verbose mode"
        action = :store_true
    end
    parse_args(parser)
end

function parse_colors(colors::String)::StringArt.Colors
    to_color(c) = parse(RGB{N0f8}, c)
    rgb_colors = [RGB{N0f8}(1,0,0), RGB{N0f8}(0,1,0), RGB{N0f8}(0,0,1)]
    try
        rgb_colors = map(to_color, split(colors, ","))
    catch e
        @error "Unable to parse '$colors' $e"
    end
    return rgb_colors
end

end

StringArtUtils.main()
