using Random
Random.seed!(42)

# Order: baseline runs the algorithm and writes metrics + artifacts.
# The others read from what baseline produced.
include("test_baseline.jl")
include("test_correctness.jl")
include("test_perf.jl")
include("test_visual_diff.jl")
