module StringArt

using ArgParse
using Base
using Base.Threads
using Colors
using FileIO
using Images
using Logging
using Memoize
using Printf

const Point = ComplexF64
const Chord = Pair{Point,Point}
const Image = Matrix{N0f8}
const CImage = Matrix{RGB{N0f8}}
const Colors = Vector{RGB{N0f8}}

const INTERVAL = 20

const DefaultArgs = Dict{String,Any}

export GifWrapper
export load_color_image
export load_image
export run
export save_gif
export save_svg

# debug functions
export plot_pins
export plot_chords
export plot_color

mutable struct GifWrapper
    frames::Array{RGB{N0f8}}
    count::Int
end

""" Load and preprocess a grayscale image: crop to square and resize. """
function load_image(image_path::String, size::Int)::Vector{Image}
    # Read the image and convert it to an array
    @assert isfile(image_path) "Image file not found: $image_path"
    img = Images.load(image_path)
    # Resize the image to the specified dimensions
    img = crop_to_square(img)
    img = Images.imresize(img, size, size)
    # Convert the Image to gray scale and wrap in a vector
    [convert(Matrix{N0f8}, Gray{N0f8}.(img))]
end

""" Load and decompose color image into grayscale channels based on given RGB filters. """
function load_color_image(image_path::String, size::Int, colors::Colors)::Vector{Image}
    # Read the image and convert it to an array
    @assert isfile(image_path) "Image file not found: $image_path"
    img = Images.load(image_path)
    # Resize the image to the specified dimensions
    img = crop_to_square(img)
    img = Images.imresize(img, size, size)
    # Extract colors from Image and convert to gray scale
    extract_color(color) = Gray{N0f8}.(mapc.(*, img, color))
    map(extract_color, colors)
end


""" Crop rectangular image to a centered square. """
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
        image[start_h:(start_h+crop_size-1), start_w:(start_w+crop_size-1)]
    return cropped_img
end

""" Main function to generate string art image. Returns final image in png, svg and gif formats. """
function run(input::Vector{Image}, args::DefaultArgs)::Tuple{CImage,String,GifWrapper}
    # create struct that holds gif frames
    gif = gen_gif_wrapper(args)
    # initialize svg content
    svg = [svg_header(args)]
    # initialize output image
    png = zeros(RGB{N0f8}, args["size"], args["size"])
    for (color, img) in zip(args["colors"], input)
        # find chords to be draw
        chords = run_algorithm(img, args)
        # draw each chord
        for (n, chord) in enumerate(chords)
            # add chord to png image
            img = gen_img(chord, args) .* complement(color)
            add_imgs!(png, img)
            # draw svg shape
            if args["svg"]
                push!(svg, draw_line(chord, color, args))
            end
            # save gif frame
            if args["gif"] && n % INTERVAL == 0
                save_frame(complement.(png), gif)
            end
        end
    end
    push!(svg, "</svg>")
    return (complement.(png), join(svg, "\n"), gif)
end

""" Core string art generation loop. Produces ordered chords for image approximation. """
function run_algorithm(input::Image, args::Dict{String,Any})::Vector{Chord}
    @debug "Generating chords and pins positions"
    output = Vector{Chord}()
    pins = gen_pins(args["pins"], args["size"])
    pin2chords = Dict(p => gen_chords(p, pins, args["size"]) for p in pins)

    @debug "Starting algorithm..."
    pin = rand(pins)
    for step = 1:args["steps"]
        @debug "Step: $step"
        if step % INTERVAL == 0
            pin = rand(pins)
        end

        @debug "Generating chord images..."
        chords = pin2chords[pin]
        imgs = [gen_img(c, args) for c in chords]

        @debug "Calculating error in chords..."
        error, idx = select_best_chord(input, imgs)
        chord, img = chords[idx], imgs[idx]
        @debug "Error calculated" idx, error

        @debug "Updating images and position..."
        add_imgs!(input, img)
        push!(output, chord)

        # use the second point of the chord as the next pin
        pin = (chord.first == pin) ? chord.second : chord.first
    end
    output
end

""" Generate `n` evenly spaced points around a circle on a square canvas. """
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

""" Generate valid chords from a given point `p` to other canvas points. """
function gen_chords(p::Point, points::Vector{Point}, size::Int)::Vector{Chord}
    # exclude small chords
    valid_distance = (p, q) -> (abs(p - q) > size * 0.1)
    # line connecting a point  to all other neighbors / canvas pins
    [to_chord(p, q) for q in points if valid_distance(p, q)]
end

""" Create an ordered chord (pair of points). """
function to_chord(p::Point, q::Point)::Chord
    # pair should be order so it can be searched
    p, q = sort([p, q], by=x -> (real(x), imag(x)))
    return (p => q)
end

""" Generate grayscale image representing a line between two points. """
@memoize Dict function gen_img(chord::Chord, args::DefaultArgs)::Image
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
    idx = CartesianIndex.(x, y)
    m[idx] .= strength

    # gaussian filter to smooth the line
    imfilter(m, Kernel.gaussian(blur))
end

""" Get slope and intercept of the line between two points. """
function get_coefficients(p::Point, q::Point)::Tuple{Float64,Float64}
    # calculate line (q-p) coefficient
    a = clamp(tan(angle(p - q)), -1000.0, 1000.0)
    b = (imag(p + q) - real(p + q) * a) / 2
    return (a, b)
end

""" Find best chord that minimizes difference to target image. """
function select_best_chord(img::Image, curves::Vector{Image})::Tuple{Float32,Int}
    # apply error function to all images and find the minimum
    cimg = complement.(img)
    errors = Vector{Float32}(undef, length(curves))
    @threads for i in eachindex(curves)
        @inbounds errors[i] = Images.ssd(cimg, curves[i])
    end
    findmin(errors)
end

""" Add grayscale curve image to base image in-place, clipping to [0,1]. """
function add_imgs!(img::Image, curve::Image)::Image
    # add images clipping values outside the range 0<x<1 (not a valid color)
    idx = [i for i in eachindex(curve) if curve[i] != 0]
    # convert to float to prevent int (N0f8) overflow
    @simd for i in idx
        @inbounds img[i] = clamp01(float32(img[i]) + float32(curve[i]))
    end
    img
end

""" Add RGB images in-place, clipping to [0,1]. """
function add_imgs!(img::CImage, curve::CImage)::CImage
    # convert to float to prevent int (N0f8) overflow
    @inbounds for i in eachindex(img)
        c = curve[i]
        img[i] = RGB{N0f8}(
            clamp01(float32(img[i].r) + float32(c.r)),
            clamp01(float32(img[i].g) + float32(c.g)),
            clamp01(float32(img[i].b) + float32(c.b)),
        )
    end
    img
end

""" Add a frame to the gif sequence. """
function save_frame(img::CImage, gif::GifWrapper)
    gif.frames[:, :, gif.count] .= img
    gif.count += 1
end

""" Write gif frames to disk. """
function save_gif(output::String, gif::GifWrapper)
    gif_frames = gif.frames[:, :, 1:(gif.count-1)]
    save(output * ".gif", gif_frames, fps=5)
end

""" Initialize gif wrapper for given step count and color mode. """
function gen_gif_wrapper(args::Dict)::GifWrapper
    n_colors = length(args["colors"])
    n_frames = n_colors * div(args["steps"], INTERVAL)
    frames = Array{RGB{N0f8}}(undef, args["size"], args["size"], n_frames)
    GifWrapper(frames, 1)
end

function svg_header(args::DefaultArgs)::String
    size = args["size"]
    """<svg xmlns="http://www.w3.org/2000/svg" width="$size" height="$size" viewBox="0 0 $size $size">\n"""
end

function draw_line(chord::Chord, color::RGB{N0f8}, args::DefaultArgs)::String
    x1, x2 = imag(chord.first), imag(chord.second)
    y1, y2 = real(chord.first), real(chord.second)
    stroke = @sprintf("#%02X%02X%02X", round(Int, 255 * color.r), round(Int, 255 * color.g), round(Int, 255 * color.b))
    width = @sprintf("%.2f", args["line-strength"] / 120)
    """<line x1="$x1" x2="$x2" y1="$y1" y2="$y2" stroke="$stroke" stroke-width="$width"/>"""
end

function save_svg(output::String, svg::String)
    open(output * ".svg", "w") do f
        write(f, svg)
    end
end

### DEBUGGING UTILITIES

""" Visual debug: overlay pin locations on image. """
function plot_pins(input::Image, args::DefaultArgs)::Image
    LEN = 4

    @debug "Generating pins positions"
    pins = gen_pins(args["pins"], args["size"])

    @debug "Plotting pins positions"
    width, height = size(input)
    for pin in pins
        lbx, ubx = Int(max(real(pin) - LEN, 0)), Int(min(real(pin) + LEN, width))
        lby, uby = Int(max(imag(pin) - LEN, 0)), Int(min(imag(pin) + LEN, height))
        input[lbx:ubx, lby:uby] .= 0
    end

    @debug "Done"
    return input
end

""" Visual debug: draw all chords from the first pin. """
function plot_chords(input::Image, args::DefaultArgs)::Image
    @debug "Generating chords"
    pins = gen_pins(args["pins"], args["size"])
    chords = gen_chords(pins[1], pins, args["size"])

    @debug "Plotting chords"
    for chord in chords
        img = gen_img(chord, args)
        add_imgs!(input, img)
    end

    @debug "Done"
    return input
end

""" Visual debug: returns first grayscale channel. Stub for color support. """
function plot_color(input::Vector{Image}, args::Dict=DefaultArgs)::Image
    return input[1]
end

end
