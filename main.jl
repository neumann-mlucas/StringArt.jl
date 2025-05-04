module StringArtMain

include("stringart.jl")

using .StringArt

using ArgParse
using FileIO
using Images
using Logging

function main()
    # parse command line arguments
    args = parse_cmd()

    # verbose mode should use debug log level log level
    if args["verbose"]
        ENV["JULIA_DEBUG"] = Main
    end

    # handle color options
    args = args_postprocessing(args)

    @debug "Parsed arguments: $args"

    # use command line options to define algorithm parameters
    input_path, output_path = args["input"], args["output"]

    @info "Loading input image '$input_path'"
    inp = args["color-mode"] ? load_color_image(input_path, args["size"], args["colors"]) : load_image(input_path, args["size"])

    @info "Generating chords and pins positions"
    png, svg, gif = StringArt.run(inp, args)

    @info "Saving final output as a PNG..."
    save(output_path * ".png", png)

    args["svg"] && let
        @info "Saving final output as a PNG..."
        StringArt.save_svg(output_path, svg)
    end

    args["gif"] && let
        @info "Saving final output as a GIF..."
        StringArt.save_gif(output_path, gif)
    end

    @info "Done"
end

function parse_cmd()
    # Create an argument parser
    parser = ArgParseSettings()
    # Add arguments to the parser
    @add_arg_table parser begin
        "--input", "-i"
        help = "input image path"
        arg_type = String
        required = true
        "--output", "-o"
        help = "output image path whiteout extension"
        arg_type = String
        default = "output"
        "--gif"
        help = "Save output as a GIF"
        action = :store_true
        "--svg"
        help = "Save output as a SVG"
        action = :store_true
        "--color-mode"
        help = "RGB mode"
        action = :store_true
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
        "--custom-colors"
        help = "HEX code of colors to use in RGB mode"
        arg_type = String
        default = nothing
        "--use-color-pallet"
        help = "[WIP] extract a color pallet from the image to be use in color-mode"
        arg_type = Int
        default = nothing
        "--verbose"
        help = "verbose mode"
        action = :store_true
    end
    parse_args(parser)
end

function parse_colors(colors::String)::StringArt.Colors
    to_color(c) = parse(RGB{N0f8}, c)
    # default value for colors
    rgb_colors = [RGB{N0f8}(1.0, 0.0, 0.0), RGB{N0f8}(0.0, 1.0, 0.0), RGB{N0f8}(0.0, 0.0, 1.0)]
    try
        rgb_colors = map(to_color, split(colors, ","))
    catch e
        @error "Unable to parse '$colors' $e"
    end
    return rgb_colors
end

function args_postprocessing(args)::Dict{String,Any}
    # if color related argument is passed, run in RGB mode
    if !isnothing(args["custom-colors"]) || !isnothing(args["use-color-pallet"])
        args["color-mode"] = true
    end

    # parse colors from cmd arguments
    if !isnothing(args["use-color-pallet"])
        # WIP, not implemented yet
        args["colors"] = parse_colors(args["custom-colors"])
    elseif !isnothing(args["custom-colors"])
        # try to parse custom RGB colors
        args["colors"] = parse_colors(args["custom-colors"])
    elseif args["color-mode"]
        # use default Red, Green and Blue
        args["colors"] = parse_colors("#FF0000,#00FF00,#0000FF")
    else
        # run in greyscale mode
        args["colors"] = parse_colors("#000000")
    end

    # svg doesn't support gif mode
    if args["svg"]
        args["gif"] = false
    end

    return args
end

end

StringArtMain.main()
