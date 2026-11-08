#!/usr/bin/env bash
# Guard: the prospero-win fork's Wine patch series must build the Wine this
# package ships.
#
#   1. The series is well-formed (tools/build_wine_ps5.sh --check-patches) and
#      applies, in order, with `git apply --index`, to a clean checkout of the
#      pinned Wine revision -- exactly as tools/build_host_wine.sh applies it.
#   2. With the build's staged sources added (the same steps as
#      build_host_wine.sh), the result is identical to the host Wine source
#      tree the package's PE runtime was built from (PW_HOST_WINE/source).
#
# Since 2026-11-08 that tree is built by build_host_wine.sh from the series
# alone. Before that, the shipped Wine carried hand edits no patch held, and the
# series could not even be applied (two 0740 patches); nothing noticed. A
# failure here means the series and the cached build have drifted apart: fix
# the series (or rebuild the cache from it), never the tree by hand.
#
# Usage: scripts/ci/check-wine-series.sh [PW_ROOT] [HOST_WINE]
#   PW_ROOT    the prospero-win checkout (default $PW_ABI4_ROOT/source)
#   HOST_WINE  host Wine work dir with source/ (default PW_ROOT/.deps/wine-host)
set -euo pipefail

ABI4=${PW_ABI4_ROOT:-/home/zpeirce/codex_scratch/abi4-upstream-port-20261104}
PW=${1:-$ABI4/source}
HOST_WINE=${2:-${PW_HOST_WINE:-$PW/.deps/wine-host}}
SOURCE=$HOST_WINE/source
# The runner's cache belongs to another user; trust this one repository for
# the commands below rather than every directory.
wgit() { git -c safe.directory="$SOURCE" -c init.defaultBranch=main "$@"; }

commit=$(sed -n 's/^WINE_COMMIT=//p' "$PW/tools/build_wine_ps5.sh")
[[ -n $commit ]] || { echo "no WINE_COMMIT in $PW/tools/build_wine_ps5.sh" >&2; exit 1; }
wgit -C "$SOURCE" cat-file -e "$commit^{commit}" 2>/dev/null || {
  echo "$SOURCE does not have the pinned Wine revision $commit" >&2; exit 1; }
ordered=$(sh "$PW/tools/build_wine_ps5.sh" --check-patches) || {
  echo "the Wine patch series is not well-formed (build_wine_ps5.sh --check-patches)" >&2; exit 1; }

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/wine-series.XXXXXX")
trap 'rm -rf "$work"' EXIT
tree=$work/source
wgit clone -q --shared --no-checkout "$SOURCE" "$tree"
git -C "$tree" checkout -q --force "$commit"

n=0
for patch in $ordered; do
  if ! git -C "$tree" apply --index "$PW/wine/patches/$patch" 2> "$work/apply.err"; then
    echo "::error::Wine patch does not apply in order: $patch" >&2
    cat "$work/apply.err" >&2
    exit 1
  fi
  n=$((n + 1))
done
echo "wine series: $n patches apply to $commit"

# The sources build_host_wine.sh stages after patching.
python3 "$PW/tools/stage_vk_batch.py" --source "$tree" --repo "$PW" > /dev/null
cp "$PW/wine/ps5/time/pw_qpc_clock.h" "$tree/dlls/ntdll/pw_qpc_clock.h"
cp "$PW/wine/ps5/menu/pw_title_menu.h" "$tree/dlls/ntdll/pw_title_menu.h"
cp "$PW/wine/ps5/input/pw_key_shared.h" "$tree/dlls/win32u/pw_key_shared.h"

if ! diff -rq --exclude=.git "$tree" "$SOURCE" > "$work/diff.txt"; then
  echo "::error::the host Wine source ($SOURCE) is not what the series builds" >&2
  head -50 "$work/diff.txt" >&2
  exit 1
fi
echo "wine series: $SOURCE is exactly the series' result"
