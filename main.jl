using ArgParse
using Base
using Base.Threads
using Dates
using Images
using Logging

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

    if !args["color"]
        @info "Loading input image..." args["input"]
        inp = load_image(args["input"])

        @info "Running gray scale algorithm..." now()
        out = run(inp)

        @info "Saving final output image to:" args["output"] now()
        out = Gray.(complement.(out))
        save(args["output"] * ".png", out)
    else
        @info "Loading input image..." args["input"]
        rgb = load_rgb_image(args["input"])

        @info "Running RGB algorithm..." now()
        rgb = [run(color) for color in rgb]

        @info "Saving final output image to:" args["output"] now()
        out = complement.(RGB.(rgb...))
        save(args["output"] * ".png", out)
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
        "--line-strength"
        help = "pixel value for line for a point in one line"
        arg_type = Float64
        default = 0.25
        "--color"
        help = "RGB mode"
        action = :store_true
        "--verbose"
        help = "verbose mode"
        action = :store_true
    end
    parse_args(parser)
end

function load_image(image_path::String)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Resize the image to the specified dimensions
    img = crop_to_square(img)
    img = Images.imresize(img, args["size"], args["size"])
    # Convert the Image to gray scale
    N0f8.(Gray.(img))
end

function load_rgb_image(image_path::String)::Tuple{Image,Image,Image}
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Resize the image to the specified dimensions
    img = crop_to_square(img)
    img = Images.imresize(img, args["size"], args["size"])
    # Convert the Image to gray scale
    red.(img), green.(img), blue.(img)
end

function crop_to_square(image::Matrix)::Matrix{RGB{N0f8}}
    # Calculate the size of the square
    height, width = size(image)
    crop_size = min(height, width)
    # Calculate the starting coordinates for the crop
    start_h = div(height - crop_size, 2) + 1
    start_w = div(width - crop_size, 2) + 1
    # Crop the image to a square shape
    cropped_img = zeros(RGB{N0f8}, crop_size, crop_size)
    cropped_img .= image[start_h:start_h+crop_size-1, start_w:start_w+crop_size-1]
    return cropped_img
end

function run(input::Image)
    PINS, SIZE = args["pins"], args["size"]
    STEPS = args["steps"]

    @debug "Generating chords and pins positions" now()
    pins = gen_pins(PINS, SIZE)
    pin2chords = Dict(p => gen_chords(p, pins) for p in pins)

    @debug "Generating chord images..." now()
    allchords = gen_all_chords(pins)
    chord2img = Dict(c => gen_img(c) for c in allchords)
    @debug "All chords generated" now() length(allchords)

    @debug "Starting algorithm..." now()
    output = zeros(N0f8, SIZE, SIZE)
    pin = rand(pins)

    for step = 1:STEPS
        if step % 20 == 0
            pin = rand(pins)
            log_step(step, output)
        end

        chords = pin2chords[pin]
        imgs = [chord2img[ch] for ch in chords]

        if length(imgs) == 0
            break
        end

        @debug "Calculating error in chords..." now()
        error, idx = select_best_chord(input, imgs)
        chord, img = chords[idx], imgs[idx]
        @debug "Error calculated" now() idx, error

        @debug "Updating images and position..." now()
        input = add_imgs(input, img)
        output = add_imgs(output, img)

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

function gen_chords(p::Point, points::Vector{Point})::Vector{Chord}
    # line connecting a point  to all other neighbors / canvas pins
    [to_chord(p, q) for q in points if valid_distance(p, q)]
end

function gen_all_chords(points::Vector{Point})::Vector{Chord}
    # generate all possible chords (combinations of two points in the circle)
    [to_chord(p, q) for (p, q) in combinations(points, 2) if valid_distance(p, q)]
end

function valid_distance(p::Point, q::Point)::Bool
    # exclude small chords
    abs(p - q) > args["size"] * 0.1
end

function to_chord(p::Point, q::Point)::Chord
    # pair should be order so it can be searched
    p, q = sort([p, q], by = x -> (real(x), imag(x)))
    return (p => q)
end

function gen_img(chord::Chord)::Image
    # calculate the linear and angular coefficient of line (b-a)
    size = args["size"]
    line_strength = args["line-strength"]

    # calculate line / chord points
    p, q = chord
    a, b = get_coefficients(p, q)

    x = LinRange(real(p), real(q), size)
    y = clamp.(a .* x .+ b, 1, size)

    # convert to the corresponding pixel position
    x = floor.(Int, x)
    y = floor.(Int, y)

    m = zeros(Gray{N0f8}, size, size)
    for (xi, yi) in zip(x, y)
        m[xi, yi] = line_strength
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

function select_best_chord(img::Image, curves::Vector{Image})::Tuple{Float64,Int}
    # apply error function to all images
    cimg = float64.(complement.(img))
    errorfunc = c -> sum(abs2.(cimg .- float64.(c)))
    # most computational intensive part
    errors = zeros(Float64, length(curves))
    @threads for i in 1:length(curves)
        @inbounds errors[i] = errorfunc(curves[i])
    end
    findmin(errors)
end

function add_imgs(img::Image, curve::Image)::Image
    # add images clipping values outside the range 0<x<1 (not a valid color)
    m = float64.(img) .+ float64.(curve)
    @. Gray{N0f8}(clamp(m, 0.0, 1.0))
end

function log_step(step::Int, out::Image)
    dt = Dates.format(now(), "HH:MM:SS")
    @info "$dt | Step: $step"
    if args["verbose"]
        filename = args["output"] * "_" * lpad("$step", 4, '0') * ".png"
        save(filename, complement.(out))
    end
end

main()
