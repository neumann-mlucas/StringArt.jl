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

    run = select_function(args["function"])

    @info "Loading input image: '$input'"
    inp = StringArt.load_image(input, args["size"])

    @info "Running gray scale algorithm..."
    out = run(inp, args)

    @info "Saving final output image to: '$output'"
    out = Gray.(out)
    save(output * ".png", out)

    @info "Done"
end

function parse_cmd()
    # Create an argument parser
    parser = ArgParseSettings()
    # Add arguments to the parser
    @add_arg_table parser begin
        "--function", "-f"
        help = "util function to execute [plot_pins]"
        arg_type = String
        required = true
        "--input", "-i"
        help = "input image path"
        arg_type = String
        required = true
        "--output", "-o"
        help = "output image path whiteout extension"
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
        "--verbose"
        help = "verbose mode"
        action = :store_true
    end
    parse_args(parser)
end

function select_function(function_name:: String)
    if function_name == "plot_pins"
        return StringArt.plot_pins
    elseif function_name == "plot_chords"
        return StringArt.plot_chords
    end

    return x->x
end

end

StringArtUtils.main()
