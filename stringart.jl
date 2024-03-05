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

const DefaultArgs = Dict{String,Any}

export gen_gif_wrapper
export GifWrapper

export load_image
export load_rgb_image
export run
export save_gif

# debug functions
export plot_pins
export plot_chords

mutable struct GifWrapper
    frames:: Array{N0f8}
    count:: Int
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

function run(input::Image, gif::GifWrapper, args::Dict = DefaultArgs)::Image
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
            args["gif"] && save_frame(output, gif)
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

function save_frame(img::Image, gif:: GifWrapper)
    gif.frames[:, :, gif.count] .= complement.(img)
    gif.count += 1
end

function save_gif(output::String, color::Bool, gif::GifWrapper)
    if color
        n = div(gif.count - 1, 3)
        sr, sg, sb = (1:n, (n + 1):(2 * n), (2 * n + 1):(3 * n))
        gif_frames = RGB.(gif.frames[:, :, sr], gif.frames[:, :, sg], gif.frames[:, :, sb])
    end
    save(output * ".gif", gif_frames, fps = 5)
end

function gen_gif_wrapper(args::Dict)::GifWrapper
    n_frames = 1
    if args["gif"]
        n_frames = ((args["color"]) ? 3 : 1) * div(args["steps"], INTERVAL)
    end

    frames = Array{N0f8}(undef, args["size"], args["size"], n_frames)
    GifWrapper(frames, 1)
end

function plot_pins(input::Image, args::Dict = DefaultArgs)::Image
    LEN = 4

    @debug "Generating pins positions"
    pins = gen_pins(args["pins"], args["size"])

    @debug "Ploting pins positions"
    width, height = size(input)
    for pin in pins
        lbx, ubx = Int(max(real(pin)-LEN,0)), Int(min(real(pin)+LEN,width))
        lby, uby = Int(max(imag(pin)-LEN,0)), Int(min(imag(pin)+LEN,height))
        input[lbx:ubx,lby:uby] .= 0
    end

    @debug "Done"
    return input
end

function plot_chords(input::Image, args::Dict = DefaultArgs)::Image
    @debug "Generating chords"
    pins = gen_pins(args["pins"], args["size"])
    chords = gen_chords(pins[1], pins, args["size"])

    @debug "Ploting chords"
    for chord in chords 
        img = gen_img(chord, args)
        add_imgs!(input, img)
    end

    @debug "Done"
    return input
end

end
