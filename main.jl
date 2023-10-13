module StringArt

using ArgParse
using Base
using Base.Threads
using Dates
using FileIO
using Images
using Logging
using Memoize

const Point = ComplexF64
const Chord = Pair{Point}
const Image = Matrix{N0f8}

const INTERVAL = 20

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

    if args["gif"]
        frames =
            (args["color"]) ? 3 * div(args["steps"], INTERVAL) :
            div(args["steps"], INTERVAL)
        global gif_frames = Array{N0f8}(undef, args["size"], args["size"], frames)
        global gif_count = 1
    end

    if !args["color"]
        @info "Loading input image: '$input'"
        inp = load_image(input, args["size"])

        @info "Running gray scale algorithm..."
        out = run(inp, args)

        @info "Saving final output image to: '$output'"
        out = Gray.(complement.(out))
        save(output * ".png", out)
    else
        @info "Loading input image: '$input'"
        rgb = load_rgb_image(input, args["size"])

        @info "Running RGB algorithm..."
        rgb = [run(color, args) for color in rgb]

        @info "Saving final output image to: '$output'"
        out = complement.(RGB.(rgb...))
        save(output * ".png", out)
    end

    @info "Saving final output as a GIF..."
    args["gif"] && save_gif(output, args["color"])

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

# TODO: enhance image contrast here
function load_image(image_path::String, size::Int)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Resize the image to the specified dimensions
    img = crop_to_square(img)
    img = Images.imresize(img, size, size)
    # Convert the Image to gray scale
    N0f8.(Gray.(img))
end

# TODO: enhance image contrast here
function load_rgb_image(image_path::String, size::Int)::Tuple{Image,Image,Image}
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Resize the image to the specified dimensions
    img = crop_to_square(img)
    img = Images.imresize(img, size, size)
    # Convert the Image to gray scale
    red.(img), green.(img), blue.(img)
end

function crop_to_square(image::Matrix)::Matrix
    # Calculate the size of the square
    height, width = size(image)
    crop_size = min(height, width)
    # Calculate the starting coordinates for the crop
    start_h = div(height - crop_size, 2) + 1
    start_w = div(width - crop_size, 2) + 1
    # Crop the image to a square shape
    cropped_img = zeros(RGB{N0f8}, crop_size, crop_size)
    cropped_img .=
        image[start_h:(start_h + crop_size - 1), start_w:(start_w + crop_size - 1)]
    return cropped_img
end

function run(input::Image, args::Dict = DefaultArgs)::Image
    @debug "Generating chords and pins positions"
    pins = gen_pins(args["pins"], args["size"])
    pin2chords = Dict(p => gen_chords(p, pins, args["size"]) for p in pins)

    @debug "Starting algorithm..."
    output = zeros(N0f8, args["size"], args["size"])
    pin = rand(pins)

    for step = 1:args["steps"]
        @debug "Step: $step"
        if step % INTERVAL == 0
            pin = rand(pins)
            args["gif"] && save_frame(output)
        end

        @debug "Generating chord images..."
        chords = pin2chords[pin]
        imgs = [gen_img(c, args) for c in chords] # memoize doest suport threads

        # if length(imgs) == 0
        #     break
        # end

        @debug "Calculating error in chords..."
        error, idx = select_best_chord(input, imgs)
        chord, img = chords[idx], imgs[idx]
        @debug "Error calculated" idx, error

        @debug "Updating images and position..."
        add_imgs!(input, img)
        add_imgs!(output, img)

        # old = pin
        pin = chord.first == pin ? chord.second : chord.first

        # excludes current chord from map
        # filter!(p -> p != chord, pin2chords[old])
        # filter!(p -> p != chord, pin2chords[pin])
    end
    output
end

function gen_pins(pins::Int, size::Int)::Vector{Point}
    center = (size / 2) + (size / 2) * 1im
    radius = 0.95 * (size / 2)
    # divide the circle into n_points
    interval = 360 / pins
    # calc polar coordinates
    phi = deg2rad.(0:interval:360)
    coords = radius .* exp.(phi .* 1im)
    # add center to coords and round the values
    round.(coords .+ center) |> unique
end

function gen_chords(p::Point, points::Vector{Point}, size::Int)::Vector{Chord}
    # exclude small chords
    valid_distance = (p, q) -> (abs(p - q) > size * 0.1)
    # line connecting a point  to all other neighbors / canvas pins
    [to_chord(p, q) for q in points if valid_distance(p, q)]
end

function to_chord(p::Point, q::Point)::Chord
    # pair should be order so it can be searched
    p, q = sort([p, q], by = x -> (real(x), imag(x)))
    return (p => q)
end

@memoize Dict function gen_img(chord::Chord, args::Dict = DefaultArgs)::Image
    # calculate the linear and angular coefficient of line (b-a)
    size, strength, blur = args["size"], args["line-strength"] / 100, args["blur"]

    # calculate line / chord points
    p, q = chord
    a, b = get_coefficients(p, q)

    x = LinRange(real(p), real(q), size)
    y = clamp.(a .* x .+ b, 1, size)

    # convert to the corresponding pixel position
    x = floor.(Int, x)
    y = floor.(Int, y)

    m = zeros(Gray{N0f8}, size, size)
    for i in eachindex(x)
        @inbounds m[x[i], y[i]] = strength
    end
    # gaussian filter to smooth the line
    imfilter(m, Kernel.gaussian(blur))
end

function get_coefficients(p::Point, q::Point)::Tuple{Float64,Float64}
    # calculate line (q-p) coefficient
    a = clamp(tan(angle(p - q)), -1000.0, 1000.0)
    b = (imag(p + q) - real(p + q) * a) / 2
    return (a, b)
end

function select_best_chord(img::Image, curves::Vector{Image})::Tuple{Float32,Int}
    # apply error function to all images and find the minium
    cimg = complement.(img)
    errors = Vector{Float32}(undef, length(curves))
    @threads for i in eachindex(curves)
        @inbounds errors[i] = Images.ssd(cimg, curves[i])
    end
    findmin(errors)
end

function add_imgs!(img::Image, curve::Image)::Image
    idx = [i for i in eachindex(curve) if curve[i] != 0]
    # add images clipping values outside the range 0<x<1 (not a valid color)
    @simd for i in idx
        @inbounds img[i] = clamp(float32(img[i]) + float32(curve[i]), 0.0, 1.0)
    end
    img
end

function save_frame(img::Image)
    global gif_count, gif_frames
    gif_frames[:, :, gif_count] .= complement.(img)
    gif_count += 1
end

function save_gif(output::String, color::Bool)
    global gif_count, gif_frames
    if color
        n = div(gif_count - 1, 3)
        sr, sg, sb = (1:n, (n + 1):(2 * n), (2 * n + 1):(3 * n))
        gif_frames = RGB.(gif_frames[:, :, sr], gif_frames[:, :, sg], gif_frames[:, :, sb])
    end
    save(output * ".gif", gif_frames, fps = 5)
end

end

StringArt.main()
