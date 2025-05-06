module StringArt

using Base.Threads: @threads, nthreads
using FileIO
using Images
using Logging
using Memoize
using Printf
using Random

const Point = ComplexF64
const Chord = Pair{Point,Point}
const GrayImage = Matrix{N0f8}
const RGBImage = Matrix{RGB{N0f8}}
const Colors = Vector{RGB{N0f8}}
const DefaultArgs = Dict{String,Any}

const GIF_INTERVAL = 10
const RANDOMIZED_PIN_INTERVAL = 20
const SMALL_CHORD_CUTOFF = 0.10
const EXCLUDE_REPEATED_PINS = false

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
function load_image(image_path::String, size::Int)::Vector{GrayImage}
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
function load_color_image(image_path::String, size::Int, colors::Colors)::Vector{GrayImage}
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
    @views image[start_h:(start_h+crop_size-1), start_w:(start_w+crop_size-1)]
end

""" Main function to generate string art image. Returns final image in png, svg and gif formats. """
function run(input::Vector{GrayImage}, args::DefaultArgs)::Tuple{RGBImage,String,GifWrapper}
    # generate all chords to be draw in the canvas
    chords = Tuple[]
    for (color, img) in zip(args["colors"], input)
        save(hex(color) * "_b.png", img)
        for chord in run_algorithm(img, args)
            push!(chords, (chord, color))
        end
        save(hex(color) * "_a.png", img)
    end
    shuffle!(chords)

    # initialize output image
    png = zeros(RGB{N0f8}, args["size"], args["size"])
    # create struct that holds gif frames
    gif = gen_gif_wrapper(args)
    # initialize svg content
    svg = [svg_header(args)]

    for (n, (chord, color)) in enumerate(chords)
        # add chord to png image
        img = gen_img(chord, args) .* complement(color)
        add_imgs!(png, img)
        # draw svg shape
        if args["svg"]
            push!(svg, draw_line(chord, color, args))
        end
        # save gif frame
        if args["gif"] && n % GIF_INTERVAL == 0
            save_frame(complement.(png), gif)
        end
    end
    push!(svg, "</svg>")
    return (complement.(png), join(svg, "\n"), gif)
end

""" Core string art generation loop. Produces ordered chords for image approximation. """
function run_algorithm(input::GrayImage, args::DefaultArgs)::Vector{Chord}
    @debug "Generating chords and pins positions"
    output = Vector{Chord}()

    pins = gen_pins(args["pins"], args["size"])
    pin2chords = Dict(p => gen_chords(p, pins, args["size"]) for p in pins)

    @debug "Starting algorithm..."
    pin = rand(pins)
    for step = 1:args["steps"]
        @debug "Step: $step"
        if step % RANDOMIZED_PIN_INTERVAL == 0
            pin = rand(pins)
        end

        @debug "Generating chord images..."
        chords = pin2chords[pin]
        imgs = [gen_img(c, args) for c in chords]

        if EXCLUDE_REPEATED_PINS && length(imgs) == 0
            @debug "No chords left, breaking..."
            break
        end

        @debug "Calculating error in chords..."
        error, idx = select_best_chord(input, imgs)
        chord, img = chords[idx], imgs[idx]
        @debug "Error calculated" idx, error

        @debug "Updating images and position..."
        add_imgs!(input, img)
        push!(output, chord)

        # don't draw the same chord again
        EXCLUDE_REPEATED_PINS && filter!(c -> c != chord, pin2chords[pin])
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
    threshold = size * SMALL_CHORD_CUTOFF
    # line connecting a point to all other neighbors / canvas pins
    [to_chord(p, q) for q in points if abs(p - q) > threshold]
end

""" Create an ordered chord (pair of points). """
function to_chord(p::Point, q::Point)::Chord
    # pair should be order so it can be searched
    p, q = sort([p, q], by=x -> (real(x), imag(x)))
    return Pair(p, q)
end

""" Generate grayscale image representing a line between two points. """
@memoize Dict function gen_img(chord::Chord, args::DefaultArgs)::GrayImage
    # calculate the linear and angular coefficient of line (b-a)
    size, strength, blur = args["size"], args["line-strength"] / 100, args["blur"]

    # calculate line / chord points
    p, q = chord
    a, b = get_coefficients(p, q)

    x = LinRange(real(p), real(q), size)
    y = clamp.(a .* x .+ b, 1, size)

    # convert to the corresponding pixel position
    x = round.(Int, x)
    y = round.(Int, y)

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
function select_best_chord(img::GrayImage, curves::Vector{GrayImage})::Tuple{Float32,Int}
    chunks = [i:min(i + div(length(curves), nthreads()) - 1, length(curves)) for i in 1:div(length(curves), nthreads()):length(curves)]

    cimg = complement.(img)
    errors = fill(Inf32, length(curves))
    # Use batch processing for better cache efficiency
    @threads for t in eachindex(chunks)
        for i in chunks[t]
            @inbounds errors[i] = Images.ssd(cimg, curves[i])
        end
    end
    findmin(errors)
end

""" Add grayscale curve image to base image in-place, clipping to [0,1]. """
function add_imgs!(img::GrayImage, curve::GrayImage)::GrayImage
    # add images clipping values outside the range 0<x<1 (not a valid color)
    @inbounds for i in eachindex(curve)
        if curve[i] != 0
            img[i] = clamp01(float32(img[i]) + float32(curve[i]))
        end
    end
    img
end

""" Add RGB images in-place, clipping to [0,1]. """
function add_imgs!(img::RGBImage, curve::RGBImage)::RGBImage
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
function save_frame(img::RGBImage, gif::GifWrapper)
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
    if !args["gif"]
        return GifWrapper(Array{RGB{N0f8}}(undef, 0, 0, 0), 0)
    end
    n_colors = length(args["colors"])
    n_frames = n_colors * div(args["steps"], GIF_INTERVAL)
    frames = Array{RGB{N0f8}}(undef, args["size"], args["size"], n_frames)
    GifWrapper(frames, 1)
end

""" Generate SVG header with specified size. """
function svg_header(args::DefaultArgs)::String
    size = args["size"]
    blur = args["blur"]
    """<svg xmlns="http://www.w3.org/2000/svg" width="$size" height="$size" viewBox="0 0 $size $size">
    <filter id="blur">
        <feGaussianBlur stdDeviation="$blur" />
    </filter>"""
end

""" Draw a line in SVG format. """
function draw_line(chord::Chord, color::RGB{N0f8}, args::DefaultArgs)::String
    x1, x2 = imag(chord.first), imag(chord.second)
    y1, y2 = real(chord.first), real(chord.second)
    width = @sprintf("%.2f", args["line-strength"] / 100)
    """<line x1="$x1" x2="$x2" y1="$y1" y2="$y2" stroke="#$(hex(color))" stroke-width="$width" filter="url(#blur)"/>"""
end

""" Write svg to disk. """
function save_svg(output::String, svg::String)
    open(output * ".svg", "w") do f
        write(f, svg)
    end
end

### DEBUGGING UTILITIES

""" Visual debug: overlay pin locations on image. """
function plot_pins(input::GrayImage, args::DefaultArgs)::GrayImage
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
function plot_chords(input::GrayImage, args::DefaultArgs)::GrayImage
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
function plot_color(input::Vector{GrayImage}, args::DefaultArgs)::GrayImage
    return input[1]
end

end
