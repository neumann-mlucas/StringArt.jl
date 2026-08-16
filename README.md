## StringArt.jl

<p align="center">
  <img src="examples/david_01.png" alt="David by Michelangelo" width="300px" />
</p>

This script implements a simplified version of the [String Art](https://en.wikipedia.org/wiki/String_art) greedy algorithm. Given an image, it attempts to create a similar representation using a single thread wound around a circle of nails, effectively constructing an image using only lines. This technique is probably most well-know for the artistic works of [Petros Vrllis](https://www.saatchiart.com/vrellis).

Most implementations often require high-contrast images, and still the results can vary significantly from one image to another. In this version, I've tweaked the algorithm parameters to **enhance the contrast and detail in the final output**. While this adjustment impacts performance, it remains usable.

Additionally, the script features a command-line interface (CLI) with various tweakable parameters, option flags, **RGB color mode** and you can also save the **GIF animation** with easy. Feel free to explore these options to customize the output according to your preferences, if you want to reuse the code or call it somewhere else, you should look at `StringArt.run`.

**Useful Resources:**

- [The Mathematics of String Art Video](https://www.youtube.com/watch?v=WGccIFf6MF8)

### Algorithm

1. **Setup:**

- Load the source image and create an empty output image.
- Calculate pin positions and all possible lines between 2 pins.

2. **Iteration Step:**

- Choose a pin (P).
- Create all possible lines connecting P to the other pins in the circle.
- Calculate the error between each lines and the source image.
- Find the line (L) that gives the minimum error.
- Update the output image adding L, and the source image subtracting L.
- Set the pin to be opposite point in the line L.

**Line Generating Function:**
Each chord is rasterized once with Xiaolin Wu antialiasing into a sparse `(idx, w)` pair — column-major pixel indices and subpixel coverage weights — cached by chord key.

**Line Pixel Strength:**
Opt for low line pixel values to create nuanced shades of gray in the output image.

**Choose Pin:**
Randomizing the pin position periodically (every N steps) tends to give better results.

**Error Function:**
The greedy pick scores candidates against a persistent `residual::Vector{Float32}` (initial `complement(target)` flattened). Score is a sparse dot product `-Σ w[k] · residual[idx[k]]` over the ~N pixels the chord touches — no full N² pass per candidate. `apply!` subtracts the weights from the residual in place.

**Excluding Already Visited Lines:**
While excluding used lines each iteration improves performance, it results in a more diffuse and noisy image. Off by default. Pass `--exclude-repeated-pins` to enable.

### Requirements

The Libraries:

- ArgParse
- Clustering
- FileIO
- **Images**
- Logging
- **LRUCache**
- Random (stdlib)
- Statistics (stdlib)

### Usage

Output format is inferred from the `-o` file extension (`.png`, `.svg`, `.gif`). Comma-separate multiple paths to emit several formats in one run.

```bash
# basic
$ julia -O3 -t 8 main.jl -i input.jpg -o output.png

# suggested
$ julia -O3 -t 8 main.jl -s 720 --steps 2000 -i input.jpg -o output.png

# alter the image resolution
$ julia -O3 -t 8 main.jl -s 800 -i input.jpg -o output.png

# RGB color mode
$ julia -O3 -t 8 main.jl --rgb -i input.jpg -o output.png

# RGB color mode with custom colors
$ julia -O3 -t 8 main.jl --custom-colors "#FFFF33,#33FFFF" -i input.jpg -o output.png

# RGB color using color palette (n = 4) extracted from the input image
$ julia -O3 -t 8 main.jl --palette 4 -i input.jpg -o output.png

# GIF output (extension picks the format)
$ julia -O3 -t 8 main.jl -i input.jpg -o output.gif

# SVG output
$ julia -O3 -t 8 main.jl -i input.jpg -o output.svg

# PNG + SVG + GIF in a single run
$ julia -O3 -t 8 main.jl -i input.jpg -o output.png,output.svg,output.gif
```

### Debugging Utilities

```bash
# plot pins used in the image
$ julia utils.jl -f plot_pins -i input.jpg -o pins.png

# plot color channel for a given color and input image
$ julia utils.jl -f plot_color --colors "#FF0000" -i input.jpg -o color.png
```

### Parameters

```bash
usage: main.jl -i INPUT [-o OUTPUT] [-s SIZE] [--steps STEPS] [-v]
               [-n PINS] [--line-strength LINE-STRENGTH] [--rgb]
               [--custom-colors CUSTOM-COLORS] [--palette PALETTE]
               [--exclude-repeated-pins] [-h]

StringArt - Convert images to string art

optional arguments:
  -i, --input INPUT     input image path
  -o, --output OUTPUT   output path with extension (.png/.svg/.gif);
                        comma-separate for multiple (default:
                        "output.png")
  -s, --size SIZE       output canvas size in pixels (type: Int64,
                        default: 512)
  --steps STEPS         algorithm iteration count (type: Int64,
                        default: 1000)
  -v, --verbose         verbose (debug) logging
  -n, --pins PINS       number of pins to use in canvas (type: Int64,
                        default: 180)
  --line-strength LINE-STRENGTH
                        line intensity ranging from 1-100 (type:
                        Int64, default: 25)
  --rgb                 use basic RGB color mode (default: red, green,
                        blue)
  --custom-colors CUSTOM-COLORS
                        comma-separated HEX color codes for custom
                        color strands (e.g. #FF0000,#00FF00)
  --palette PALETTE     number of colors to extract as a palette from
                        the input image (k-means clustering) (type:
                        Int64)
  --exclude-repeated-pins
                        skip chords already drawn (yields noisier /
                        more diffuse output)
  -h, --help            show this help message and exit

Example: julia main.jl -i input.jpg -o output.png
```

> keep the number of pins below 250 and the image size below 1000.

> the number of iteration steps is dependent on the image size. For size between 500 and 800, 2000 iteration is more than enough.

### Gallery

<p align="center">
  <img src="examples/david_02.png" alt="David by Michelangelo" width="400px" />
</p>

<p align="center">
  <img src="examples/einstein.png" alt="Albert Einstein" width="400px" />
</p>

<p align="center">
  <img src="examples/eye.png" alt="Eye" width="400px" />
</p>

#### RGB Mode

<p align="center">
  <img src="examples/venus.png" alt="Birth of Venus" width="400px" />
</p>

<p align="center">
  <img src="examples/lady.png" alt="Lady with an Ermine" width="400px" />
</p>

<p align="center">
  <img src="examples/lucifer.png" alt="The Fallen Angel" width="400px" />
</p>

#### Animation

<p align="center">
  <img src="examples/david.gif" alt="David Gif" width="400px" />
</p>

---

### TODO

- [x] Write output image as GIF
- [x] Write output image as SVG
- [x] Optimize memory usage
- [x] Support GIF in `--rgb` mode
- [x] Use user provided colors (`--custom-colors` flag) to create the output image
- [x] Use color palette (`--palette` flag) from input image to create the output image
- [ ] Enhance Image Contrast (needed?)
- [ ] Port Code to the GPU
