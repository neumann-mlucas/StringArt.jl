module TestVisualDiff

using FileIO
using Images

const HERE = @__DIR__
const PHASE = get(ENV, "PHASE", "pre-p1")
const ARTIFACT_DIR = joinpath(HERE, "artifacts", PHASE)
const FIXTURES_DIR = joinpath(HERE, "fixtures")

function crop_square(img)
    height, width = size(img)
    crop = min(height, width)
    h0 = div(height - crop, 2) + 1
    w0 = div(width - crop, 2) + 1
    return img[h0:(h0+crop-1), w0:(w0+crop-1)]
end

function match_geometry(target, sz)
    return Images.imresize(crop_square(target), sz, sz)
end

function stretch(a::Matrix)
    lo, hi = extrema(a)
    hi == lo && return zeros(eltype(a), size(a))
    return (a .- lo) ./ (hi - lo)
end

# Map fixture name (kebab from test_baseline) -> actual filename in fixtures/.
function fixture_lookup()
    lookup = Dict{String,String}()
    for f in readdir(FIXTURES_DIR)
        stem = replace(splitext(f)[1], "_" => "-")
        lookup[stem] = joinpath(FIXTURES_DIR, f)
    end
    return lookup
end

function write_diffs()
    isdir(ARTIFACT_DIR) || (@warn "no artifacts dir $ARTIFACT_DIR"; return)
    lookup = fixture_lookup()
    for f in readdir(ARTIFACT_DIR)
        endswith(f, "_output.png") || continue
        stem = replace(f, "_output.png" => "")
        fixture = split(stem, "__")[1]
        haskey(lookup, fixture) || (@warn "no source for $fixture"; continue)

        out_path = joinpath(ARTIFACT_DIR, f)
        got = Images.load(out_path)
        target = match_geometry(Images.load(lookup[fixture]), size(got, 1))

        Images.save(joinpath(ARTIFACT_DIR, "$(stem)_target.png"), target)
        diff = Gray.(stretch(abs.(Float32.(Gray.(target)) .- Float32.(Gray.(got)))))
        Images.save(joinpath(ARTIFACT_DIR, "$(stem)_diff.png"), diff)
    end
end

write_diffs()

end # module
