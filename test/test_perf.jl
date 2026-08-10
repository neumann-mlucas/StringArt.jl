module TestPerf

using Test
using TOML

const HERE = @__DIR__
const BASELINE_TOML = joinpath(HERE, "baseline.toml")
const PHASE = get(ENV, "PHASE", "pre-p1")
const WALL_MAX = 1.15   # noise floor: single-measurement wall_clock incl. JIT.
# SPEC target is 1.00; upgrade harness to warmup+median before tightening.
# ponytail: single-shot timing, add repeated-run median if flakes bite.
const ALLOC_MAX = 1.20

const PHASE_ORDER = [
    "pre-p1",
    "c1-tuple",
    "p1-sparse",
    "p2-wu",
    "p4-residual",
    "p6-dedup",
    "d3-overdraw",
    "d4-palette",
    "p5-parallel",
    "d1-dark",
    "d5-adaptive",
    "d2-beam",
]

function prior_phase(current, data)
    idx = findfirst(==(current), PHASE_ORDER)
    idx === nothing && return nothing
    for j = (idx-1):-1:1
        haskey(data, PHASE_ORDER[j]) && return PHASE_ORDER[j]
    end
    return nothing
end

function check()
    data = TOML.parsefile(BASELINE_TOML)
    prev = prior_phase(PHASE, data)
    prev === nothing && (@info "no prior phase, perf gate skipped"; return)

    @testset "perf $PHASE vs $prev" begin
        for (key, cur) in data[PHASE]
            haskey(data[prev], key) || continue
            base = data[prev][key]
            @test cur["wall_clock_s"] <= WALL_MAX * base["wall_clock_s"]
            @test cur["alloc_bytes_100steps"] <= ALLOC_MAX * base["alloc_bytes_100steps"]
        end
    end
end

check()

end # module
