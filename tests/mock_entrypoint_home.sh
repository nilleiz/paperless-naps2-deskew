#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/input" "$tmp/output" "$tmp/work"
printf '%s' '%PDF-1.4 fake' > "$tmp/input/home-check.pdf"

cat > "$tmp/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  if [[ "${MOCK_NON_ROOT:-}" == "1" ]]; then
    echo 1000
  else
    echo 0
  fi
  exit 0
fi
if [[ "${1:-}" == "naps2" ]]; then
  exit 0
fi
command /usr/bin/id "$@"
STUB

cat > "$tmp/bin/getent" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "group" ]]; then
  echo "naps2:x:${2:-1000}:"
  exit 0
fi
command /usr/bin/getent "$@"
STUB

cat > "$tmp/bin/usermod" <<'STUB'
#!/usr/bin/env bash
echo "usermod $*" >> "${MOCK_LOG}"
exit 0
STUB

cat > "$tmp/bin/useradd" <<'STUB'
#!/usr/bin/env bash
echo "useradd $*" >> "${MOCK_LOG}"
exit 0
STUB

cat > "$tmp/bin/groupadd" <<'STUB'
#!/usr/bin/env bash
echo "groupadd $*" >> "${MOCK_LOG}"
exit 0
STUB

cat > "$tmp/bin/chown" <<'STUB'
#!/usr/bin/env bash
echo "chown $*" >> "${MOCK_LOG}"
exit 0
STUB

cat > "$tmp/bin/gosu" <<'STUB'
#!/usr/bin/env bash
echo "gosu $*" >> "${MOCK_LOG}"
shift
export MOCK_NON_ROOT=1
exec "$@"
STUB

cat > "$tmp/bin/pdftoppm" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "pdftoppm $*" >> "${MOCK_LOG}"
[[ "$1" == "-r" ]]
[[ "$2" == "300" ]]
[[ "$3" == "-png" ]]
input_pdf="$4"
output_prefix="$5"
[[ "$input_pdf" == *.pdf ]]
printf 'page one' > "${output_prefix}-1.png"
printf 'page two' > "${output_prefix}-2.png"
STUB

cat > "$tmp/bin/naps2" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$HOME" == "/naps2" ]]
[[ "$XDG_CONFIG_HOME" == "/naps2/.config" ]]
[[ "$XDG_DATA_HOME" == "/naps2/.local/share" ]]
[[ "$XDG_CACHE_HOME" == "/naps2/.cache" ]]
[[ "$DOTNET_CLI_HOME" == "/naps2/.dotnet" ]]
[[ -d "$HOME" ]]
[[ -d "$XDG_CONFIG_HOME" ]]
[[ -d "$XDG_DATA_HOME" ]]
[[ -d "$XDG_CACHE_HOME" ]]
[[ -d "$DOTNET_CLI_HOME" ]]
echo "naps2 $*" >> "${MOCK_LOG}"
in=""
out=""
while (($#)); do
  case "$1" in
    -i) shift; in="$1" ;;
    -o) shift; out="$1" ;;
  esac
  shift || true
done
[[ "$in" == *'.png'* ]]
[[ "$in" != *'.pdf'* ]]
[[ "$in" == *';'* ]]
first_image="${in%%;*}"
cp "$first_image" "$out"
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
ARCHIVE_ORIGINALS=true \
timeout 5 "$repo_root/entrypoint.sh"
code=$?
set -e

[[ "$code" -eq 124 ]]
[[ -f "$tmp/output/home-check.pdf" ]]
[[ -f "$tmp/input/.processed/home-check.pdf" ]]
grep -F -- 'usermod --uid 1000 --gid 1000 --home /naps2 naps2' "$tmp/mock.log" >/dev/null
grep -F -- 'chown -R 1000:1000 /naps2' "$tmp/mock.log" >/dev/null
grep -F -- 'gosu 1000:1000' "$tmp/mock.log" >/dev/null
grep -F -- 'pdftoppm -r 300 -png' "$tmp/mock.log" >/dev/null
grep -F -- 'naps2 console -i' "$tmp/mock.log" >/dev/null
grep -F -- '.png;' "$tmp/mock.log" >/dev/null
grep -F -- ' -f' "$tmp/mock.log" >/dev/null
# The fake NAPS2 command above asserts that its -i value contains PNG pages and no PDF path.
