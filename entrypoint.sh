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
  export PDF_RENDER_DPI="${PDF_RENDER_DPI:-300}"
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
  result_output="${work_dir}/output.pdf"

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

  log "processing start: rasterizing input=$input_file dpi=${PDF_RENDER_DPI}"
  if ! pdftoppm -r "${PDF_RENDER_DPI}" -png "$work_input" "${page_dir}/page"; then
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

    cp -- "$result_output" "$tmp_output"
    mv -- "$tmp_output" "$final_output"

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

  log "startup: watching input=${INPUT_DIR} output=${OUTPUT_DIR} poll_seconds=${POLL_SECONDS} archive_originals=${ARCHIVE_ORIGINALS} pdf_render_dpi=${PDF_RENDER_DPI}"

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
