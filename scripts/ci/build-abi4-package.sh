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
#                         with .deps/wine-host), build/wine-ps5/, native/.
#                         Its generated makefiles embed this absolute path; the
#                         runner symlinks it to the cache (prepare-runner.sh).
#   OUT                   output directory (required)
#   TITLE_ID, TITLE, PKG_VERSION
#   PS4_BASELINE_STAGE    known-good stage the parity check compares against
#   PS4_PKGTOOL_OPENSSL_LIB  directory holding libssl.so.1.1 for PkgTool.Core
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ABI4=${PW_ABI4_ROOT:-/home/zpeirce/codex_scratch/abi4-upstream-port-20261104}
PW=$ABI4/source
OUT=${OUT:?set OUT to the output directory}
TITLE_ID=${TITLE_ID:-GLDS10043}
TITLE=${TITLE:-Orbis Wine ABI-v4}
PKG_VERSION=${PKG_VERSION:-01.00}
BASELINE=${PS4_BASELINE_STAGE:-$ROOT/pkgout/falloutnv-no-relro-kept-data-1090/pkg-stage}
OPENSSL_LIB=${PS4_PKGTOOL_OPENSSL_LIB:-$HOME/.cache/orbis-ports/openssl11/lib}
SDKBIN=$ROOT/sdk/orbis-sdk-v1/sdk/bin/linux

# The matched ABI-v4 native WoW64 pair that 01.06 shipped. The PE side is built
# by prospero-win tools/build_wow64native.sh into native/; the PRX by prx-ps4.sh.
# The PRX pin moved from 1e93fca7... on 2026-11-05 when create-fself started
# going through scripts/create-fself-repro.sh. The code is unchanged (its
# loaded sections are identical); only the fself's digests of .comment/.debug_*
# and the embedded -in path changed, which made CI builds differ from local ones.
WOW64NATIVE_DLL=$ABI4/native/x86_64-windows/wow64native.dll
WOW64NATIVE_ABI4_SHA256=e531a51bb19ae4f92e65556f0f6d4f89e930b9c7490d8a02988feb1d5ee9c044
WOW64NATIVE_ABI4_PRX_SHA256=20eee436ae5856f06d39b9f9fa57720806612f15e1ebea4ab15b4638da5b729d

# mesa-zink/ holds the artifacts of prospero-win tools/build_mesa_zink.sh (pinned
# Mesa + llvm-mingw): the WGL/Zink OpenGL provider for graphics = opengl games.
for p in "$PW/.deps/wine-host/build" "$PW/.deps/wine-host/install/usr/lib/wine" \
         "$PW/.deps/wine-ps5/build" "$WOW64NATIVE_DLL" "$BASELINE/eboot.bin" \
         "$ABI4/mesa-zink/i386-windows/opengl32.dll" "$ABI4/mesa-zink/x86_64-windows/opengl32.dll"; do
  [[ -e $p ]] || { echo "missing ABI-v4 build input: $p" >&2; exit 1; }
done
mkdir -p "$OUT"
log() { printf '\n== %s\n' "$*"; }

log "32-bit kernelbase.dll with the PW_EXCEPTION32 guest-fault diagnostics"
# The wine-host tree carries series 1037-1043 (archive 0962-0965, 0973, 1013 and
# the 1007 fault-page record). Strip exactly as `make install` does.
make -C "$PW/.deps/wine-host/build" -j4 dlls/kernelbase/i386-windows/kernelbase.dll
mkdir -p "$OUT/pe"
( cd "$PW/.deps/wine-host/build" && tools/install -m 644 -s \
    --strip-program="tools/winebuild/winebuild --builtin --strip-cmd=i686-w64-mingw32-strip" \
    -t "$OUT/pe" dlls/kernelbase/i386-windows/kernelbase.dll )

log "Unix PRXs, PS4 RADV, FreeType, wineps5"
# prx-ps4.sh and radv-prx-ps4.sh set PW_SHARED_LIBC for the modules themselves.
PW_ROOT=$PW sh "$ROOT/scripts/prx-ps4.sh"
PW_ROOT=$PW sh "$ROOT/scripts/radv-prx-ps4.sh"
PW_ROOT=$PW sh "$ROOT/scripts/freetype-prx-ps4.sh"
PW_ROOT=$PW sh "$ROOT/scripts/wineps5-prx-ps4.sh"

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
  PW_MESA_ZINK_DIR="$ABI4/mesa-zink" \
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
if grep -v '^\[OK\]' "$OUT/pkg_validate.txt" | grep -q .; then
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
  echo "mesa_commit=$(git -C "$ROOT/mesa-build/mesa-ps4" rev-parse HEAD)"
  for f in eboot.bin sce_module/relocated_wine_app.prx sce_module/ntdll.prx sce_module/win32u.prx \
           sce_module/wineserver.prx sce_module/libvulkan.prx sce_module/wow64native.prx \
           win/wine/lib/wine/x86_64-windows/wow64native.dll win/wine/lib/wine/i386-windows/kernelbase.dll; do
    echo "sha256 $(sha256sum "$STAGE/$f" | cut -d' ' -f1) $f"
  done
} > "$OUT/BUILD-MANIFEST.txt"
cat "$OUT/BUILD-MANIFEST.txt"
echo "pkg: $PKG"
