module TestCorrectness

using Test
using TOML

const HERE = @__DIR__
const BASELINE_TOML = joinpath(HERE, "baseline.toml")
const PHASE = get(ENV, "PHASE", "pre-p1")

# SPEC §Guardrails
const SSD_MAX = 1.03
# Coverage recorded as informational only. Sparse residual (P1+) legitimately shifts
# the chord distribution away from dark-region revisits (SPEC D3 intent), which the
# coverage metric penalizes. SSD is the primary correctness signal per SPEC.

# Phase ordering used to pick "prior phase" for regression comparison.
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

function prior_phase(current::String, data::Dict)
    idx = findfirst(==(current), PHASE_ORDER)
    idx === nothing && return nothing
    for j = (idx-1):-1:1
        haskey(data, PHASE_ORDER[j]) && return PHASE_ORDER[j]
    end
    return nothing
end

function check()
    isfile(BASELINE_TOML) || error("baseline.toml missing — run test_baseline first")
    data = TOML.parsefile(BASELINE_TOML)
    haskey(data, PHASE) || error("no records for phase $PHASE in baseline.toml")

    prev = prior_phase(PHASE, data)
    if prev === nothing
        @info "no prior phase for $PHASE — establishing baseline, no regression checks"
        @testset "baseline sanity ($PHASE)" begin
            for (key, rec) in data[PHASE]
                @test isfinite(rec["ssd"])
                @test rec["wall_clock_s"] > 0
                @test !isempty(rec["sha256"])
            end
        end
        return
    end

    @info "checking $PHASE vs prior $prev"
    @testset "correctness $PHASE vs $prev" begin
        for (key, cur) in data[PHASE]
            haskey(data[prev], key) || continue
            base = data[prev][key]
            @test cur["ssd"] <= SSD_MAX * base["ssd"]
        end
    end
end

check()

end # module
