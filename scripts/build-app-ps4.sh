#!/usr/bin/env bash
# Build the prospero-win title itself for PS4: the launcher and DBT from src/,
# the portable half of native/, this port's platform layer, linked against the
# Wine PRX modules that scripts/prx-ps4.sh produces.
#
# Upstream builds this with tools/build_native.sh against
# .deps/ps5-native-app-boilerplate, which is PS5-only; this is the PS4
# equivalent, using our own eboot + .pkg pipeline.
#
# ⚠ Run scripts/prx-ps4.sh first: the title links against prx/stubs/ntdll.so and
# the package carries the eight modules in sce_module/.
set -euo pipefail
# Resolve libc from the shared module so the title and every PRX share one
# environ and one TLS regime (docs/FINDINGS.md). Unset to go back to static.
: "${PW_SHARED_LIBC:=1}"; export PW_SHARED_LIBC
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PW=${PW_ROOT:-$ROOT/prospero-win}
BUNDLE=$ROOT/sdk/orbis-sdk-v1
CC=$ROOT/build/ps4-wine-sdk/bin/prospero-clang
PRX=$PW/.deps/wine-ps5/prx
OBJ=${PW_APP_OBJ:-$ROOT/build/wine-app/obj}
MODULE_STUBS_DIR=${PW_MODULE_STUBS_DIR:-$ROOT/sce_module}
# Environment overrides let a comparison build use a distinct install identity
# and output directory without changing the default deployable Neo package.
TITLE_ID="${TITLE_ID:-GLDS10005}"
TITLE="${TITLE:-Prospero Wine}"
PW_WINE64_WAIT_WATCHDOG="${PW_WINE64_WAIT_WATCHDOG:-0}"
PW_WINE64_SERVER_DIRECT_OFF="${PW_WINE64_SERVER_DIRECT_OFF:-0}"
PW_WINE64_HEAP_FLEXIBLE="${PW_WINE64_HEAP_FLEXIBLE:-0}"
export OO_PS4_TOOLCHAIN=$BUNDLE/sdk
PKG=0; NEO=0; LOW_BASE=0; RELOC_STAGE=0
for a in "$@"; do
  case $a in
    --pkg) PKG=1 ;;
    --neo) NEO=1 ;;
    --non-relocatable) LOW_BASE=1 ;;
    --relocatable-stage) RELOC_STAGE=1 ;;
  esac
done
say(){ printf '== %s\n' "$*"; }

# All installable Wine packages use the high-address PRX + low-address handoff
# by default. Oblivion's non-relocatable PE32 image occupies 0x400000, which
# collides with the ordinary eboot. Keep the old layout only for an explicit
# diagnostic build; the relocatable script calls this file with the private
# --relocatable-stage flag to assemble its base payload.
if (( PKG && !LOW_BASE && !RELOC_STAGE )); then
  OUT="${PKG_OUT:-$ROOT/pkgout/wine-app}"
  BASE_OUT="${PKG_BASE_OUT:-$ROOT/pkgout/wine-app-relocatable-base}"
  args=()
  (( NEO )) && args+=(--neo)
  exec env \
    TITLE_ID="$TITLE_ID" TITLE="$TITLE" PKG_OUT="$OUT" PKG_BASE_OUT="$BASE_OUT" \
    PW_ROOT="$PW" PW_APP_OBJ="$OBJ" \
    PW_WINE64_WAIT_WATCHDOG="$PW_WINE64_WAIT_WATCHDOG" \
    PW_WINE64_SERVER_DIRECT_OFF="$PW_WINE64_SERVER_DIRECT_OFF" \
    PW_WINE64_HEAP_FLEXIBLE="$PW_WINE64_HEAP_FLEXIBLE" \
    PS4_KERNELBASE32_DLL="${PS4_KERNELBASE32_DLL:-}" \
    PS4_IPHLPAPI32_DLL="${PS4_IPHLPAPI32_DLL:-}" \
    PS4_NTDLL32_DLL="${PS4_NTDLL32_DLL:-}" \
    "$ROOT/scripts/build-relocatable-wine-ps4.sh" "${args[@]}"
fi

rm -rf "$OBJ"; mkdir -p "$OBJ"
INC="-I$PW -I$PW/include -I$PW/src -I$PW/native -I$ROOT/src/native"
# ⚠ ps5log is a single-header library whose network backend is chosen by what
# is included BEFORE it (ps5log.h guards every hook with #ifndef). Nothing in
# the title includes ps5log_ps5_net.h, so it compiled against POSIX
# socket/connect/fcntl -- which on Orbis are not sceNet, so the channel opened
# a socket that could never connect and then disabled itself in silence.
# Measured 2026-10-07: ps5log.o imported plain socket/connect/fcntl.
# Force-include the sceNet adapters so the hooks resolve to sceNet* instead.
PS5LOG_NET="-include $PW/native/ps5log/ps5log_ps5_net.h"
case "$PW_WINE64_WAIT_WATCHDOG" in
  0|1) ;;
  *) echo "PW_WINE64_WAIT_WATCHDOG must be 0 or 1" >&2; exit 2 ;;
esac
case "$PW_WINE64_SERVER_DIRECT_OFF" in
  0|1) ;;
  *) echo "PW_WINE64_SERVER_DIRECT_OFF must be 0 or 1" >&2; exit 2 ;;
esac
case "$PW_WINE64_HEAP_FLEXIBLE" in
  0|1) ;;
  *) echo "PW_WINE64_HEAP_FLEXIBLE must be 0 or 1" >&2; exit 2 ;;
esac
# The release this build belongs to (VERSION: the last published orbis-win
# release, bumped when the next one is cut). The launcher compares it with
# the newest stable release on GitHub and says when a newer one exists.
PW_RELEASE_VERSION="${PW_RELEASE_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null)}"
[[ $PW_RELEASE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "PW_RELEASE_VERSION must be MAJOR.MINOR.PATCH (VERSION file): '$PW_RELEASE_VERSION'" >&2; exit 2;
}
CFL="-std=gnu11 -O2 -fPIC -DPW_RELEASE_VERSION=\"$PW_RELEASE_VERSION\" -DPW_BUILD_ID=\"${PW_BUILD_ID:-unknown-local}\" -DPW_WINE64_WAIT_WATCHDOG=$PW_WINE64_WAIT_WATCHDOG -DPW_WINE64_SERVER_DIRECT_OFF=$PW_WINE64_SERVER_DIRECT_OFF -DPW_WINE64_HEAP_FLEXIBLE=$PW_WINE64_HEAP_FLEXIBLE $INC $PS5LOG_NET"

say "compile: portable core (DBT + launcher) and the portable half of native/"
for f in "$PW"/src/*.c "$PW"/native/wine64_main.c "$PW"/native/pw_data_mount.c \
         "$PW"/native/pw_diagnostics.c "$PW"/native/pw_wine_display.c \
         "$PW"/native/pw_wine_library.c "$PW"/native/pw_wine_prefix.c \
         "$PW"/native/pw_osk_ps5.c "$PW"/native/pw_update_ps4.c "$PW"/native/ps5log/*.c; do
  [ -f "$f" ] || continue
  $CC $CFL -c "$f" -o "$OBJ/$(echo "${f#$PW/}" | tr '/' '_' | sed 's/\.c$/.o/')"
done

say "compile: upstream platform cores, PS5 vtables guarded out"
$CC $CFL -DPW_PAD_PS5_HOST_TEST   -c "$PW/native/pw_pad_ps5.c"   -o "$OBJ/core_pad.o"
$CC $CFL -DPW_AUDIO_PS5_HOST_TEST -c "$PW/native/pw_audio_ps5.c" -o "$OBJ/core_audio.o"
$CC $CFL -DPW_HID_PS5_HOST_TEST   -c "$PW/native/pw_hid_ps5.c"   -o "$OBJ/core_hid.o"
# Those builds keep platform_ops as a stub returning PW_ERR_UNSUPPORTED, so the
# symbol still exists and would collide. Rename it aside and let the binding
# file below supply the real vtable.
llvm-objcopy --redefine-sym pw_pad_ps5_platform_ops=pw_pad_ps5_platform_ops_unused     "$OBJ/core_pad.o"
llvm-objcopy --redefine-sym pw_audio_ps5_platform_ops=pw_audio_ps5_platform_ops_unused "$OBJ/core_audio.o"

# The PRX loader belongs to the TITLE, not to a module: it is what loads the
# modules, so it cannot be imported from one.
say "compile: the PRX loader"
$CC $CFL -I"$PW/wine/ps5" -c "$PW/wine/ps5/pw_wine_prx.c" -o "$OBJ/pw_wine_prx.o"

say "compile: this port's platform layer"
# pw_wow_log_ps4.c: the title links prospero-win's DBT sources too, and they
# carry the translator's diagnostics, so it needs the same logger the PRX has.
for f in "$ROOT"/src/native/pw_videoout_ps4.c "$ROOT"/src/native/pw_pad_ps4.c \
         "$ROOT"/src/native/pw_audio_ps4.c "$ROOT"/src/native/pw_platform_bind_ps4.c \
         "$ROOT"/src/native/pw_wow_log_ps4.c "$ROOT"/src/native/pw_osk_ps4.c; do
  $CC $CFL -c "$f" -o "$OBJ/ps4_$(basename "$f" .c).o"
done
$CC $CFL -c "$ROOT/src/native/pw_netctl_ps4.c" -o "$OBJ/ps4_pw_netctl_ps4.o"

say "link"
# ⚠ DO NOT LINK AGAINST ntdll. The title resolves Wine's entry points at RUNTIME
# through its own PRX loader (src/pw_wine_start.c: pw_prx_lookup(descriptor,
# "__wine_main")), so a link-time dependency is wrong in both directions:
#
#   - the console does not auto-load /app0/sce_module/*.prx for a DT_NEEDED on
#     a non-Sony module, so the title died at load with
#     0xa0020101 PRX_NOT_RESOLVED_FUNCTION having loaded none of our nine;
#   - every PRX carries orbis-compat and libc++ whole-archive, so linking the
#     stub silently bound the title's 212 C++ runtime imports (_ZNSt3__1...,
#     _Unwind_*) to ntdll.prx instead of to the SDK's own runtime.
#
# Measured on hardware 2026-10-07. The title must depend on Sony libraries only.
# ⚠ --image-base. The kernel loads this title at 0x400000, which is exactly
# where a 32-bit Windows executable is based -- and one whose relocations are
# stripped, as Oblivion.exe's are, cannot go anywhere else:
#
#   wine: failed to create main module for "C:\Games\Oblivion\Oblivion.exe",
#         status c0000018          (STATUS_CONFLICTING_ADDRESSES)
#
# Nor is the low 2 GiB enough to clear: the executable is LARGE_ADDRESS_AWARE,
# so under WoW64 it may use the whole 4 GiB, and a game that wants any
# particular address there is a game that cannot run. Link above it instead, out
# of 32-bit reach altogether, which costs the guest nothing and frees the lot.
#
# ⚠ NOT YET: the kernel relocates a PIE whatever base the ELF asks for. Built
# at 0x200000000 the title died before its first instruction --
#   SIGSEGV, page fault (user read instruction, page not present)
#   fault address 0x4004790a8 = 0x200000000 + 0x200000000 + 0x400000 + entry
# -- the loader having added its own bias on top of ours. Moving the title needs
# ET_EXEC, not a different base. This build keeps the default PIE layout.
# ⚠ ET_EXEC at 0x200000000, out of the guest's reach.
#
# The kernel loads a PIE at 0x400000, which is where a 32-bit Windows image is
# based -- and one with its relocations stripped, as Oblivion.exe's are, cannot
# go anywhere else:
#     wine: failed to create main module ... status c0000018
#                                               (STATUS_CONFLICTING_ADDRESSES)
# Clearing only the low 2 GiB is not enough either: that executable is
# LARGE_ADDRESS_AWARE and may use the whole 4 GiB under WoW64.
#
# A base in the ELF does not move a PIE -- the loader adds its own bias on top
# and the title died on an unmapped page. The attempted relocation is disabled.
$CC -o "$OBJ/../wine_app.elf" "$OBJ"/*.o \
    -lSceNet -lSceNetCtl -lSceAudioOut -lSceSystemService -lSceSysmodule \
    -lSceGnmDriver -lSceVideoOut -lScePad -lSceUserService
printf '   elf %s\n' "$(du -h "$OBJ/../wine_app.elf" | cut -f1)"

say "eboot"
"$ROOT/scripts/create-fself-repro.sh" "$BUNDLE/sdk/bin/linux/create-fself" -in "$OBJ/../wine_app.elf" \
    -out "$OBJ/../wine_app.oelf" -eboot "$OBJ/../eboot.bin" >/dev/null
printf '   eboot.bin %s\n' "$(du -h "$OBJ/../eboot.bin" | cut -f1)"

if (( PKG )); then
  say "package"
  OUT="${PKG_OUT:-$ROOT/pkgout/wine-app}"; mkdir -p "$OUT"
  EXTRA=()
  for m in libc.prx libSceFios2.prx; do
    [ -f "$MODULE_STUBS_DIR/$m" ] || { echo "missing package module $MODULE_STUBS_DIR/$m" >&2; exit 1; }
    EXTRA+=(--extra "$MODULE_STUBS_DIR/$m:sce_module/$m")
  done
  # ⚠ dev.conf must be in the PACKAGE, at /app0/dev.conf. ps5log reads its
  # destination in main() BEFORE pw_hid_ps5_preload, which wine64_main.c marks
  # as running "before the /data grant changes the title's credentials" -- so
  # /data/homebrew/dev.conf is not yet readable and the title logs nowhere.
  # Measured 2026-10-07: a copy at /data/homebrew alone produced total silence.
  # The file is gitignored; it holds this workstation's address.
  [ -f "$ROOT/build/devconf/dev.conf" ] && EXTRA+=(--extra "$ROOT/build/devconf/dev.conf:dev.conf")

  # ⚠ The Wine modules go to win/wine/lib/wine/x86_64-unix, NOT sce_module.
  # wine64_main.c:64 PW_WINE64_RUNTIME "/win/wine/lib/wine/x86_64-unix", searched
  # under /app0 and the sandbox app0. Measured 2026-10-07: with them in
  # sce_module the title found the library and listed the game, then failed to
  # start it with
  #     runtime not at /app0/win/wine/lib/wine/x86_64-unix
  #     load status=-2147352574 stage=1 module=0x80020002   (ENOENT)
  # sce_module keeps Sony's libc.prx and libSceFios2.prx, which the loader does
  # require there.
  for m in "$PRX"/sce_module/*.prx; do
    case "${m##*/}" in
      libc.prx|libSceFios2.prx|relocated_wine_app.prx) continue ;;
    esac
    EXTRA+=(--extra "$m:win/wine/lib/wine/x86_64-unix/$(basename "$m")")
    # ⚠ AND in sce_module. The title loads ntdll by explicit path, but once Wine
    # is running its own dlopen goes through wine/ps5/pw_wine_dl_libc.c, which
    # searches WINE_PRX_DIR and falls back to "/app0/sce_module". Nothing sets
    # that variable, so server_init_process could not find wineserver.prx and
    # Wine stopped there. Shipping both copies costs ~8 MB and needs no patch.
    EXTRA+=(--extra "$m:sce_module/$(basename "$m")")
  done

  # Wine's NLS data. It resolves the directory relative to the module path --
  #   /app0/win/wine/lib/wine/../../share/wine/nls -> /app0/win/wine/share/wine/nls
  # and without it init_environment reports
  #   err:environ:read_nls_file failed to load .../locale.nls
  NLS=$PW/.deps/wine-runtime/nls
  if [[ ! -f "$NLS/locale.nls" || ! -f "$NLS/l_intl.nls" ]]; then
    echo "   X incomplete Wine NLS runtime at $NLS (requires locale.nls and l_intl.nls)" >&2
    exit 1
  fi
  nls_count=0
  for f in "$NLS"/*.nls; do
    [ -f "$f" ] || continue
    EXTRA+=(--extra "$f:win/wine/share/wine/nls/$(basename "$f")")
    # ⚠ AND beside the modules. ntdll locates the in-process server with
    # dladdr and derives the server's NLS directory as "<that dir>/nls"
    # (patch 0111), which is NOT where Wine itself looks. Two consumers, two
    # paths, same files.
    EXTRA+=(--extra "$f:win/wine/lib/wine/x86_64-unix/nls/$(basename "$f")")
    nls_count=$((nls_count+1))
  done
  (( nls_count > 0 )) || { echo "   X no Wine NLS data files in $NLS" >&2; exit 1; }
  printf '   nls: %s files\n' "$nls_count"
  # Wine's builtin font fallback is shared runtime data, not title/prefix data.
  # Keep the same six Wine TTFs that repaired the empty Fonts directories on
  # the console, once under the app's common runtime so every profile can use
  # them without duplicating them into each game's installer.
  # PW_HOST_WINE names the host Wine work directory (build/, install/) the PE
  # runtime and fonts come from; default the synced tree.
  HOST_WINE=${PW_HOST_WINE:-$PW/.deps/wine-host}
  FONTDIR=$HOST_WINE/install/usr/share/wine/fonts
  if [[ ! -f "$FONTDIR/tahoma.ttf" ]]; then
    echo "   X Wine runtime fonts missing at $FONTDIR (requires tahoma.ttf)" >&2
    exit 1
  fi
  font_count=0
  for f in "$FONTDIR"/*.ttf; do
    [ -f "$f" ] || continue
    EXTRA+=(--extra "$f:win/wine/share/wine/fonts/$(basename "$f")")
    font_count=$((font_count+1))
  done
  (( font_count > 0 )) || { echo "   X no Wine TTF fonts in $FONTDIR" >&2; exit 1; }
  printf '   fonts: %s shared runtime TTFs\n' "$font_count"
  # Wine's PE side: the shared runtime, beside the Unix modules.
  #
  # The Unix side loads some of these by path, before any Windows search path
  # exists. load_ntdll and load_apiset_dll read dll_dir, which ntdll derives by
  # stripping /x86_64-unix off its own directory, so without them Wine stops at
  #
  #   wine: failed to load .../x86_64-unix/ntdll.dll error c0000135
  #
  # Ship the whole set for both architectures, as upstream does, rather than
  # the handful this game happens to reach: Wine needs both these copies and
  # the ones in the prefix's system32, syswow64 and winsxs, and without either
  # kernel32.dll or start.exe fails to load (prospero-win
  # docs/WINE_PS5_BUILD.md). A per-game subset would break the next game.
  #
  # They come debug-stripped from the host build's install tree, which is what
  # keeps this near upstream's 515 MiB rather than the 1.3 GB it builds as.
  PELIB=$HOST_WINE/install/usr/lib/wine
  # A PS4 diagnostic build can override the host-built 32-bit ntdll PE. Keep
  # this opt-in so normal packages continue using the pinned host runtime.
  PS4_NTDLL32_DLL="${PS4_NTDLL32_DLL:-}"
  if [[ -n "$PS4_NTDLL32_DLL" && ! -f "$PS4_NTDLL32_DLL" ]]; then
    echo "   X PS4_NTDLL32_DLL does not exist: $PS4_NTDLL32_DLL" >&2
    exit 1
  fi
  # Optional i386 Wine build containing bounded fault-time exception context.
  PS4_KERNELBASE32_DLL="${PS4_KERNELBASE32_DLL:-}"
  if [[ -n "$PS4_KERNELBASE32_DLL" && ! -f "$PS4_KERNELBASE32_DLL" ]]; then
    echo "   X PS4_KERNELBASE32_DLL does not exist: $PS4_KERNELBASE32_DLL" >&2
    exit 1
  fi
  # Optional PS4 i386 iphlpapi build. The pinned host Wine PE set does not
  # contain the PS4 NSI fallback, so diagnostics or PS4 adapter behavior must
  # be selected explicitly for packages that need it.
  PS4_IPHLPAPI32_DLL="${PS4_IPHLPAPI32_DLL:-}"
  if [[ -n "$PS4_IPHLPAPI32_DLL" && ! -f "$PS4_IPHLPAPI32_DLL" ]]; then
    echo "   X PS4_IPHLPAPI32_DLL does not exist: $PS4_IPHLPAPI32_DLL" >&2
    exit 1
  fi
  # Native WoW64 PE and Unix companion ABIs must match. Keep ABI v3 as the
  # existing default; an explicit ABI v4 comparison may select the synced
  # companion built from the same source tree as its PS4 PRX.
  PW_SKIP_NATIVE="${PW_SKIP_NATIVE:-0}"
  if [[ $PW_SKIP_NATIVE != 1 ]]; then
    WOW64NATIVE_ABI="${WOW64NATIVE_ABI:-3}"
    case $WOW64NATIVE_ABI in
      3)
        WOW64NATIVE_DLL="${WOW64NATIVE_DLL:-$ROOT/build/orbw00053-iret-selectors-wow64native/x86_64-windows/wow64native.dll}"
        WOW64NATIVE_SHA256="${WOW64NATIVE_ABI3_SHA256:-d7029105cae5d9ba7eecb16b33b02fff8d4c0d7dba7801ab4cd817053a88ce36}"
        WOW64NATIVE_PRX_SHA256="${WOW64NATIVE_ABI3_PRX_SHA256:-e486fc5d126baa4d87fb3921dadf70b437952279ca66d3c1e7d8449ebaf5a506}"
        ;;
      4)
        WOW64NATIVE_DLL="${WOW64NATIVE_DLL:-$PW/.deps/wine-ps5/pe/x86_64-windows/wow64native.dll}"
        WOW64NATIVE_SHA256="${WOW64NATIVE_ABI4_SHA256:-79ca58203273010701a7d6c6d74a12c08e95c2877f2a0b763287dc9f869f6502}"
        WOW64NATIVE_PRX_SHA256="${WOW64NATIVE_ABI4_PRX_SHA256:-af747c960c6fde21b59d4e38962adb44fae162bb060b1b1601ab6cb1a1bcd97f}"
        ;;
      *) echo "   X unsupported WOW64NATIVE_ABI=$WOW64NATIVE_ABI (expected 3 or 4)" >&2; exit 1 ;;
    esac
    if [[ ! -f "$WOW64NATIVE_DLL" ]]; then
      echo "   X required PS4 ABI-v$WOW64NATIVE_ABI wow64native.dll does not exist: $WOW64NATIVE_DLL" >&2
      exit 1
    fi
    wow64native_sha256=$(sha256sum "$WOW64NATIVE_DLL" | cut -d ' ' -f 1)
    if [[ $wow64native_sha256 != "$WOW64NATIVE_SHA256" ]]; then
      echo "   X refusing non-matching wow64native.dll: $WOW64NATIVE_DLL" >&2
      echo "     expected ABI-v$WOW64NATIVE_ABI SHA-256 $WOW64NATIVE_SHA256" >&2
      echo "     got                      $wow64native_sha256" >&2
      exit 1
    fi
    wow64native_prx="$PRX/sce_module/wow64native.prx"
    if [[ ! -f "$wow64native_prx" ]]; then
      echo "   X required ABI-v$WOW64NATIVE_ABI wow64native.prx does not exist: $wow64native_prx" >&2
      exit 1
    fi
    wow64native_prx_sha256=$(sha256sum "$wow64native_prx" | cut -d ' ' -f 1)
    if [[ $wow64native_prx_sha256 != "$WOW64NATIVE_PRX_SHA256" ]]; then
      echo "   X refusing mismatched wow64native PE/PRX pair for ABI-v$WOW64NATIVE_ABI" >&2
      echo "     expected PRX SHA-256 $WOW64NATIVE_PRX_SHA256" >&2
      echo "     got                 $wow64native_prx_sha256 ($wow64native_prx)" >&2
      exit 1
    fi
  fi
  # The WoW64 CPU backend's PE side is not part of Wine: prx-ps4.sh builds only
  # its Unix half. Without the PE half Wine builds a builtin module out of the
  # PRX alone, finds no DllMain in it, and stops with
  #     err:wow:load_64bit_module failed to load dll c0000142
  if [ ! -f "$PELIB/x86_64-windows/wowprospero.dll" ]; then
    echo "   X no wowprospero.dll in the PE runtime" >&2
    echo "     sh prospero-win/tools/build_wowprospero.sh --build .deps/wine-host/build --source .deps/wine-host/source" >&2
    echo "     then strip it and copy it into $PELIB/x86_64-windows/" >&2
    exit 1
  fi
  for arch in i386-windows x86_64-windows; do
    if [ ! -d "$PELIB/$arch" ]; then
      echo "   ✗ no PE runtime at $PELIB/$arch" >&2
      echo "     run: make -C .deps/wine-host/build install DESTDIR=.deps/wine-host/install" >&2
      exit 1
    fi
    # Everything but the import libraries. Wine's install leaves lib*.a here
    # for building against -- 509 archives, 1.3 GB, four times the modules
    # themselves -- and nothing on the console links against them.
    n=0
    for f in "$PELIB/$arch"/*; do
      [ -f "$f" ] || continue
      case $f in *.a) continue ;; esac
      dest_basename=${f##*/}
      if [[ -n "$PS4_NTDLL32_DLL" && $arch == i386-windows && ${f##*/} == ntdll.dll ]]; then
        f=$PS4_NTDLL32_DLL
      fi
      if [[ -n "$PS4_KERNELBASE32_DLL" && $arch == i386-windows && ${f##*/} == kernelbase.dll ]]; then
        f=$PS4_KERNELBASE32_DLL
        dest_basename=kernelbase.dll
      fi
      if [[ -n "$PS4_IPHLPAPI32_DLL" && $arch == i386-windows && ${f##*/} == iphlpapi.dll ]]; then
        f=$PS4_IPHLPAPI32_DLL
        dest_basename=iphlpapi.dll
      fi
      if [[ $arch == x86_64-windows && ${f##*/} == wow64native.dll ]]; then
        # Package only the explicitly selected ABI-matched PS4 override below.
        continue
      fi
      EXTRA+=(--extra "$f:win/wine/lib/wine/$arch/$dest_basename")
      n=$((n+1))
    done
    printf '   pe %s: %s modules\n' "$arch" "$n"
  done
  # OpenGL (graphics = opengl): the launcher copies Mesa's WGL/Zink provider
  # from win/mesa-zink/<arch>/ into the game's prefix and refuses the game when
  # it is absent (Half-Life, 2026-11-05: no PS4 package had ever carried it).
  # PW_MESA_ZINK_DIR is the artifacts directory of prospero-win's
  # tools/build_mesa_zink.sh: <arch>/{opengl32,libgallium_wgl,...}.dll + LICENSES.
  PW_MESA_ZINK_DIR="${PW_MESA_ZINK_DIR:-}"
  if [[ -n $PW_MESA_ZINK_DIR ]]; then
    for arch in i386-windows x86_64-windows; do
      for core in opengl32.dll libgallium_wgl.dll; do
        [[ -f $PW_MESA_ZINK_DIR/$arch/$core ]] || {
          echo "   X PW_MESA_ZINK_DIR lacks $arch/$core: $PW_MESA_ZINK_DIR" >&2; exit 1;
        }
      done
      for f in "$PW_MESA_ZINK_DIR/$arch"/*.dll; do
        EXTRA+=(--extra "$f:win/mesa-zink/$arch/$(basename "$f")")
      done
    done
    while IFS= read -r -d '' f; do
      EXTRA+=(--extra "$f:win/mesa-zink/${f#"$PW_MESA_ZINK_DIR"/}")
    done < <(find "$PW_MESA_ZINK_DIR/LICENSES" -type f -print0 2>/dev/null)
    printf '   Mesa Zink OpenGL provider: %s\n' "$PW_MESA_ZINK_DIR"
  fi
  if [[ $PW_SKIP_NATIVE != 1 ]]; then
    EXTRA+=(--extra "$WOW64NATIVE_DLL:win/wine/lib/wine/x86_64-windows/wow64native.dll")
    printf '   wow64native ABI-v%s PE: %s (%s)\n' "$WOW64NATIVE_ABI" "$WOW64NATIVE_DLL" "$wow64native_sha256"
  else
    printf '   native WoW64 disabled: omitting wow64native.dll and PRX\n'
  fi
  printf '   modules: %s\n' "$(ls "$PRX"/sce_module/ | tr '\n' ' ')"
  "$BUNDLE/orbis-compat/scripts/ps4/make-pkg.sh" --eboot "$OBJ/../eboot.bin" --out-dir "$OUT" \
      --title-id "$TITLE_ID" --title "$TITLE" "${EXTRA[@]}"
  for m in libc.prx libSceFios2.prx; do
    if [[ ! -f "$OUT/pkg-stage/sce_module/$m" ]] || ! cmp -s "$MODULE_STUBS_DIR/$m" "$OUT/pkg-stage/sce_module/$m"; then
      echo "   X staged $m does not match selected package stub: $MODULE_STUBS_DIR/$m" >&2
      exit 1
    fi
  done
  if [[ $PW_SKIP_NATIVE != 1 ]]; then
    staged_wow64native="$OUT/pkg-stage/win/wine/lib/wine/x86_64-windows/wow64native.dll"
    if [[ ! -f "$staged_wow64native" ]] || ! cmp -s "$WOW64NATIVE_DLL" "$staged_wow64native"; then
      echo "   X staged wow64native.dll does not match the selected PS4 ABI-v$WOW64NATIVE_ABI DLL" >&2
      exit 1
    fi
    for staged_prx in "$OUT/pkg-stage/sce_module/wow64native.prx" \
                      "$OUT/pkg-stage/win/wine/lib/wine/x86_64-unix/wow64native.prx"; do
      if [[ ! -f "$staged_prx" ]] || ! cmp -s "$wow64native_prx" "$staged_prx"; then
        echo "   X staged wow64native PRX does not match the selected ABI-v$WOW64NATIVE_ABI pair: $staged_prx" >&2
        exit 1
      fi
    done
  elif [[ -e "$OUT/pkg-stage/win/wine/lib/wine/x86_64-windows/wow64native.dll" || -e "$OUT/pkg-stage/sce_module/wow64native.prx" ]]; then
    echo "   X native WoW64 file leaked into translator-only package stage" >&2
    exit 1
  fi
  (( NEO )) && "$ROOT/scripts/set-neo.sh" "$OUT"
  ls -la "$OUT"/*.pkg | sed 's/^/   /'
fi
