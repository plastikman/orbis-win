#!/bin/sh
# Build libfreetype.prx for PS4: the FreeType win32u looks up by dlsym.
#
# build_wine_ps5.sh already compiles libfreetype.a and hands it to configure as
# FREETYPE_LIBS, but nothing can reach it: win32u's freetype.c opens FreeType
# only through dlopen(SONAME_LIBFREETYPE) and then dlsym's each entry point, and
# the archive is not even on win32u's link line. So the library was built and
# then went nowhere, every run reported
#
#     Wine cannot find the FreeType font library.
#
# and the port had no fonts at all. A Windows error box drew its frame and not
# one glyph of the message inside it.
#
# Same shape as scripts/radv-prx-ps4.sh: put the archive behind a PRXDESC1
# descriptor so pw_wine_dl's dlopen("libfreetype.so") finds libfreetype.prx and
# dlsym resolves from the descriptor.
set -eu
# Share the title's libc, as every other PRX here does; see prx-ps4.sh.
: "${PW_SHARED_LIBC:=1}"; export PW_SHARED_LIBC
# ⚠ PW_PRX_LINK=1 keeps libwineshim.a off the line (src/toolchain/prospero-clang
# :108). It carries this port's stand-ins for the wine/ps5 units, so with it
# present the linker answers pw_wine_heap_malloc and pw_wine_dl_open out of the
# archive and the module gets its own copy of the heap and of the module
# registry instead of ntdll's. prx-ps4.sh sets this for every module it builds.
PW_PRX_LINK=1; export PW_PRX_LINK
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
bundle=$root/sdk/orbis-sdk-v1
oo=$bundle/sdk
sdk=$root/build/ps4-wine-sdk
pw=${PW_ROOT:-$root/prospero-win}
prx=$pw/.deps/wine-ps5/prx
CC=$sdk/bin/prospero-clang
export OO_PS4_TOOLCHAIN=$oo

archive=$pw/.deps/wine-ps5/freetype/libfreetype.a
[ -f "$archive" ] || { echo "no libfreetype.a at $archive" >&2; exit 2; }

work=$prx/freetype
mkdir -p "$work/obj" "$prx/sce_module"
log=$prx/libfreetype.link.log

# The entry points win32u resolves, taken from its own source rather than a
# list kept here: freetype.c's LOAD_FUNCPTR lines are the contract, and a name
# added upstream must not silently become a NULL pointer at run time.
symbols=$(grep -oE "LOAD_FUNCPTR\(FT_[A-Za-z_0-9]+\)" \
    "$pw/.deps/wine-ps5/source/dlls/win32u/freetype.c" |
    sed 's/LOAD_FUNCPTR(//;s/)//' | sort -u)
echo "== 1. descriptor ($(echo "$symbols" | wc -l) entry points) =="
# shellcheck disable=SC2086
python3 "$pw/tools/gen_prx_descriptor.py" "$work/obj/libfreetype_desc.c" $symbols
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -I"$pw/wine/ps5" \
    -c "$work/obj/libfreetype_desc.c" -o "$work/obj/libfreetype_desc.o"

echo "== 2. heap =="
# ⚠ By --wrap, not by linking wine/ps5/pw_wine_heap_libc.o as the unixlibs do:
# this link already defines strdup, aligned_alloc and posix_memalign from the
# static libc, and that file defines them too. Four wraps are all that is
# needed, and they collide with nothing.
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC \
    -c "$root/src/native/pw_prx_heap_wrap_ps4.c" -o "$work/obj/pw_prx_heap_wrap_ps4.o"

# ⚠ Link against ntdll's stub, as prx-ps4.sh does for every module it builds.
# Without it the linker resolves pw_wine_heap_malloc out of libwineshim.a and
# this module gets its own copy of the heap -- nm shows it as "t", a local
# definition, rather than "U" -- which is the same split this change exists to
# close, just one layer down. With the stub on the line it imports ntdll's.
stubs=$prx/stubs
export PW_PRX_STUBS="-L$stubs -Wl,--as-needed $(ls "$stubs"/*.so 2>/dev/null | tr '\n' ' ')"

echo "== 3. link =="
# ⚠ pw_wine_heap_libc.o, so this module's malloc family is ntdll's heap and not
# the shared libc's. Three bugs today came of a module binding its own
# allocator: wineserver ran out of a 13 MiB libc arena, win32u freed a block
# ntdll had allocated and faulted inside libSceLibcInternal, and every unixlib
# took dlopen from a weak stub instead of ntdll's. FreeType allocates buffers
# that win32u's font code frees, so the two must agree on the heap.
#
# whole-archive for the same reason the driver needs it: nothing will dlopen
# the members the linker decided were unreachable, and win32u resolves each
# entry point by name at run time rather than referencing it at link time.
$CC -shared -Wl,-Bsymbolic -Wl,--eh-frame-hdr -Wl,-soname,libfreetype.prx \
    -Wl,--wrap=malloc -Wl,--wrap=calloc -Wl,--wrap=realloc -Wl,--wrap=free \
    -Wl,--warn-unresolved-symbols -o "$prx/libfreetype.shared.elf" \
    "$work/obj/libfreetype_desc.o" "$work/obj/pw_prx_heap_wrap_ps4.o" \
    -Wl,--whole-archive "$archive" -Wl,--no-whole-archive > "$log" 2>&1 ||
    { echo "   X link"; grep -E "error|undefined" "$log" | head -8 | sed 's/^/      /'; exit 1; }

echo "== 4. container =="
"$oo/bin/linux/create-fself" -in "$prx/libfreetype.shared.elf" \
    -out "$prx/libfreetype.oelf" -lib "$prx/sce_module/libfreetype.prx" \
    -libname libfreetype.prx -ptype fake \
    -library-path "$prx/stubs:$oo/lib" >> "$log" 2>&1 ||
    { echo "   X create-fself"; tail -4 "$log" | sed 's/^/      /'; exit 1; }
printf '   ok libfreetype  %s\n' "$(du -h "$prx/sce_module/libfreetype.prx" | cut -f1)"
