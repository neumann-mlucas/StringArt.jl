#!/usr/bin/env bash
# Parametrized baseline runner for StringArt.jl.
# Sweeps every fixture over {grayscale, rgb, palette6} × {default, exclude-repeated}.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd -- "${HERE}/../.." &>/dev/null && pwd)"
PHASE="${PHASE:-pre-p1}"
CORPUS_DIR="${PROJECT_DIR}/test/fixtures"
OUT_DIR="${PROJECT_DIR}/test/results/${PHASE}"
NORM_DIR="${OUT_DIR}/_inputs"
BENCH_CSV="${OUT_DIR}/bench.csv"
JULIA_BIN="${JULIA_BIN:-julia}"
JULIA_OPTS=(-O3 -t "${JULIA_NUM_THREADS:-8}")
CSV_HEADER="phase,image,config,mode,flag,size,pins,steps,seconds,status,git_sha"

# Fixed axes.
SIZE=512
PINS=240
STEPS=1500

# name|mode|flag
# mode: grayscale|rgb|palette6
# flag: default|excl
CONFIGS=(
  "grayscale_default|grayscale|default"
  "grayscale_excl|grayscale|excl"
  "rgb_default|rgb|default"
  "rgb_excl|rgb|excl"
  "palette6_default|palette6|default"
  "palette6_excl|palette6|excl"
)

source "${HERE}/lib.sh"

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
  IFS='|' read -r name mode flag <<< "$cfg"

  local stem_short; stem_short="$(basename "$out_stem")"
  if [[ -f "${out_stem}.png" ]]; then
    echo "  SKIP  ${stem_short}.png"; return
  fi

  # shellcheck disable=SC2046
  julia_timed "${out_stem}.log" "${JULIA_OPTS[@]}" --project="$PROJECT_DIR" main.jl \
    -i "$input" -o "${out_stem}.png" \
    -s "$SIZE" -n "$PINS" --steps "$STEPS" \
    $(mode_flags "$mode") $(extra_flags "$flag")

  local img; img="$(basename "$input" .png)"
  echo "${PHASE},${img},${name},${mode},${flag},${SIZE},${PINS},${STEPS},${LAST_SECS},${LAST_STATUS},$(git_sha)" >> "$BENCH_CSV"
  echo "  ${LAST_STATUS^^}  ${stem_short}.png  ($(fmt_time $LAST_SECS))"
}

run_sweep "$@"
