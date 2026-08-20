module StringArtUtils

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

    outputs = StringArt.resolve_output(args["output"])
    length(outputs) == 1 || error("utils.jl expects a single output path")
    out_path, _ = outputs[1]

    fn_name = args["function"]
    input = args["input"]
    @info "Loading input image: '$input'"

    if fn_name in ("plot_pins", "plot_chords")
        black = [RGB{N0f8}(0, 0, 0)]
        cfg = StringArt.Config(
            size = args["size"],
            pins = args["pins"],
            line_strength = args["line-strength"],
            mode = StringArt.GrayscaleMode,
            colors = black,
        )
        inp = StringArt.load_image(input, cfg.size, black, StringArt.GrayscaleMode)[1]
        @info "Running $fn_name..."
        out =
            fn_name == "plot_pins" ? StringArt.plot_pins(inp, cfg) :
            StringArt.plot_chords(inp, cfg)
    else
        error("Unknown --function '$fn_name' (expected: plot_pins, plot_chords)")
    end

    @info "Saving final output image to: '$out_path'"
    save(out_path, Gray.(out))
    @info "Done"
end

function parse_cmd()
    parser = ArgParseSettings(
        description = "StringArt Utilities - Debug and visualization tools",
        epilog = "Example: julia utils.jl -f plot_pins -i input.jpg -o debug.png",
    )
    StringArt.add_common_args!(parser)
    @add_arg_table! parser begin
        "--size", "-s"
        help = "output canvas size in pixels"
        arg_type = Int
        default = 512
        "--function", "-f"
        help = "util function to execute (plot_pins, plot_chords)"
        arg_type = String
        required = true
        "--pins", "-n"
        help = "number of pins to use in canvas"
        arg_type = Int
        default = 180
        "--line-strength"
        help = "line intensity ranging from 1-100"
        arg_type = Int
        default = 25
    end
    parse_args(parser)
end

end

StringArtUtils.main()
