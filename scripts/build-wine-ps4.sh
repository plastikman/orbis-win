#!/usr/bin/env bash
# Build the two Wine trees the PS4 package needs, from prospero-win's series:
#   host   prospero-win/.deps/wine-host  (tools/build_host_wine.sh: WoW64 PE side,
#          winebuild/widl, the 32-bit kernelbase.dll with PW_EXCEPTION32)
#   ps5    prospero-win/.deps/wine-ps5   (tools/build_wine_ps5.sh: the Unix side
#          cross-compiled with build/ps4-wine-sdk/bin/prospero-clang; make.log is
#          what scripts/prx-ps4.sh reads back)
#
# build_wine_ps5.sh puts prospero-win's real wine/ps5 heap and dmem objects on
# the ntdll and wineserver links. src/toolchain/prospero-clang adds its stand-in
# for them, build/ps4-wine-sdk/libwineshim.a, unless PW_PRX_LINK=1, and then
# ntdll.so fails with "duplicate symbol: pw_wine_dmem_init" (measured
# 2026-11-17 with prospero-win fe5c8d1). So the ps5 step runs with PW_PRX_LINK=1,
# as scripts/prx-ps4.sh does for its own links.
set -euo pipefail

usage() {
    cat <<EOF
usage: $0 [--host|--ps5|--all] [--jobs N]

  --host    only the host Wine (prospero-win/.deps/wine-host)
  --ps5     only the PS4 cross build (prospero-win/.deps/wine-ps5); needs --host first
  --all     both (default)
  --jobs N  make -j (default: nproc)

Environment: PW_ROOT (default: this checkout's prospero-win/). The toolchain must be
ready (scripts/prepare-ps4-toolchain.sh). Both prospero-win scripts reset and
re-patch their source trees and relink every run; make rebuilds what changed.
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PW=${PW_ROOT:-$ROOT/prospero-win}
SDK=$ROOT/build/ps4-wine-sdk
WHAT=all
JOBS=$(nproc)
while [[ $# -gt 0 ]]; do
    case $1 in
        --host) WHAT=host; shift ;;
        --ps5) WHAT=ps5; shift ;;
        --all) WHAT=all; shift ;;
        --jobs)
            if [[ $# -lt 2 || ! $2 =~ ^[1-9][0-9]*$ ]]; then
                echo "--jobs needs a positive number" >&2; usage >&2; exit 2
            fi
            JOBS=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
# The prospero-win scripts run from inside it, so a relative PW_ROOT must be absolute.
[[ -f $PW/tools/build_wine_ps5.sh ]] ||
    { echo "no prospero-win at $PW (set PW_ROOT)" >&2; exit 1; }
PW=$(cd "$PW" && pwd -P)

if [[ $WHAT == host || $WHAT == all ]]; then
    (cd "$PW" && sh tools/build_host_wine.sh --jobs "$JOBS")
fi
if [[ $WHAT == ps5 || $WHAT == all ]]; then
    [[ -x $SDK/bin/prospero-clang && -x $SDK/bin/llvm-ar ]] || {
        echo "no PS4 toolchain in $SDK/bin (prospero-clang, and the LLVM 19 links from" >&2
        echo "scripts/link-llvm-ps4.sh): run scripts/prepare-ps4-toolchain.sh first" >&2
        exit 1
    }
    [[ -x $PW/.deps/wine-host/build/tools/winebuild/winebuild ]] ||
        { echo "no host Wine tools in $PW/.deps/wine-host/build: run with --host first" >&2; exit 1; }
    (cd "$PW" && PW_PRX_LINK=1 PATH="$SDK/bin:$PATH" sh tools/build_wine_ps5.sh \
        --sdk "$SDK" --host-tools "$PW/.deps/wine-host/build" \
        --source "$PW/.deps/wine/source" --jobs "$JOBS")
fi
