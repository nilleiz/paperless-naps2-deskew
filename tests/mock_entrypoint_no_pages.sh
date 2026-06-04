#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/input" "$tmp/output" "$tmp/work"
printf '%s' '%PDF-1.4 fake' > "$tmp/input/no-pages.pdf"

cat > "$tmp/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo 1000
  exit 0
fi
command /usr/bin/id "$@"
STUB

cat > "$tmp/bin/pdftoppm" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "pdftoppm $*" >> "${MOCK_LOG}"
# Simulate a render that exits successfully but creates no PNG pages.
exit 0
STUB

cat > "$tmp/bin/naps2" <<'STUB'
#!/usr/bin/env bash
echo "naps2 should not be called" >> "${MOCK_LOG}"
exit 99
STUB

chmod +x "$tmp/bin"/*
: > "$tmp/mock.log"

set +e
PATH="$tmp/bin:$PATH" \
MOCK_LOG="$tmp/mock.log" \
INPUT_DIR="$tmp/input" \
OUTPUT_DIR="$tmp/output" \
WORK_DIR="$tmp/work" \
POLL_SECONDS=1 \
PDF_RENDER_DPI=300 \
ARCHIVE_ORIGINALS=true \
timeout 5 "$repo_root/entrypoint.sh"
code=$?
set -e

[[ "$code" -eq 124 ]]
[[ -f "$tmp/input/.failed/no-pages.pdf" ]]
[[ ! -e "$tmp/output/no-pages.pdf" ]]
grep -F -- 'pdftoppm -r 300 -png' "$tmp/mock.log" >/dev/null
if grep -F -- 'naps2 should not be called' "$tmp/mock.log" >/dev/null; then
  echo "NAPS2 was called even though no pages were rendered" >&2
  exit 1
fi
