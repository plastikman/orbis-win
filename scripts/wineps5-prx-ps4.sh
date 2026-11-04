#!/bin/sh
# Build wineps5.prx for PS4: the audio driver mmdevapi loads by name.
#
# GTA IV refuses to start without one -- "GTA IV requires a soundcard in order
# to run", its own dialog, once there were fonts to read it with. Patch 0120
# already points HKCU\Software\Wine\Drivers\Audio at "ps5", so Wine asks for
# this driver on every run and has been answered with
#
#     pw_wine_dl: cannot open .../wineps5.so ... not found
#     err:mmdevapi:init_driver ...
#
# since the beginning: prx-ps4.sh builds nine modules and this was never one of
# them.
#
# Upstream's build_wine_ps5.sh compiles the same two units and finishes with
# ps5-native-tool, which does not exist for this console. This is the PS4 arm,
# linking with create-fself exactly as prx-ps4.sh does for the others.
set -eu
# Share the title's libc, as every other PRX here does; see prx-ps4.sh.
: "${PW_SHARED_LIBC:=1}"; export PW_SHARED_LIBC
# ⚠ PW_PRX_LINK=1 keeps libwineshim.a off the line (src/toolchain/prospero-clang
# :108). That archive carries this port's stand-ins for the wine/ps5 units, so
# with it present the linker answers pw_wine_dl_open out of it and the module
# gets a registry of its own -- empty, and dlsym then finds nothing. prx-ps4.sh
# sets this for every module it builds, which is why win32u shows
# "U pw_wine_dl_open" and this did not.
PW_PRX_LINK=1; export PW_PRX_LINK
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
bundle=$root/sdk/orbis-sdk-v1
oo=$bundle/sdk
sdk=$root/build/ps4-wine-sdk
pw=${PW_ROOT:-$root/prospero-win}
work=$pw/.deps/wine-ps5
tree=$work/source
build=$work/build
prx=$work/prx
CC=$sdk/bin/prospero-clang
export OO_PS4_TOOLCHAIN=$oo

mkdir -p "$prx/obj" "$prx/sce_module"
log=$prx/wineps5.link.log

echo "== 1. mmdevapi's headers =="
# The driver speaks mmdevapi's interfaces, which are IDL. The ELF build only
# generated what ntdll, win32u and the server include, so ask for the rest.
make -C "$build" include/audioclient.h include/mmdeviceapi.h include/devicetopology.h \
    include/propsys.h include/propidl.h include/objidl.h include/objidlbase.h \
    include/unknwn.h include/wtypes.h include/oaidl.h >> "$work/make.log" 2>&1 ||
    { echo "   X cannot generate mmdevapi's headers; see $work/make.log" >&2; exit 1; }

echo "== 2. driver + mixer =="
audio=""
for unit in wine/wineps5/unix.c src/pw_audio_mix.c; do
    object=$prx/obj/wineps5_$(basename "$unit" .c).o
    $CC -std=gnu11 -O2 -fPIC -D__WINESRC__ -DWINE_UNIX_LIB -D_REENTRANT \
        -I"$build/include" -I"$tree/include" -I"$tree/dlls/mmdevapi" -I"$pw/wine/ps5" \
        -I"$pw/src" -I"$pw/include" -c "$pw/$unit" -o "$object" ||
        { echo "   X cannot compile $unit" >&2; exit 1; }
    audio="$audio $object"
done

echo "== 3. descriptor =="
# The two entry points a Wine unixlib exports, upstream's list verbatim.
python3 "$pw/tools/gen_prx_descriptor.py" "$prx/obj/wineps5_desc.c" \
    __wine_unix_call_funcs __wine_unix_call_wow64_funcs
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -I"$pw/wine/ps5" \
    -c "$prx/obj/wineps5_desc.c" -o "$prx/obj/wineps5_desc.o"

echo "== 4. link =="
# ⚠ pw_wine_dl_libc.o, or the driver never finds the sink. It looks the title's
# audio up by name --
#     dlsym(RTLD_DEFAULT, "pw_wine_audio_available")
#     dlsym(RTLD_DEFAULT, "pw_wine_audio_output")
# -- and ntdll exports both, but without this object the link takes dlsym from
# the static libc instead (nm: "T dlsym", a local definition) and that one
# knows nothing of pw_wine_dl's registry. It answers NULL, the driver reports
# itself unavailable, and the game says it has no soundcard -- the same symptom
# we started from, from a different cause. win32u had this exact bug with
# dlopen and libvulkan paid for it four times over.
#
# ⚠ And ntdll.so named on the line, not left to PW_PRX_STUBS. The wrapper
# appends those last, after libwineshim.a, so the archive answers
# pw_wine_dl_open first and the module ends up with its own registry -- empty,
# since nothing registers modules in it -- which fails exactly as the libc
# dlsym would. Named here it resolves to ntdll's, the one with the modules in
# it. nm tells the two apart: "U pw_wine_dl_open" is right, "t" is not.
stubs=$prx/stubs
export PW_PRX_STUBS="-L$stubs -Wl,--as-needed $(ls "$stubs"/*.so 2>/dev/null | tr '\n' ' ')"
# shellcheck disable=SC2086
$CC -shared -Wl,-Bsymbolic -Wl,--eh-frame-hdr -Wl,-soname,wineps5.prx \
    -Wl,--warn-unresolved-symbols -o "$prx/wineps5.shared.elf" \
    $audio "$prx/obj/wineps5_desc.o" "$prx/obj/pw_wine_dl_libc.o" \
    "$stubs/ntdll.so" > "$log" 2>&1 ||
    { echo "   X link"; grep -E "error|undefined" "$log" | head -8 | sed 's/^/      /'; exit 1; }

echo "== 5. container =="
"$oo/bin/linux/create-fself" -in "$prx/wineps5.shared.elf" \
    -out "$prx/wineps5.oelf" -lib "$prx/sce_module/wineps5.prx" \
    -libname wineps5.prx -ptype fake \
    -library-path "$stubs:$oo/lib" >> "$log" 2>&1 ||
    { echo "   X create-fself"; tail -4 "$log" | sed 's/^/      /'; exit 1; }
printf '   ok wineps5  %s\n' "$(du -h "$prx/sce_module/wineps5.prx" | cut -f1)"
