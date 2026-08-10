# Batch-sweep helpers — vendored in StringArt.jl and MonteCarloArt.jl.
# Sync manually across both when editing.
#
# Caller sets these before sourcing:
#   PROJECT_DIR   julia project root (has Project.toml)
#   CORPUS_DIR    fixture dir
#   OUT_DIR       output dir
#   NORM_DIR      normalized-PNG cache dir
#   BENCH_CSV     CSV path
#   CSV_HEADER    CSV header row
#   CONFIGS       array of pipe-delim rows; first field is the config name
#   JULIA_BIN     julia binary (default: julia)
# Caller defines:
#   run_config <cfg_row> <input_path> <out_stem>
#     Should skip-if-exists, invoke julia via julia_timed, and append a
#     CSV row. `LAST_SECS` and `LAST_STATUS` are populated by julia_timed.
# Then calls:
#   run_sweep "$@"
#   (positional args are optional subset selectors — file paths or basenames
#    resolved against CORPUS_DIR; empty argv = full corpus)

set -euo pipefail

# --- setup / discovery ---------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

im_convert() {
  if have magick; then magick "$1" "$2"
  elif have convert; then convert "$1" "$2"
  else echo "ERROR: need 'magick' or 'convert' for $1" >&2; exit 1
  fi
}

normalize_to_png() {
  local src="$1" name stem ext dst
  name="$(basename "$src")"; stem="${name%.*}"; ext="${name##*.}"
  dst="${NORM_DIR}/${stem}.png"
  if [[ ! -f "$dst" ]]; then
    case "${ext,,}" in
      png) cp "$src" "$dst" ;;
      *)   im_convert "$src" "$dst" ;;
    esac
  fi
  echo "$dst"
}

fmt_time() { local s="$1"; printf '%dm%02ds' $((s / 60)) $((s % 60)); }

git_sha() { git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown; }

# --- log-grep helpers (safe when nothing matches) ------------------------

extract_circles() {
  (grep -oE 'with [0-9]+ circles' "$1" 2>/dev/null || true) | awk '{print $2}' | tail -1
}

extract_stopped_at() {
  (grep -oE 'Early stop at step [0-9]+' "$1" 2>/dev/null || true) | awk '{print $5}' | tail -1
}

# --- julia runner --------------------------------------------------------

# Timed julia invocation. Args after `log` form the full argv passed to julia.
# Populates globals LAST_SECS (int) and LAST_STATUS ("ok" or "fail").
julia_timed() {
  local log="$1"; shift
  local t0 t1 ec=0
  t0=$(date +%s)
  (cd "$PROJECT_DIR" && "${JULIA_BIN:-julia}" "$@") >"$log" 2>&1 || ec=$?
  t1=$(date +%s)
  LAST_SECS=$((t1 - t0))
  LAST_STATUS=$([[ $ec -eq 0 ]] && echo ok || echo fail)
}

# --- source selection ----------------------------------------------------

# Populates the named array with source paths.
# If argv is empty: full corpus glob. Else: each arg resolved as file or basename.
collect_sources() {
  local -n _out=$1; shift
  if (( $# > 0 )); then
    for arg in "$@"; do
      if [[ -f "$arg" ]]; then _out+=("$arg")
      elif [[ -f "${CORPUS_DIR}/${arg}" ]]; then _out+=("${CORPUS_DIR}/${arg}")
      else echo "ERROR: not found: $arg" >&2; exit 1
      fi
    done
  else
    shopt -s nullglob nocaseglob
    for f in "${CORPUS_DIR}"/*.{png,jpg,jpeg,tiff,tif,webp}; do _out+=("$f"); done
    shopt -u nocaseglob
    (( ${#_out[@]} > 0 )) || { echo "ERROR: no images in $CORPUS_DIR" >&2; exit 1; }
  fi
}

# --- driver --------------------------------------------------------------

run_sweep() {
  mkdir -p "$OUT_DIR" "$NORM_DIR"
  [[ -f "$BENCH_CSV" ]] || echo "$CSV_HEADER" > "$BENCH_CSV"

  local sources=()
  collect_sources sources "$@"

  local total=$(( ${#sources[@]} * ${#CONFIGS[@]} ))
  local i=0
  local overall_t0; overall_t0=$(date +%s)

  local src png stem cfg out
  for src in "${sources[@]}"; do
    png="$(normalize_to_png "$src")"
    stem="$(basename "$png" .png)"
    echo "=== $stem ==="
    for cfg in "${CONFIGS[@]}"; do
      i=$((i + 1))
      local cfg_name="${cfg%%|*}"
      out="${OUT_DIR}/${stem}__${cfg_name}"
      printf '[%02d/%02d] ' "$i" "$total"
      run_config "$cfg" "$png" "$out"
    done
  done

  local overall_t1; overall_t1=$(date +%s)
  echo
  echo "Done: $total runs in $(fmt_time $((overall_t1 - overall_t0)))"
  echo "Outputs: $OUT_DIR"
  echo "Bench:   $BENCH_CSV"
}
