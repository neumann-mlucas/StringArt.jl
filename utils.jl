module StringArtUtils

include("stringart.jl")

using .StringArt

using ArgParse
using Images
using Logging

const DefaultArgs = Dict{String,Any}((
    "blur" => 1,
    "line-strength" => 25,
    "pins" => 180,
    "size" => 500,
    "steps" => 1000,
    "gif" => false,
    "color" => false,
    "colors" => "#FF0000,#00FF00,#0000FF",
))

function main()
    # parse command line arguments
    args = parse_cmd()

    # verbose mode should use debug log level log level
    if args["verbose"]
        ENV["JULIA_DEBUG"] = Main
    end

    # use command line options to define algorithm parameters
    args = merge(DefaultArgs, args)
    input, output = args["input"], args["output"]

    # default colors
    colors = parse_colors(args["colors"])
    # function to run
    run = select_function(args["function"])

    @info "Loading input image: '$input'"
    inp = StringArt.load_image(input, args["size"])
    if args["function"] == "plot_color"
        inp = StringArt.load_color_image(input, args["size"], colors)
    end

    @info "Running selected function $(args["function"])..."
    out = run(inp, args)

    @info "Saving final output image to: '$output'"
    out = Gray.(out)
    save(output * ".png", out)

    @info "Done"
end

function parse_cmd()
    # Create an argument parser
    parser = ArgParseSettings(
        description="StringArt Utilities - Debug and visualization tools",
        epilog="Example: julia utils.jl -f plot_pins -i input.jpg -o debug"
    )
    # Add arguments to the parser
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
        help = "HEX code of colors to use in RGB mode (comma-separated)"
        default = "#FF0000,#00FF00,#0000FF"
        "--color"
        help = "RGB mode"
        action = :store_true
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
    # default value for colors
    rgb_colors = [RGB(1,0,0), RGB(0,1,0), RGB(0,0,1)]
    try
        rgb_colors = map(to_color, split(colors,","))
    catch e
        @error "Unable to parse '$colors' $e"
    end
    return rgb_colors
end

function select_function(function_name::String)
    function_map = Dict(
        "plot_pins" => StringArt.plot_pins,
        "plot_chords" => StringArt.plot_chords,
        "plot_color" => StringArt.plot_color
    )
    
    get(function_map, function_name, x->x)
end

end

StringArtUtils.main()
