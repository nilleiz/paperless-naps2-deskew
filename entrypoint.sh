#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

configure_naps2_environment() {
  export HOME=/naps2
  export XDG_CONFIG_HOME=/naps2/.config
  export XDG_DATA_HOME=/naps2/.local/share
  export XDG_CACHE_HOME=/naps2/.cache
  export DOTNET_CLI_HOME=/naps2/.dotnet
  export PDF_RENDER_DPI="${PDF_RENDER_DPI:-auto}"
  export PDF_RENDER_DPI_FALLBACK="${PDF_RENDER_DPI_FALLBACK:-200}"
  export PDF_RENDER_DPI_MIN="${PDF_RENDER_DPI_MIN:-150}"
  export PDF_RENDER_DPI_MAX="${PDF_RENDER_DPI_MAX:-300}"
  export POSTPROCESS_GHOSTSCRIPT="${POSTPROCESS_GHOSTSCRIPT:-true}"
  export GS_DOWNSAMPLE_DPI="${GS_DOWNSAMPLE_DPI:-auto}"
  export GS_DOWNSAMPLE_DPI_FALLBACK="${GS_DOWNSAMPLE_DPI_FALLBACK:-200}"
  export GS_JPEG_QUALITY="${GS_JPEG_QUALITY:-90}"
  export GS_COMPATIBILITY_LEVEL="${GS_COMPATIBILITY_LEVEL:-1.7}"
}

create_naps2_directories() {
  mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_CACHE_HOME}" "${DOTNET_CLI_HOME}"
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_runtime_user() {
  local target_uid="${PUID:-1000}"
  local target_gid="${PGID:-1000}"

  if ! [[ "$target_uid" =~ ^[0-9]+$ && "$target_gid" =~ ^[0-9]+$ ]]; then
    log "startup: invalid PUID/PGID values PUID=$target_uid PGID=$target_gid"
    exit 1
  fi

  if ! getent group "$target_gid" >/dev/null; then
    groupadd --gid "$target_gid" naps2-runtime
  fi

  local group_name
  group_name="$(getent group "$target_gid" | cut -d: -f1)"

  configure_naps2_environment

  if id naps2 >/dev/null 2>&1; then
    usermod --uid "$target_uid" --gid "$target_gid" --home "$HOME" naps2
  else
    useradd --uid "$target_uid" --gid "$target_gid" --home-dir "$HOME" --create-home --shell /usr/sbin/nologin naps2
  fi

  mkdir -p "${INPUT_DIR}" "${OUTPUT_DIR}" "${WORK_DIR}" "${INPUT_DIR}/.processed" "${INPUT_DIR}/.failed"
  create_naps2_directories
  chown -R "$target_uid:$target_gid" "${HOME}" "${WORK_DIR}" 2>/dev/null || true
  chown "$target_uid:$target_gid" "${INPUT_DIR}" "${OUTPUT_DIR}" "${INPUT_DIR}/.processed" "${INPUT_DIR}/.failed" 2>/dev/null || true

  log "startup: switching to uid=${target_uid} gid=${target_gid} (${group_name}) home=${HOME}"
  exec gosu "$target_uid:$target_gid" "$0" "$@"
}

unique_path() {
  local dir="$1"
  local filename="$2"
  local stem ext candidate timestamp counter

  stem="${filename%.*}"
  ext="${filename##*.}"
  if [[ "$stem" == "$filename" ]]; then
    ext=""
  else
    ext=".${ext}"
  fi

  candidate="${dir}/${filename}"
  if [[ ! -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  candidate="${dir}/${stem}-${timestamp}${ext}"
  if [[ ! -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  counter=1
  while :; do
    candidate="${dir}/${stem}-${timestamp}-${counter}${ext}"
    if [[ ! -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    counter=$((counter + 1))
  done
}

is_skippable_file() {
  local path="$1"
  local name
  name="$(basename -- "$path")"

  [[ "$name" == .* ]] && return 0
  case "$name" in
    *.part|*.partial|*.tmp|*.temp|*.crdownload|*.download|~*|*~) return 0 ;;
  esac
  [[ ! "$name" =~ \.([Pp][Dd][Ff])$ ]] && return 0
  return 1
}

wait_until_stable() {
  local file="$1"
  local previous current

  previous=""
  while :; do
    if [[ ! -f "$file" ]]; then
      log "skipped file: disappeared before processing path=$file"
      return 1
    fi

    current="$(stat -c '%s:%Y' -- "$file")"
    if [[ -n "$previous" && "$current" == "$previous" ]]; then
      return 0
    fi

    log "waiting for file stability: path=$file poll_seconds=${POLL_SECONDS}"
    previous="$current"
    sleep "${POLL_SECONDS}"
  done
}

move_original() {
  local source="$1"
  local target_dir="$2"
  local target

  mkdir -p "$target_dir"
  target="$(unique_path "$target_dir" "$(basename -- "$source")")"
  mv -- "$source" "$target"
}

print_naps2_logs() {
  local log_file
  for log_file in "${XDG_CONFIG_HOME}/naps2/errorlog.txt" "${XDG_CONFIG_HOME}/naps2/debuglog.txt"; do
    if [[ -s "$log_file" ]]; then
      log "processing failure: printing NAPS2 log path=$log_file"
      sed 's/^/NAPS2 log: /' "$log_file" || true
    fi
  done
}


is_numeric() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

round_number() {
  awk -v value="$1" 'BEGIN { printf "%d", value + 0.5 }'
}

clamp_dpi() {
  local value="$1"
  local min_dpi="${2:-${PDF_RENDER_DPI_MIN}}"
  local max_dpi="${3:-${PDF_RENDER_DPI_MAX}}"
  local rounded

  if ! is_numeric "$value"; then
    return 1
  fi

  rounded="$(round_number "$value")"
  if (( rounded < min_dpi )); then
    rounded="$min_dpi"
  elif (( rounded > max_dpi )); then
    rounded="$max_dpi"
  fi

  printf '%s\n' "$rounded"
}

validate_dpi_config() {
  local name
  for name in PDF_RENDER_DPI_FALLBACK PDF_RENDER_DPI_MIN PDF_RENDER_DPI_MAX GS_DOWNSAMPLE_DPI_FALLBACK GS_JPEG_QUALITY; do
    if ! is_numeric "${!name}"; then
      log "startup: invalid numeric configuration ${name}=${!name}"
      exit 1
    fi
  done

  PDF_RENDER_DPI_MIN="$(round_number "$PDF_RENDER_DPI_MIN")"
  PDF_RENDER_DPI_MAX="$(round_number "$PDF_RENDER_DPI_MAX")"
  if (( PDF_RENDER_DPI_MIN > PDF_RENDER_DPI_MAX )); then
    log "startup: invalid DPI clamp range PDF_RENDER_DPI_MIN=${PDF_RENDER_DPI_MIN} PDF_RENDER_DPI_MAX=${PDF_RENDER_DPI_MAX}"
    exit 1
  fi
  export PDF_RENDER_DPI_MIN PDF_RENDER_DPI_MAX
}

detect_source_pdf_dpi() {
  local pdf="$1"
  local dpi_values

  if ! command -v pdfimages >/dev/null 2>&1; then
    log "dpi detection: pdfimages command not found"
    return 1
  fi

  dpi_values="$({ pdfimages -list "$pdf" || true; } | awk '
    function valid(value) { return value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0 }
    NR == 1 { next }
    {
      x = $13
      y = $14
      if (valid(x) && valid(y)) {
        print (x + y) / 2
      } else if (valid(x)) {
        print x
      } else if (valid(y)) {
        print y
      }
    }
  ' | sort -n)"

  if [[ -z "$dpi_values" ]]; then
    return 1
  fi

  awk '
    { values[++count] = $1 }
    END {
      if (count == 0) exit 1
      middle = int((count + 1) / 2)
      if (count % 2) {
        printf "%d\n", values[middle] + 0.5
      } else {
        printf "%d\n", ((values[middle] + values[middle + 1]) / 2) + 0.5
      }
    }
  ' <<< "$dpi_values"
}

select_render_dpi() {
  local detected_dpi="${1:-}"
  local selected

  if [[ "${PDF_RENDER_DPI}" == "auto" ]]; then
    if is_numeric "$detected_dpi"; then
      selected="$detected_dpi"
    else
      selected="$PDF_RENDER_DPI_FALLBACK"
    fi
  elif is_numeric "${PDF_RENDER_DPI}"; then
    selected="$PDF_RENDER_DPI"
  else
    log "startup: invalid PDF_RENDER_DPI=${PDF_RENDER_DPI}; use auto or a numeric DPI"
    exit 1
  fi

  clamp_dpi "$selected"
}

select_gs_dpi() {
  local render_dpi="$1"
  local selected

  if [[ "${GS_DOWNSAMPLE_DPI}" == "auto" ]]; then
    if is_numeric "$render_dpi"; then
      selected="$render_dpi"
    else
      selected="$GS_DOWNSAMPLE_DPI_FALLBACK"
    fi
  elif is_numeric "${GS_DOWNSAMPLE_DPI}"; then
    selected="$GS_DOWNSAMPLE_DPI"
  else
    log "startup: invalid GS_DOWNSAMPLE_DPI=${GS_DOWNSAMPLE_DPI}; use auto or a numeric DPI"
    exit 1
  fi

  clamp_dpi "$selected"
}

file_size() {
  stat -c '%s' -- "$1"
}

postprocess_with_ghostscript() {
  local naps2_pdf="$1"
  local compressed_pdf="$2"
  local gs_dpi="$3"

  log "ghostscript postprocess start: input=$naps2_pdf output=$compressed_pdf dpi=$gs_dpi jpeg_quality=${GS_JPEG_QUALITY} compatibility=${GS_COMPATIBILITY_LEVEL}"

  if gs -q -dNOPAUSE -dBATCH \
    -sDEVICE=pdfwrite \
    -dCompatibilityLevel="${GS_COMPATIBILITY_LEVEL}" \
    -dAutoRotatePages=/None \
    -dDownsampleColorImages=true \
    -dColorImageResolution="${gs_dpi}" \
    -dColorImageDownsampleThreshold=1.0 \
    -dAutoFilterColorImages=false \
    -sColorImageFilter=DCTEncode \
    -dJPEGQ="${GS_JPEG_QUALITY}" \
    -dDownsampleGrayImages=true \
    -dGrayImageResolution="${gs_dpi}" \
    -dGrayImageDownsampleThreshold=1.0 \
    -dAutoFilterGrayImages=false \
    -sGrayImageFilter=DCTEncode \
    -dDownsampleMonoImages=false \
    -sOutputFile="${compressed_pdf}" \
    "${naps2_pdf}" && [[ -s "$compressed_pdf" ]]; then
    log "ghostscript output size: path=$compressed_pdf bytes=$(file_size "$compressed_pdf")"
    return 0
  fi

  log "ghostscript fallback warning: compression failed or produced empty output; using uncompressed NAPS2 PDF input=$naps2_pdf"
  return 1
}

build_image_import_list() {
  local page_dir="$1"
  local image image_import_list
  local -a images

  images=()
  while IFS= read -r -d '' image; do
    images+=("$image")
  done < <(find "$page_dir" -maxdepth 1 -type f -name '*.png' -print0 | sort -zV)

  if [[ "${#images[@]}" -eq 0 ]]; then
    return 1
  fi

  image_import_list=""
  for image in "${images[@]}"; do
    if [[ -n "$image_import_list" ]]; then
      image_import_list+=';'
    fi
    image_import_list+="$image"
  done

  printf '%s\n' "$image_import_list"
}

process_pdf() {
  local input_file="$1"
  local filename work_dir work_input page_dir final_output tmp_output result_output image_import_list
  local detected_dpi selected_render_dpi gs_dpi compressed_output final_pdf
  local -a extra_args naps2_cmd

  filename="$(basename -- "$input_file")"
  log "detected file: path=$input_file"

  if is_skippable_file "$input_file"; then
    log "skipped file: unsupported or temporary name path=$input_file"
    return 0
  fi

  wait_until_stable "$input_file" || return 0

  work_dir="$(mktemp -d -p "${WORK_DIR}" job.XXXXXXXXXX)"
  final_output="$(unique_path "${OUTPUT_DIR}" "$filename")"
  tmp_output="${OUTPUT_DIR}/.$(basename -- "$final_output").tmp.$$.$RANDOM"
  result_output="${work_dir}/naps2-output.pdf"
  compressed_output="${work_dir}/compressed-output.pdf"

  cleanup() {
    rm -rf -- "$work_dir"
    rm -f -- "$tmp_output"
  }
  trap cleanup RETURN

  log "processing start: input=$input_file output=$final_output"

  work_input="${work_dir}/${filename}"
  page_dir="${work_dir}/pages"
  mkdir -p "$page_dir"
  cp -p -- "$input_file" "$work_input"

  detected_dpi=""
  if detected_dpi="$(detect_source_pdf_dpi "$work_input")"; then
    log "detected source DPI: input=$input_file dpi=$detected_dpi"
  else
    log "detected source DPI: input=$input_file dpi=none"
  fi

  selected_render_dpi="$(select_render_dpi "$detected_dpi")"
  log "selected render DPI: input=$input_file dpi=$selected_render_dpi source_setting=${PDF_RENDER_DPI} fallback=${PDF_RENDER_DPI_FALLBACK} min=${PDF_RENDER_DPI_MIN} max=${PDF_RENDER_DPI_MAX}"

  log "processing start: rasterizing input=$input_file dpi=${selected_render_dpi}"
  if ! pdftoppm -r "${selected_render_dpi}" -png "$work_input" "${page_dir}/page"; then
    log "processing failure: PDF rasterization failed input=$input_file"
    move_original "$input_file" "${INPUT_DIR}/.failed"
    return 0
  fi

  if ! image_import_list="$(build_image_import_list "$page_dir")"; then
    log "processing failure: PDF rasterization produced no PNG pages input=$input_file"
    move_original "$input_file" "${INPUT_DIR}/.failed"
    return 0
  fi

  extra_args=()
  if [[ -n "${NAPS2_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=( ${NAPS2_EXTRA_ARGS} )
  fi

  naps2_cmd=(naps2 console -i "$image_import_list" -n 0 --deskew --disableocr "${extra_args[@]}" -o "$result_output" -f)

  if "${naps2_cmd[@]}"; then
    if [[ ! -s "$result_output" ]]; then
      log "processing failure: NAPS2 completed but produced no output input=$input_file"
      print_naps2_logs
      move_original "$input_file" "${INPUT_DIR}/.failed"
      return 0
    fi

    log "NAPS2 output size: path=$result_output bytes=$(file_size "$result_output")"
    final_pdf="$result_output"

    if is_true "${POSTPROCESS_GHOSTSCRIPT:-true}"; then
      gs_dpi="$(select_gs_dpi "$selected_render_dpi")"
      log "selected Ghostscript downsample DPI: input=$input_file dpi=$gs_dpi source_setting=${GS_DOWNSAMPLE_DPI} fallback=${GS_DOWNSAMPLE_DPI_FALLBACK}"
      if postprocess_with_ghostscript "$result_output" "$compressed_output" "$gs_dpi"; then
        final_pdf="$compressed_output"
      fi
    fi

    cp -- "$final_pdf" "$tmp_output"
    mv -- "$tmp_output" "$final_output"
    log "final output size: path=$final_output bytes=$(file_size "$final_output")"

    if is_true "${ARCHIVE_ORIGINALS:-true}"; then
      move_original "$input_file" "${INPUT_DIR}/.processed"
      log "processing success: input=$input_file output=$final_output original=archived"
    else
      rm -f -- "$input_file"
      log "processing success: input=$input_file output=$final_output original=deleted"
    fi
  else
    log "processing failure: input=$input_file"
    print_naps2_logs
    move_original "$input_file" "${INPUT_DIR}/.failed"
  fi
}

run_watcher() {
  configure_naps2_environment
  validate_dpi_config
  mkdir -p "${INPUT_DIR}" "${OUTPUT_DIR}" "${WORK_DIR}" "${INPUT_DIR}/.processed" "${INPUT_DIR}/.failed"
  create_naps2_directories

  if ! command -v naps2 >/dev/null 2>&1; then
    log "startup: naps2 command not found"
    exit 1
  fi

  if ! command -v pdftoppm >/dev/null 2>&1; then
    log "startup: pdftoppm command not found"
    exit 1
  fi

  if ! command -v pdfimages >/dev/null 2>&1; then
    log "startup: pdfimages command not found"
    exit 1
  fi

  if is_true "${POSTPROCESS_GHOSTSCRIPT:-true}" && ! command -v gs >/dev/null 2>&1; then
    log "startup: gs command not found while POSTPROCESS_GHOSTSCRIPT=true"
    exit 1
  fi

  log "startup: watching input=${INPUT_DIR} output=${OUTPUT_DIR} poll_seconds=${POLL_SECONDS} archive_originals=${ARCHIVE_ORIGINALS} pdf_render_dpi=${PDF_RENDER_DPI} postprocess_ghostscript=${POSTPROCESS_GHOSTSCRIPT}"

  while :; do
    while IFS= read -r -d '' file; do
      process_pdf "$file"
    done < <(find "${INPUT_DIR}" -maxdepth 1 -type f -print0 | sort -z)

    sleep "${POLL_SECONDS}"
  done
}

if [[ "$(id -u)" == "0" ]]; then
  ensure_runtime_user "$@"
fi

run_watcher
