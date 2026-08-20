# Dev tasks. Requires: just, julia. Optional: shellcheck.
# Dev tools (JuliaFormatter, JET) isolated in ./dev/ to keep runtime deps clean.

SIBLING := "../MonteCarloArt.jl"

default:
    @just --list

# One-time: install runtime + dev tool deps.
install:
    julia --project=. -e 'using Pkg; Pkg.instantiate()'
    julia --project=./dev -e 'using Pkg; Pkg.instantiate()'

# Run tests.
test:
    julia --project=. --startup-file=no test/runtests.jl

# Format all julia sources in-place.
fmt:
    julia --project=./dev -e 'using JuliaFormatter; format(".")'

# Static analysis on the main module. LOAD_PATH picks up JET (dev) + module (main).
lint:
    JULIA_LOAD_PATH=".:./dev:@stdlib" julia --startup-file=no -e 'using JET, StringArt; report_package(StringArt)'

# Shell-script lint. Requires shellcheck binary.
shellcheck:
    @command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed — apt install shellcheck / pacman -S shellcheck"; exit 1; }
    shellcheck test/scripts/*.sh

# Verify vendored files match sibling project. Fails on any drift.
check-sync:
    @[ -d "{{SIBLING}}" ] || { echo "sibling not found: {{SIBLING}}"; exit 1; }
    diff -q src/common.jl {{SIBLING}}/src/common.jl
    diff -q test/scripts/lib.sh {{SIBLING}}/test/scripts/lib.sh
    @echo "vendored files in sync with {{SIBLING}}"

# CI checks.
check: lint test shellcheck check-sync

# Purge generated + resolved state.
clean:
    rm -f Manifest.toml dev/Manifest.toml
    rm -rf test/results test/artifacts
