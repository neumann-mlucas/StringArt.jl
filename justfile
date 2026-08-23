# Dev tasks. Requires: just, julia. Optional: shellcheck.
# Dev tools (JuliaFormatter, JET) isolated in ./dev/ to keep runtime deps clean.

SIBLING := "../MonteCarloArt.jl"

default:
    @just --list

# One-time: install runtime + dev tool deps.
install:
    julia --project=. -e 'using Pkg; Pkg.instantiate()'
    julia --project=./dev -e 'using Pkg; Pkg.instantiate()'

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

# CI checks.
check: lint shellcheck

# Purge generated + resolved state.
clean:
    rm -rf test/results test/artifacts
