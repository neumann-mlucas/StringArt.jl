#!/usr/bin/env bash
# Parametrized baseline runner for StringArt.jl.
# Sweeps fixtures × {grayscale, rgb, palette6} × {default, exclude-repeated}
# at default line-strength, plus 2 line-strength variations on grayscale.
# Each config emits both PNG and SVG.
#
# Usage:  ./test/scripts/baseline.sh                # full corpus
#         ./test/scripts/baseline.sh aristotle.png  # subset (basename or path)
#
# Env: PHASE (default pre-p1), JULIA_NUM_THREADS (default 8), JULIA_BIN.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${HERE}/lib.sh"

PHASE="${PHASE:-pre-p1}"
set_out_dir "$PHASE"
JULIA_OPTS=(-O3 -t "${JULIA_NUM_THREADS:-8}")
CSV_HEADER="phase,image,config,mode,flag,line_strength,size,pins,steps,seconds,status,git_sha"

# Fixed axes.
SIZE=512
PINS=240
STEPS=1500

# name|mode|flag|line_strength
# mode: grayscale|rgb|palette6
# flag: default|excl
# line_strength: 1..100 (default 25)
CONFIGS=(
  "grayscale_default|grayscale|default|25"
  "grayscale_excl|grayscale|excl|25"
  "rgb_default|rgb|default|25"
  "rgb_excl|rgb|excl|25"
  "palette6_default|palette6|default|25"
  "palette6_excl|palette6|excl|25"
  "grayscale_ls15|grayscale|default|15"
  "grayscale_ls40|grayscale|default|40"
)

mode_flags() {
  case "$1" in
    grayscale) ;;
    rgb)       echo "--rgb" ;;
    palette6)  echo "--palette 6" ;;
    *) echo "unknown mode: $1" >&2; exit 1 ;;
  esac
}

extra_flags() {
  case "$1" in
    default) ;;
    excl)    echo "--exclude-repeated-pins" ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
}

run_config() {
  local cfg="$1" input="$2" out_stem="$3"
  IFS='|' read -r name mode flag ls <<< "$cfg"

  local stem_short; stem_short="$(basename "$out_stem")"
  if [[ -f "${out_stem}.png" && -f "${out_stem}.svg" ]]; then
    echo "  SKIP  ${stem_short}.{png,svg}"; return
  fi

  # shellcheck disable=SC2046
  julia_timed "${out_stem}.log" "${JULIA_OPTS[@]}" --project="$PROJECT_DIR" main.jl \
    -i "$input" -o "${out_stem}.png,${out_stem}.svg" \
    -s "$SIZE" -n "$PINS" --steps "$STEPS" --line-strength "$ls" \
    $(mode_flags "$mode") $(extra_flags "$flag")

  local img; img="$(basename "$input" .png)"
  echo "${PHASE},${img},${name},${mode},${flag},${ls},${SIZE},${PINS},${STEPS},${LAST_SECS},${LAST_STATUS},$(git_sha)" >> "$BENCH_CSV"
  echo "  ${LAST_STATUS^^}  ${stem_short}.{png,svg}  ($(fmt_time "$LAST_SECS"))"
}

run_sweep "$@"
