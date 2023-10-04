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

function main()
    # parse command line arguments
    args = parse_cmd()

    # verbose mode should use debug log level log level
    if args["verbose"]
        ENV["JULIA_DEBUG"] = Main
    end

    global args

    pins, size, steps = args["pins"], args["size"], args["steps"]
    input, output = args["input"], args["output"]

    if args["gif"]
        frames = (args["color"]) ? 3 * div(steps, 20) : div(steps, 20)
        args["gif-frames"] = Array{N0f8}(undef, size, size, frames)
        args["gif-count"] = 1
    end

    if !args["color"]
        @info "Loading input image: '$input'"
        inp = load_image(input, size)

        @info "Running gray scale algorithm..." now()
        out = run(inp, pins, size, steps)

        @info "Saving final output image to: '$output'" now()
        out = Gray.(complement.(out))
        save(output * ".png", out)
    else
        @info "Loading input image: '$input'"
        rgb = load_rgb_image(input, size)

        @info "Running RGB algorithm..." now()
        rgb = [run(color, pins, size, steps) for color in rgb]

        @info "Saving final output image to: '$output'" now()
        out = complement.(RGB.(rgb...))
        save(output * ".png", out)
    end

    if args["gif"] & args["color"]
        frames, n = args["gif-frames"], div(args["gif-count"] - 1, 3)
        sr, sg, sb = (1:n, (n + 1):(2 * n), (2 * n + 1):(3 * n))
        frames = RGB.(frames[:, :, sr], frames[:, :, sg], frames[:, :, sb])
        save(output * ".gif", frames, fps = 5)
    elseif args["gif"]
        save(output * ".gif", args["gif-frames"], fps = 5)
    end
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
        "--gif"
        help = "Save output as a GIF"
        action = :store_true
        "--color"
        help = "RGB mode"
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

function crop_to_square(image::Matrix{RGB{N0f8}})::Matrix{RGB{N0f8}}
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

function run(input::Image, pins::Int, size::Int, steps::Int)::Image
    @debug "Generating chords and pins positions" now()
    pins = gen_pins(pins, size)
    pin2chords = Dict(p => gen_chords(p, pins, size) for p in pins)

    @debug "Starting algorithm..." now()
    output = zeros(N0f8, size, size)
    pin = rand(pins)

    for step = 1:steps
        if step % 20 == 0
            pin = rand(pins)
            log_step(step, output)
        end

        chords = pin2chords[pin]
        imgs = gen_img.(chords, size)

        # if length(imgs) == 0
        #     break
        # end

        @debug "Calculating error in chords..." now()
        error, idx = select_best_chord(input, imgs)
        chord, img = chords[idx], imgs[idx]
        @debug "Error calculated" now() idx, error

        @debug "Updating images and position..." now()
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

@memoize Dict function gen_img(chord::Chord, size::Int)::Image
    # calculate the linear and angular coefficient of line (b-a)

    # calculate line / chord points
    p, q = chord
    a, b = get_coefficients(p, q)

    x = LinRange(real(p), real(q), size)
    y = clamp.(a .* x .+ b, 1, size)

    # convert to the corresponding pixel position
    x = floor.(Int, x)
    y = floor.(Int, y)

    m = zeros(Gray{N0f8}, size, size)
    @inbounds @simd for i in eachindex(x)
        m[x[i], y[i]] = 0.25 # line_strength
    end
    # gaussian filter to smooth the line
    imfilter(m, Kernel.gaussian(1))
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
    errors = zeros(Float32, length(curves))
    @threads for i in eachindex(curves)
        errors[i] = Images.ssd(cimg, curves[i])
    end
    findmin(errors)
end

function add_imgs!(img::Image, curve::Image)::Image
    idx = [i for i in eachindex(curve) if curve[i] != 0]
    # add images clipping values outside the range 0<x<1 (not a valid color)
    @inbounds @simd for i in idx
        img[i] = clamp(float32(img[i]) + float32(curve[i]), 0.0, 1.0)
    end
    img
end

function log_step(step::Int, out::Image)
    dt = Dates.format(now(), "HH:MM:SS")
    @info "$dt | Step: $step"
    if isdefined(Main.StringArt, :args) & args["gif"]
        img = complement.(out)
        args["gif-frames"][:, :, args["gif-count"]] .= img
        args["gif-count"] += 1
    end
end

end

StringArt.main()
