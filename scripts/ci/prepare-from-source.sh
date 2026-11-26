#!/usr/bin/env bash
# Build every input from source, from the pins in this repository.
#
# This replaces scripts/ci/prepare-runner.sh, which linked a private 26 GB cache
# and then did `sudo ln -sfn "$ROOT" /home/zpeirce/ps4-gladius` because generated
# makefiles and the compiler shim carried that absolute path. Nothing here needs
# that: the shim self-locates, and every input is a public base plus a pin in
# src/wine-trees, src/mesa-trees and src/orbis-compat-pin.
#
# Console modules (sce_module/libc.prx, libSceFios2.prx) are Sony's and are NOT
# built here; the runner supplies them, as it always has.
#
# Steps are stamped, so a second run on a warm runner rebuilds only what the
# pins changed. Delete $WORK to force a cold build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK="${PW_CI_WORK:-$ROOT/.ci-from-source}"
JOBS="${PW_CI_JOBS:-$(nproc)}"
mkdir -p "$WORK"

say() { echo "== $*"; }

# A stamp is the pin content that decides a step's output. If it has not moved,
# the step is skipped -- these builds are hours long and CI reruns are common.
stamped() {
    local name=$1 stamp=$2; shift 2
    local f="$WORK/.stamp-$name"
    if [[ -f $f && "$(cat "$f")" == "$stamp" ]]; then
        say "$name: up to date"; return 0
    fi
    say "$name: building"
    "$@"
    echo "$stamp" > "$f"
}

pin_stamp() { cat "$@" 2>/dev/null | sha256sum | cut -c1-16; }

# ---------------------------------------------------------------- SDK bundle
stamped sdk "$(sha256sum "$ROOT/scripts/fetch-sdk.sh" | cut -c1-16)" \
    "$ROOT/scripts/fetch-sdk.sh"

# ------------------------------------------------------------- prospero-win
say "prospero-win: checking pinned native-module build source"
"$ROOT/scripts/ci/checkout-prospero-win.sh"
PW=${PW_PROSPERO_ROOT:-$ROOT/prospero-win}

# --------------------------------------------------------------- Wine trees
restore_wine() {
    "$ROOT/scripts/restore-wine-trees.sh" "$WORK/wine-trees"
    mkdir -p "$PW/.deps/wine-ps5" "$PW/.deps/wine-host" "$PW/.deps/wine"
    rm -rf "$PW/.deps/wine-ps5/source" "$PW/.deps/wine-host/source"
    cp -a "$WORK/wine-trees/wine-ps5"  "$PW/.deps/wine-ps5/source"
    cp -a "$WORK/wine-trees/wine-host" "$PW/.deps/wine-host/source"
    if [[ ! -d $PW/.deps/wine/source/.git ]]; then
        git clone -q --no-checkout https://gitlab.winehq.org/wine/wine.git "$PW/.deps/wine/source"
    fi
    git -C "$PW/.deps/wine/source" checkout -q --detach \
        490f6d5dcbb2a5047345b8af88d114bbcaad69a8
}
stamped wine-trees "$(pin_stamp "$ROOT"/src/wine-trees/*-HEAD.txt)" restore_wine

# --------------------------------------------------------------- mesa-ps4
stamped mesa-tree "$(pin_stamp "$ROOT/src/mesa-trees/mesa-ps4-HEAD.txt")" \
    "$ROOT/scripts/restore-mesa-tree.sh" "$ROOT/mesa-build"

# ------------------------------------------------------------- toolchain
prepare_toolchain() {
    "$ROOT/scripts/prepare-ps4-toolchain.sh"
    # build_wine_ps5.sh calls these through the SDK; only prepare-runner.sh
    # used to create them, by hand.
    cd "$ROOT/build/ps4-wine-sdk/bin"
    local t src
    for t in llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-readelf llvm-strip; do
        src=$(command -v "$t-19" || command -v "$t")
        [[ -n $src ]] || { echo "missing LLVM tool: $t" >&2; exit 1; }
        ln -sfn "$src" "$t"
    done
    src=$(command -v ld.lld-19 || command -v ld.lld)
    ln -sfn "$src" orbis-ld
}
# ⚠ The stamp must cover everything the archives are built FROM, not just the
# shim: libwineshim.a compiles src/native/*.c and prospero-win's wine/ps5 units.
# Keyed on the shim alone, a change to src/native would be silently skipped and
# the build would ship the previous objects -- this project's most common bug.
stamped toolchain \
    "$(pin_stamp "$ROOT/src/toolchain/prospero-clang" "$ROOT"/src/native/*.c \
        "$PW"/wine/ps5/*.c 2>/dev/null)" \
    prepare_toolchain

# ------------------------------------------------------------------- Wine
stamped wine-runtime "$(pin_stamp "$ROOT/src/wine-trees/wine-host-HEAD.txt" \
    "$ROOT/src/prospero-win-HEAD.txt" "$PW/tools/build_wine_runtime.sh")" \
    sh "$PW/tools/build_wine_runtime.sh" --jobs "$JOBS"

build_wine_ps5() {
    PROSPERO_WINE_PREPATCHED=1 PW_PRX_LINK=1 \
        sh "$PW/tools/build_wine_ps5.sh" --source "$PW/.deps/wine-ps5/source" \
            --sdk "$ROOT/build/ps4-wine-sdk"
}
stamped wine-ps5 "$(pin_stamp "$ROOT/src/wine-trees/wine-ps5-HEAD.txt" \
    "$ROOT/src/prospero-win-HEAD.txt" "$PW/tools/build_wine_ps5.sh")" build_wine_ps5

build_host_wine() {
    PROSPERO_WINE_PREPATCHED=1 \
        sh "$PW/tools/build_host_wine.sh" --source "$PW/.deps/wine-host/source" \
            --work "$PW/.deps/wine-host" --jobs "$JOBS"
}
stamped wine-host "$(pin_stamp "$ROOT/src/wine-trees/wine-host-HEAD.txt" \
    "$ROOT/src/prospero-win-HEAD.txt" "$PW/tools/build_host_wine.sh" \
    "$PW/tools/build_wine_ps5.sh")" build_host_wine

# ------------------------------------------------------------------- Mesa
# ⚠ RADV IS THE ONE MODULE THAT MUST **NOT** USE THE PIN orbis-compat.
# Measured on hardware 2026-11-17 (Fallout: New Vegas, one variable changed):
#   libvulkan.prx against the PIN    -> 0xc0000005 at libvulkan.so+0x16a6dba,
#                                       frames_put=0, every title on the spinner
#   libvulkan.prx against the BUNDLE -> 0 faults, 1920x1080, 59.8 fps
# Every other PRX needs the PIN, whose include/signal.h fix (SIG_UNBLOCK=2) is what
# lets Wine's native-frame probe pass; without it wow64native returns c00000bb and
# every title silently drops to the wowprospero translator. RADV does not care about
# the signal ABI. So the split is deliberate, and each module stays CONSISTENT: the
# headers it compiles against and the archive it links are the same orbis-compat.
# (Working packages always shipped this split -- by accident of a five-week-old
# staged archive. PW_RADV_ORBIS_COMPAT makes it explicit.)
MESA_ORBIS_COMPAT="${PW_RADV_ORBIS_COMPAT:-$ROOT/sdk/orbis-sdk-v1/orbis-compat}"
build_mesa() {
    ORBIS_KIT_DIR="${ORBIS_KIT_DIR:-$MESA_ORBIS_COMPAT}" \
    ORBIS_COMPAT_DIR="$MESA_ORBIS_COMPAT" \
    OO_PS4_TOOLCHAIN="$ROOT/sdk/orbis-sdk-v1/sdk" \
        bash "$ROOT/mesa-build/mesa-ps4/ps4/build.sh"
}
stamped mesa "$(pin_stamp "$ROOT/src/mesa-trees/mesa-ps4-HEAD.txt")" build_mesa

# -------------------------------------------------------------------- PRXs
# Always relinked: they are cheap next to the Wine build and they are what the
# package stages. A stale PRX is the failure this project has shipped most.
say "PRX modules"
sh "$ROOT/scripts/prx-ps4.sh"
sh "$ROOT/scripts/freetype-prx-ps4.sh"
# ⚠ The PRX link reads the STAGED archive (prospero-clang's OCLIB,
# build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a), NOT $PW_ORBIS_COMPAT -- that
# only steers the executable link and the toolchain guard. So stage the bundle for
# the RADV link and put the pin back straight after, or the next PRX built would
# silently link the wrong one.
OCLIB_STAGED="$ROOT/build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a"
cp "$OCLIB_STAGED" "$OCLIB_STAGED.pin-backup"
cp "$MESA_ORBIS_COMPAT/build/liborbis-compat.a" "$OCLIB_STAGED"
PW_RADV_MESA_SRC="$ROOT/mesa-build/mesa-ps4" \
PW_RADV_MESA_BUILD="$ROOT/mesa-build/mesa-ps4/build-orbis" \
    sh "$ROOT/scripts/radv-prx-ps4.sh"
mv "$OCLIB_STAGED.pin-backup" "$OCLIB_STAGED"
sh "$ROOT/scripts/wineps5-prx-ps4.sh"

say "from-source inputs ready"
ls -la "$PW/.deps/wine-ps5/prx/sce_module/"
