using Test
using Images
using Random
using Statistics: mean
include(joinpath(@__DIR__, "..", "src", "StringArt.jl"))
using .StringArt

const SZ = 64

# White canvas, black disk off-center: needs ink in one region only.
function disk(sz::Int)::Matrix{N0f8}
    img = ones(N0f8, sz, sz)
    c, r = sz * 0.4, sz * 0.25
    for x = 1:sz, y = 1:sz
        (x - c)^2 + (y - c)^2 < r^2 && (img[y, x] = 0)
    end
    img
end

mse(a, b) = mean((Float64.(Gray.(a)) .- Float64.(b)) .^ 2)

gray_cfg(; kw...) = StringArt.Config(; size=SZ, pins=32, steps=150, kw...)

@testset "StringArt" begin
    @testset "pinset" begin
        ps = StringArt.build_pinset(32, SZ)
        @test length(ps.pts) == 32
        @test all(1 <= real(p) <= SZ && 1 <= imag(p) <= SZ for p in ps.pts)
        # every chord pixel inside the canvas, weights positive
        @test all(all(1 .<= c.idx .<= SZ * SZ) && all(c.w .> 0) for c in values(ps.chords))
        # neighbor lists symmetric
        @test all(i in ps.nbrs[j] for i = 1:32 for j in ps.nbrs[i])
    end

    @testset "greedy reduces error" begin
        target = disk(SZ)
        Random.seed!(42)
        png, _, _ = StringArt.render([target], gray_cfg())
        @test size(png) == (SZ, SZ)
        blank = ones(N0f8, SZ, SZ)
        @test mse(png, target) < mse(blank, target)
        # ink lands on the disk more than off it
        ink = 1 .- Float64.(Gray.(png))
        on = target .== 0
        @test mean(ink[on]) > 2 * mean(ink[.!on])
    end

    @testset "deterministic under fixed seed" begin
        target = disk(SZ)
        Random.seed!(7)
        a, _, _ = StringArt.render([target], gray_cfg())
        Random.seed!(7)
        b, _, _ = StringArt.render([target], gray_cfg())
        @test a == b
    end

    @testset "exclude-repeated never repeats a chord" begin
        Random.seed!(42)
        ps = StringArt.build_pinset(32, SZ)
        # all-dark target + weak strength: without exclusion the greedy walk
        # re-picks the same chords hundreds of times in 300 steps
        dark = zeros(N0f8, SZ, SZ)
        picks, _ = StringArt.run_algorithm(dark, ps, gray_cfg(; steps=300, line_strength=5))
        @test !allunique(picks)
        Random.seed!(42)
        cfg = gray_cfg(; steps=300, line_strength=5, exclude_repeated_pins=true)
        picks, _ = StringArt.run_algorithm(dark, ps, cfg)
        @test length(picks) > 100
        @test allunique(picks)
    end

    @testset "formats" begin
        Random.seed!(42)
        cfg = gray_cfg(; formats=Set([:svg, :gif]))
        png, svg, gif = StringArt.render([disk(SZ)], cfg)
        @test occursin("<svg", svg) && occursin("</svg>", svg) && occursin("<line", svg)
        @test !isempty(gif) && size(first(gif)) == (SZ, SZ)
        _, svg2, gif2 = StringArt.render([disk(SZ)], gray_cfg())
        @test isempty(svg2) && isempty(gif2)
    end

    @testset "palette mode" begin
        Random.seed!(42)
        colors = [RGB{N0f8}(0, 0, 0), RGB{N0f8}(1, 0, 0)]
        cfg = gray_cfg(; mode=StringArt.PaletteMode, colors=colors, steps=50)
        png, _, _ = StringArt.render([disk(SZ), ones(N0f8, SZ, SZ)], cfg)
        @test size(png) == (SZ, SZ)
        @test eltype(png) == RGB{N0f8}
    end

    @testset "plot_pins marks pins at (row=y, col=x)" begin
        cfg = gray_cfg(; pins=3)  # sparse, asymmetric under transpose: no other pin box covers (y, x)
        out = StringArt.plot_pins(ones(N0f8, SZ, SZ), cfg)
        p = StringArt.gen_pins(cfg.pins, SZ)[2]  # x≈17, y≈58
        x, y = round(Int, real(p)), round(Int, imag(p))
        @test x != y
        @test out[y, x] == 0
    end
end
