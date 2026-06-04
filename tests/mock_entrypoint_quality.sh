#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_case() {
  local name="$1"
  local detected_dpi="$2"
  local pdf_render_dpi="$3"
  local expected_render_dpi="$4"
  local gs_fail="$5"
  local expected_content="$6"

  local tmp
  tmp="$(mktemp -d)"
  cleanup_case() {
    rm -rf "$tmp"
  }
  trap cleanup_case RETURN

  mkdir -p "$tmp/bin" "$tmp/input" "$tmp/output" "$tmp/work"
  printf '%s' '%PDF-1.4 fake' > "$tmp/input/${name}.pdf"

  cat > "$tmp/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo 1000
  exit 0
fi
command /usr/bin/id "$@"
STUB

  cat > "$tmp/bin/pdfimages" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "pdfimages $*" >> "${MOCK_LOG}"
echo 'page   num  type   width height color comp bpc  enc interp  object ID x-ppi y-ppi size ratio'
case "${MOCK_DETECTED_DPI}" in
  none) exit 0 ;;
  invalid)
    echo '   1     0 image    1000  1000  rgb     3   8  jpeg   no         8  0     -     -  100K  77%'
    ;;
  *)
    echo "   1     0 image    1000  1000  rgb     3   8  jpeg   no         8  0   ${MOCK_DETECTED_DPI}   ${MOCK_DETECTED_DPI}  100K  77%"
    ;;
esac
STUB

  cat > "$tmp/bin/pdftoppm" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "pdftoppm $*" >> "${MOCK_LOG}"
[[ "$1" == "-r" ]]
[[ "$2" == "${EXPECT_RENDER_DPI}" ]]
[[ "$3" == "-png" ]]
printf 'page one' > "$5-1.png"
STUB

  cat > "$tmp/bin/naps2" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "naps2 $*" >> "${MOCK_LOG}"
out=""
in=""
while (($#)); do
  case "$1" in
    -i) shift; in="$1" ;;
    -o) shift; out="$1" ;;
  esac
  shift || true
done
[[ "$in" == *'.png'* ]]
[[ "$in" != *'.pdf'* ]]
printf 'naps2 output' > "$out"
STUB

  cat > "$tmp/bin/gs" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "gs $*" >> "${MOCK_LOG}"
for arg in "$@"; do
  case "$arg" in
    -dColorImageResolution=*) [[ "${arg#-dColorImageResolution=}" == "${EXPECT_RENDER_DPI}" ]] ;;
    -dGrayImageResolution=*) [[ "${arg#-dGrayImageResolution=}" == "${EXPECT_RENDER_DPI}" ]] ;;
    -dJPEGQ=*) [[ "${arg#-dJPEGQ=}" == "90" ]] ;;
  esac
done
if [[ "${MOCK_GS_FAIL}" == "1" ]]; then
  exit 42
fi
out=""
for arg in "$@"; do
  case "$arg" in
    -sOutputFile=*) out="${arg#-sOutputFile=}" ;;
  esac
done
[[ -n "$out" ]]
printf 'compressed output' > "$out"
STUB

  chmod +x "$tmp/bin"/*
  : > "$tmp/mock.log"

  set +e
  PATH="$tmp/bin:$PATH" \
  MOCK_LOG="$tmp/mock.log" \
  MOCK_DETECTED_DPI="$detected_dpi" \
  MOCK_GS_FAIL="$gs_fail" \
  EXPECT_RENDER_DPI="$expected_render_dpi" \
  INPUT_DIR="$tmp/input" \
  OUTPUT_DIR="$tmp/output" \
  WORK_DIR="$tmp/work" \
  POLL_SECONDS=1 \
  PDF_RENDER_DPI="$pdf_render_dpi" \
  PDF_RENDER_DPI_FALLBACK=200 \
  PDF_RENDER_DPI_MIN=150 \
  PDF_RENDER_DPI_MAX=300 \
  POSTPROCESS_GHOSTSCRIPT=true \
  GS_DOWNSAMPLE_DPI=auto \
  GS_DOWNSAMPLE_DPI_FALLBACK=200 \
  GS_JPEG_QUALITY=90 \
  GS_COMPATIBILITY_LEVEL=1.7 \
  ARCHIVE_ORIGINALS=true \
  timeout 5 "$repo_root/entrypoint.sh"
  local code=$?
  set -e

  [[ "$code" -eq 124 ]]
  [[ -f "$tmp/output/${name}.pdf" ]]
  [[ -f "$tmp/input/.processed/${name}.pdf" ]]
  [[ "$(cat "$tmp/output/${name}.pdf")" == "$expected_content" ]]
  grep -F -- "pdftoppm -r ${expected_render_dpi} -png" "$tmp/mock.log" >/dev/null
  grep -F -- "-dColorImageResolution=${expected_render_dpi}" "$tmp/mock.log" >/dev/null
  grep -F -- 'gs -q -dNOPAUSE -dBATCH' "$tmp/mock.log" >/dev/null
  if find "$tmp/output" -maxdepth 1 -type f -name '.*.tmp.*' | grep -q .; then
    echo "temporary atomic-output file was left behind for case $name" >&2
    exit 1
  fi
  trap - RETURN
  rm -rf "$tmp"
}

run_case auto-detected-200 200 auto 200 0 'compressed output'
run_case auto-no-dpi none auto 200 0 'compressed output'
run_case auto-invalid-dpi invalid auto 200 0 'compressed output'
run_case auto-below-min 72 auto 150 0 'compressed output'
run_case auto-above-max 600 auto 300 0 'compressed output'
run_case numeric-250 200 250 250 0 'compressed output'
run_case gs-fallback 200 auto 200 1 'naps2 output'
