#!/usr/bin/env bash
# Build the ABI-v4 PS4 package from source, the way GLDS10043 01.06 was
# validated on hardware (2026-11-05: GTA IV, FNV, FO3, Oblivion native; MDK
# translator), then refuse to publish it unless every parity gate passes.
#
# The same script runs on the GitHub runner and on the build workstation, so CI
# and local builds cannot drift. See docs/UPSTREAM-SYNC-PLAYBOOK.md.
#
# Inputs (environment):
#   PW_ABI4_ROOT          ABI-v4 sync directory: source/ (prospero-win ABI-v4
#                         with .deps/wine-host), build/wine-ps5/, native/,
#                         mesa-zink/. Its generated makefiles embed this
#                         absolute path; the runner symlinks it to the cache
#                         (prepare-runner.sh), which also exports this variable
#                         to the later workflow steps.
#   PW_ROOT               without PW_ABI4_ROOT: the prospero-win tree (default
#                         this checkout's prospero-win/), built in place by
#                         its tools/build_host_wine.sh and build_wine_ps5.sh.
#   WOW64NATIVE_DLL       without PW_ABI4_ROOT: the ABI-v4 wow64native.dll
#                         (default PW_ROOT/.deps/wow64native/x86_64-windows/...).
#                         Its hash stays pinned below.
#   PW_MESA_ZINK_DIR      without PW_ABI4_ROOT: tools/build_mesa_zink.sh's
#                         artifacts (default PW_ROOT/.deps/mesa-zink).
#                         With PW_ABI4_ROOT both come from that directory and
#                         these two variables are ignored, as before.
#   OUT                   output directory (required)
#   TITLE_ID, TITLE, PKG_VERSION
#   PS4_BASELINE_STAGE    known-good stage the parity check compares against
#   PS4_PKGTOOL_OPENSSL_LIB  directory holding libssl.so.1.1 for PkgTool.Core
set -euo pipefail
case ${1:-} in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# Two layouts: the synced ABI-v4 directory (CI, the workstation that fills its
# cache), or a prospero-win tree built in place (any other host).
if [[ -n ${PW_ABI4_ROOT:-} ]]; then
  PW=$PW_ABI4_ROOT/source
  WOW64NATIVE_DLL=$PW_ABI4_ROOT/native/x86_64-windows/wow64native.dll
  MESA_ZINK=$PW_ABI4_ROOT/mesa-zink
else
  PW=${PW_ROOT:-$ROOT/prospero-win}
  WOW64NATIVE_DLL=${WOW64NATIVE_DLL:-$PW/.deps/wow64native/x86_64-windows/wow64native.dll}
  MESA_ZINK=${PW_MESA_ZINK_DIR:-$PW/.deps/mesa-zink}
fi
OUT=${OUT:?set OUT to the output directory}
TITLE_ID=${TITLE_ID:-GLDS10043}
TITLE=${TITLE:-Orbis Wine ABI-v4}
PKG_VERSION=${PKG_VERSION:-01.00}
# pkgout/baseline -> the promoted known-good build (GLDS10043 01.21 since
# 2026-11-05; the 1090 stage before it stays in pkgout for history).
BASELINE=${PS4_BASELINE_STAGE:-$ROOT/pkgout/baseline/pkg-stage}
# One lookup for every package script (scripts/find-openssl11.sh). A hit is
# exported, so the bundle's make-pkg.sh uses the same directory instead of
# fetching a copy; on a miss the old default stays and make-pkg.sh fetches one.
if OPENSSL_LIB=$("$ROOT/scripts/find-openssl11.sh"); then
  export PS4_PKGTOOL_OPENSSL_LIB=$OPENSSL_LIB
else
  OPENSSL_LIB=${XDG_CACHE_HOME:-$HOME/.cache}/orbis-ports/openssl11/lib
fi
SDKBIN=$ROOT/sdk/orbis-sdk-v1/sdk/bin/linux

# The matched ABI-v4 native WoW64 pair that 01.06 shipped. The PE side is built
# by prospero-win tools/build_wow64native.sh into native/; the PRX by prx-ps4.sh.
# The PRX pin moved from 1e93fca7... on 2026-11-05 when create-fself started
# going through scripts/create-fself-repro.sh. The code is unchanged (its
# loaded sections are identical); only the fself's digests of .comment/.debug_*
# and the embedded -in path changed, which made CI builds differ from local ones.
WOW64NATIVE_ABI4_SHA256=e531a51bb19ae4f92e65556f0f6d4f89e930b9c7490d8a02988feb1d5ee9c044
WOW64NATIVE_ABI4_PRX_SHA256=20eee436ae5856f06d39b9f9fa57720806612f15e1ebea4ab15b4638da5b729d

# mesa-zink/ holds the artifacts of prospero-win tools/build_mesa_zink.sh (pinned
# Mesa + llvm-mingw): the WGL/Zink OpenGL provider for graphics = opengl games.
# PW_HOST_WINE: the host Wine work directory (build/, install/) for the PE side;
# default the synced tree. A tree built by prospero-win tools/build_host_wine.sh
# from the patch series alone can be named here instead.
HOST_WINE=${PW_HOST_WINE:-$PW/.deps/wine-host}
export PW_HOST_WINE=$HOST_WINE
for p in "$HOST_WINE/build" "$HOST_WINE/install/usr/lib/wine" \
         "$PW/.deps/wine-ps5/build" "$WOW64NATIVE_DLL" "$BASELINE/eboot.bin" \
         "$MESA_ZINK/i386-windows/opengl32.dll" "$MESA_ZINK/x86_64-windows/opengl32.dll" \
         "$PW/.deps/wine-runtime/nls/locale.nls" "$PW/.deps/wine-runtime/nls/l_intl.nls" \
         "$HOST_WINE/install/usr/lib/wine/x86_64-windows/wowprospero.dll"; do
  # wine-runtime/nls: prospero-win tools/build_wine_runtime.sh. wowprospero.dll:
  # tools/build_wowprospero.sh, stripped into the host install. build-app-ps4.sh
  # stages both and refuses the package without them, after every PRX is linked.
  [[ -e $p ]] || { echo "missing ABI-v4 build input: $p" >&2; exit 1; }
done
mkdir -p "$OUT"
log() { printf '\n== %s\n' "$*"; }

log "32-bit kernelbase.dll with the PW_EXCEPTION32 guest-fault diagnostics"
# Apply the narrow Conviction hook to the checked patch-series source used by
# the ABI-v4 cache. Keep the cached source clean after building so the next
# package run still passes the patch-series/source identity gate.
KERNELBASE_SOURCE="$HOST_WINE/source/dlls/kernelbase/main.c"
CONVICTION_PATCH="$ROOT/src/wine-patches-ps4/conviction-loading-tier-abi4.patch"
conviction_patch_applied=0
cleanup_conviction_patch() {
  if [[ $conviction_patch_applied == 1 ]]; then
    git -C "$HOST_WINE/source" apply --reverse "$CONVICTION_PATCH" || \
      echo "warning: could not revert the temporary Conviction kernelbase source patch" >&2
  fi
}
trap cleanup_conviction_patch EXIT
if ! grep -Fq 'init_conviction_loading_tier' "$KERNELBASE_SOURCE"; then
  git -C "$HOST_WINE/source" apply --check "$CONVICTION_PATCH"
  git -C "$HOST_WINE/source" apply "$CONVICTION_PATCH"
  conviction_patch_applied=1
fi
# Wine can retain objects across source-pin changes, so force main.c to compile
# before linking the staged PE DLL.
rm -f "$HOST_WINE/build/dlls/kernelbase/i386-windows/main.o"
make -C "$HOST_WINE/build" -j4 dlls/kernelbase/i386-windows/kernelbase.dll
strings "$HOST_WINE/build/dlls/kernelbase/i386-windows/kernelbase.dll" |
  grep -Fq 'loading-only CPU tier hook installed' || {
    echo "kernelbase.dll is missing the Conviction loading-tier source marker" >&2
    exit 1
  }
mkdir -p "$OUT/pe"
( cd "$HOST_WINE/build" && tools/install -m 644 -s \
    --strip-program="tools/winebuild/winebuild --builtin --strip-cmd=i686-w64-mingw32-strip" \
    -t "$OUT/pe" dlls/kernelbase/i386-windows/kernelbase.dll )

log "Unix PRXs, PS4 RADV, FreeType, wineps5"
# prx-ps4.sh and radv-prx-ps4.sh set PW_SHARED_LIBC for the modules themselves.
PW_ROOT=$PW sh "$ROOT/scripts/prx-ps4.sh"
# RADV must link the SDK bundle's orbis-compat archive. The compiler wrapper
# reads the archive staged under its historical filename, so swap the bundle
# archive in just for this link and restore the pinned archive immediately.
(
  set -euo pipefail
  staged_compat="$ROOT/build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a"
  bundle_compat="$ROOT/sdk/orbis-sdk-v1/orbis-compat/build/liborbis-compat.a"
  compat_backup="$OUT/orbis-compat-pin-backup.a"
  [[ -f $staged_compat && -f $bundle_compat ]] || {
    echo "missing staged or bundle orbis-compat archive for RADV" >&2; exit 1;
  }
  cp "$staged_compat" "$compat_backup"
  restore_compat() { cp "$compat_backup" "$staged_compat"; rm -f "$compat_backup"; }
  trap restore_compat EXIT
  cp "$bundle_compat" "$staged_compat"
  PW_ROOT=$PW \
  PW_RADV_MESA_SRC="${PW_RADV_MESA_SRC:-$ROOT/mesa-build/mesa-ps4}" \
  PW_RADV_MESA_BUILD="${PW_RADV_MESA_BUILD:-${PW_RADV_MESA_SRC:-$ROOT/mesa-build/mesa-ps4}/build-orbis}" \
    sh "$ROOT/scripts/radv-prx-ps4.sh"
)
PW_ROOT=$PW sh "$ROOT/scripts/freetype-prx-ps4.sh"
PW_ROOT=$PW sh "$ROOT/scripts/wineps5-prx-ps4.sh"

# source-build refreshes Wine and relinks every PRX, but packages the validated
# ABI-v4 wow64native.dll from the shared cache. Keep its Unix companion from the
# same validated build as well; a freshly relinked PRX is not interchangeable
# with that PE even when the source code is unchanged (the pair is hash-pinned
# below by build-app-ps4.sh).
if [[ -n ${WOW64NATIVE_PRX_OVERRIDE:-} ]]; then
  cached_native_prx=$WOW64NATIVE_PRX_OVERRIDE
  cached_native_elf=${WOW64NATIVE_SHARED_ELF_OVERRIDE:-${cached_native_prx%.prx}.shared.elf}
  [[ -f $cached_native_prx ]] || {
    echo "missing validated ABI-v4 wow64native PRX: $cached_native_prx" >&2; exit 1;
  }
  [[ -f $cached_native_elf ]] || {
    echo "missing matching ABI-v4 wow64native shared ELF: $cached_native_elf" >&2; exit 1;
  }
  cached_native_hash=$(sha256sum "$cached_native_prx" | cut -d' ' -f1)
  [[ $cached_native_hash == "$WOW64NATIVE_ABI4_PRX_SHA256" ]] || {
    echo "cached ABI-v4 wow64native PRX has unexpected SHA-256: $cached_native_hash" >&2
    echo "expected: $WOW64NATIVE_ABI4_PRX_SHA256" >&2
    exit 1
  }
  cp "$cached_native_prx" "$PW/.deps/wine-ps5/prx/sce_module/wow64native.prx"
  cp "$cached_native_elf" "$PW/.deps/wine-ps5/prx/wow64native.shared.elf"
  echo "restored hash-matched ABI-v4 wow64native PE/PRX pair from validated cache"
fi

log "relocatable package: no-RELRO stub eboot + high-address app PRX"
# ⚠ Do NOT export PW_SHARED_LIBC here. The validated eboot stub and app PRX link
# libc statically; PW_SHARED_LIBC=1 produced a 39,840-byte stub and an 812 KB
# app PRX that differ from every hardware-tested build (2026-11-05).
env -u PW_SHARED_LIBC \
  TITLE_ID="$TITLE_ID" TITLE="$TITLE" PKG_VERSION="$PKG_VERSION" PW_ROOT="$PW" \
  WOW64NATIVE_ABI=4 WOW64NATIVE_DLL="$WOW64NATIVE_DLL" \
  WOW64NATIVE_ABI4_SHA256=$WOW64NATIVE_ABI4_SHA256 \
  WOW64NATIVE_ABI4_PRX_SHA256=$WOW64NATIVE_ABI4_PRX_SHA256 \
  PS4_KERNELBASE32_DLL="$OUT/pe/kernelbase.dll" \
  PW_MESA_ZINK_DIR="$MESA_ZINK" \
  PKG_OUT="$OUT/app" PKG_BASE_OUT="$OUT/base" \
  PW_BUILD_ROOT="$OUT/build" PW_APP_OBJ="$OUT/app-obj" \
  bash "$ROOT/scripts/build-relocatable-wine-ps4.sh"
STAGE=$OUT/app/pkg-stage
PKG=$(find "$OUT/app" -maxdepth 1 -type f -name '*.pkg' -print -quit)
rm -rf "$OUT/base"     # intermediate non-relocatable package; never install it

log "parity gates against the known-good baseline"
python3 -I "$ROOT/scripts/check-ps4-package-parity.py" "$BASELINE" "$STAGE" \
  --elf-dir "$PW/.deps/wine-ps5/prx" --upstream-root "$PW" | tee "$OUT/parity.txt"

log "package hash and signature validation"
LD_LIBRARY_PATH=$OPENSSL_LIB DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
DOTNET_BUNDLE_EXTRACT_BASE_DIR=${DOTNET_BUNDLE_EXTRACT_BASE_DIR:-$OUT/dotnet-extract} \
  "$SDKBIN/PkgTool.Core" pkg_validate "$PKG" | tee "$OUT/pkg_validate.txt"
if grep -qvE '^(\[OK\]|$)' "$OUT/pkg_validate.txt"; then
  echo "pkg_validate reported a non-OK line" >&2; exit 1
fi

log "provenance"
{
  echo "package=$(basename "$PKG")"
  echo "package_sha256=$(sha256sum "$PKG" | cut -d' ' -f1)"
  echo "title_id=$TITLE_ID app_ver=$PKG_VERSION title=$TITLE"
  echo "root_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "prospero_win_abi4_commit=$(git -C "$PW" rev-parse HEAD)"
  echo "prospero_win_abi4_diff_sha256=$(git -C "$PW" diff --binary | sha256sum | cut -d' ' -f1)"
  echo "host_wine=$HOST_WINE"
  echo "mesa_commit=$(git -C "$ROOT/mesa-build/mesa-ps4" rev-parse HEAD)"
  # No dev.conf, no app log (see build-app-ps4.sh). Record which way it went.
  if [[ -f $STAGE/dev.conf ]]; then
    echo "app_log=$(sed -n 's/^DEV_SERVER=//p' "$STAGE/dev.conf"):$(sed -n 's/^DEV_PORT=//p' "$STAGE/dev.conf")"
  else
    echo "app_log=none (no /app0/dev.conf)"
  fi
  for f in eboot.bin sce_module/relocated_wine_app.prx sce_module/ntdll.prx sce_module/win32u.prx \
           sce_module/wineserver.prx sce_module/libvulkan.prx sce_module/wow64native.prx \
           win/wine/lib/wine/x86_64-windows/wow64native.dll win/wine/lib/wine/i386-windows/kernelbase.dll; do
    echo "sha256 $(sha256sum "$STAGE/$f" | cut -d' ' -f1) $f"
  done
} > "$OUT/BUILD-MANIFEST.txt"
cat "$OUT/BUILD-MANIFEST.txt"
echo "pkg: $PKG"
