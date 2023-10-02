## StringArt.jl

![David by Michelangelo](examples/david.png)

This script implements a simplified version of the [String Art](https://en.wikipedia.org/wiki/String_art) greedy algorithm. Given an image, it attempts to create a similar representation using a single thread wound around a circle of nails, effectively constructing an image using only lines. This technique is probably most well-know for the artistic works of [Petros Vrllis](https://www.saatchiart.com/vrellis).

Most implementations often require high-contrast images, and still the results can vary significantly from one image to another. In this version, I've tweaked the algorithm parameters to enhance the contrast and detail in the final output. While this adjustment impacts performance, it remains usable.

Additionally, the script features a command-line interface (CLI) with various parameters and option flags and a _RGB color mode_. Feel free to explore these options to customize the output according to your preferences.

### Algorithm

1. Setup:

- Load the source image and create an empty output image.
- Calculate pin positions and all possible lines between 2 pins.
- Compute all possible line images.

2. Iteration Step:

- Choose a pin (P).
- Load all possible lines connecting P to the other pins in the circle.
- Calculate the error between each of the lines and the source image.
- Find the line (L) that gives the minimum error.
- Update the output image (add L) and the source image (subtract L).
- Set the pin to be the other pin of L.

_Line Generating Function:_
One-pixel-width lines (or any square/stair-like lines) do not yield good results. Experimentation with different line functions is essential here. I ended up choosing to apply the Gaussian Blur Kernel to the line. It's simple, and it works (also, it eliminates the need to fine-tune other parameters).

_Line Pixel Strength:_
Opt for low line pixel values to create nuanced shades of grey in the output image.

_Choose Pin:_
Randomizing the pin position periodically (every N steps) tends to give better results.

_Error Function:_
Arguably the most critical part of the algorithm. You should minimize the error here and not any other metric (I lost a lot of time doing that...). The best function that I found was the squared difference between the source image and the line (but the performance takes a considerable hit here).

_Excluding Already Visited Lines:_
While excluding used lines each iteration improves performance, it results in a more diffuse and noisy image. In this implementation, visited lines are retained. If you prefer the noisy style, just uncomment the lines with filter!.

### Requirements

The Libraries:

- ArgParse
- Combinatorics
- Images
- Logging

### Usage

```bash
$ julia -O3 -t 8 main.jl -i [input image] -o [output image]

# alter the image resolution
$ julia -O3 -t 8 main.jl -s 800 -i [input image] -o [output image]

# RGB color mode
$ julia -O3 -t 8 main.jl --color -i [input image] -o [output image]

# Saves output image for each iteration
$ julia -O3 -t 8 main.jl --verbose -i [input image] -o [output image]
```

### Parameters

```bash
usage: main.jl -i INPUT [-o OUTPUT] [-s SIZE] [-n PINS]
               [--steps STEPS] [--line-strength LINE-STRENGTH]
               [--color] [--verbose] [-h]

optional arguments:
  -i, --input INPUT     input image path
  -o, --output OUTPUT   output image path whiteout extension (default: "output")
  -s, --size SIZE       output image size in pixels (type: Int64, default: 512)
  -n, --pins PINS       number of pins to use in canvas (type: Int64, default: 180)
  --steps STEPS         number of algorithm iterations (type: Int64, default: 1000)
  --line-strength LINE-STRENGTH
                        pixel value for line for a point in one line
                        (type: Float64, default: 0.25)
  --color               RGB mode
  --verbose             verbose mode
  -h, --help            show this help message and exit
```

> keep the number of pins bellow 250 and the image size bellow 1000.

### Gallery

### TODO

- [ ] GIF mode
- [ ] take a list of files as inputs
- [ ] Optimize (or cache) setup
- [ ] Eliminate graphical bug (dot line at the center)
- [ ] more memory efficient implementation (use sparse matrix or just don't pre-compute chords)
- [ ] version for the GPU
