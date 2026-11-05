#!/bin/sh
# Build libvulkan.prx for PS4: RADV behind the two entry points win32u looks up.
#
# prospero-win's own recipe (tools/link_radv_prx.sh) wants a PS5_Vulkan
# checkout -- .deps/native/radv-release/lib/libvulkan_radeon.ps5.a, a
# PROVENANCE.txt, the checkout's radv-link.sh -- and finishes with
# ps5-native-tool, which does not exist for this console. This is the PS4 arm,
# linking the bundle's own RADV with create-fself, exactly as scripts/prx-ps4.sh
# does for the other nine modules.
#
# The library set is the bundle's, not invented here: orbis-compat/vkloader/
# CMakeLists.txt carries it with the reasoning, and the triangle example proves
# it reaches the screen. Whole-archive because nothing will dlopen the members
# the linker dropped; zlib because RADV's shader disk cache calls
# deflate/inflate/crc32; SceGnmDriver and SceVideoOut because the driver's WSI
# arm opens video-out itself, so they belong to the archive rather than to any
# title.
set -eu
# ⚠ Share the title's libc, as every other PRX here does (scripts/prx-ps4.sh).
# Without this the toolchain links the static archive instead
# (src/toolchain/prospero-clang:124), and the module arrives with a second libc
# -- its own environ and its own TLS regime -- and no libSceLibcInternal in
# NEEDED. Measured: libvulkan.prx built that way loads nowhere, and win32u
# reports only "Failed to load libvulkan.so".
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
# The local Mesa implements low CPU aliases validated by vkmapprobe on PS4.
# Override PW_RADV_MESA_SRC/PW_RADV_MESA_BUILD for an explicit alternate build.
mesa_src=${PW_RADV_MESA_SRC:-$root/mesa-build/mesa-ps4}
mesa_build=${PW_RADV_MESA_BUILD:-$mesa_src/build-orbis}
CC=$sdk/bin/prospero-clang
export OO_PS4_TOOLCHAIN=$oo

archive=$mesa_build/src/amd/vulkan/libvulkan_radeon.a
zlib=$(ls "$mesa_build"/subprojects/zlib-*/libz.a 2>/dev/null | head -1)
[ -f "$archive" ] || { echo "no RADV archive at $archive" >&2; exit 2; }
[ -n "$zlib" ] || { echo "no libz.a under $mesa_build/subprojects/zlib-*/" >&2; exit 2; }

work=$prx/radv
mkdir -p "$work/obj" "$prx/sce_module"
log=$prx/libvulkan.link.log

echo "== 1. entry points =="
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -I"$mesa_src/include" \
    -c "$root/src/native/pw_vulkan_radv_ps4.c" -o "$work/obj/pw_vulkan_radv_ps4.o"

# ⚠ The module's own environment, so RADV's ORBIS_* switches can be read at
# all. Each PRX carries a private environment here and this one had none, which
# left the driver's tessellation knobs and its ring watermark probe switched
# off; pw_vulkan_radv_ps4.c fills it from /data/prospero-win/radv.env.
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC \
    -c "$root/src/native/pw_prx_env_ps4.c" -o "$work/obj/pw_prx_env_ps4.o"

echo "== 2. descriptor =="
python3 "$pw/tools/gen_prx_descriptor.py" "$work/obj/libvulkan_desc.c" \
    vkGetInstanceProcAddr vkGetDeviceProcAddr pw_videoout_cursor
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -I"$pw/wine/ps5" \
    -c "$work/obj/libvulkan_desc.c" -o "$work/obj/libvulkan_desc.o"

echo "== 3. optional entry points =="
# Mesa's dispatch tables reference optional entry points weakly. In a shared ELF
# lld leaves each as a dynamic import, which the PRX converter takes for a
# required external function: resolve them to 0, as an executable would.
"$sdk/bin/llvm-nm" -g "$archive" | awk '$1 == "w" {print $2}' | LC_ALL=C sort -u |
    awk '{print "PROVIDE_HIDDEN(" $0 " = 0);"}' > "$work/mesa_optional_zero.ld"
printf '   %s weak symbols zeroed\n' "$(wc -l < "$work/mesa_optional_zero.ld")"

# Share ntdll's large direct-memory heap for shader compiler allocations.
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC \
    -c "$root/src/native/pw_prx_heap_wrap_ps4.c" -o "$work/obj/pw_prx_heap_wrap_ps4.o"
stubs=$prx/stubs
export PW_PRX_STUBS="-L$stubs -Wl,--as-needed $(ls "$stubs"/*.so 2>/dev/null | tr '\n' ' ')"

echo "== 4. link =="
$CC -shared -Wl,-Bsymbolic -Wl,--eh-frame-hdr -Wl,-soname,libvulkan.prx \
    -Wl,--wrap=strdup -Wl,--wrap=__tls_get_addr -Wl,--wrap=scePthreadCreate \
    -Wl,--wrap=malloc -Wl,--wrap=calloc -Wl,--wrap=realloc -Wl,--wrap=free \
    -Wl,--wrap=memalign -Wl,--wrap=aligned_alloc -Wl,--wrap=posix_memalign \
    -Wl,--wrap=strndup -Wl,--wrap=asprintf -Wl,--wrap=vasprintf \
    -Wl,--wrap=_ZdlPv -Wl,--wrap=_ZdaPv -Wl,--wrap=_ZdlPvm \
    -Wl,-T,"$work/mesa_optional_zero.ld" -Wl,--warn-unresolved-symbols \
    -o "$prx/libvulkan.shared.elf" \
    "$work/obj/pw_vulkan_radv_ps4.o" "$work/obj/pw_prx_env_ps4.o" "$work/obj/libvulkan_desc.o" \
    "$work/obj/pw_prx_heap_wrap_ps4.o" \
    -Wl,--whole-archive "$archive" -Wl,--no-whole-archive \
    "$zlib" -lSceGnmDriver -lSceVideoOut > "$log" 2>&1 ||
    { echo "   X link"; grep -E "error|undefined" "$log" | head -8 | sed 's/^/      /'; exit 1; }

echo "== 5. container =="
# -library-path, as prx-ps4.sh passes for every other module: create-fself
# resolves each imported symbol to a providing library, and without the path it
# has nowhere to look.
"$oo/bin/linux/create-fself" -in "$prx/libvulkan.shared.elf" \
    -out "$prx/libvulkan.oelf" -lib "$prx/sce_module/libvulkan.prx" \
    -libname libvulkan.prx -ptype fake \
    -library-path "$prx/stubs:$oo/lib" >> "$log" 2>&1 ||
    { echo "   X create-fself"; tail -4 "$log" | sed 's/^/      /'; exit 1; }
printf '   ok libvulkan  %s\n' "$(du -h "$prx/sce_module/libvulkan.prx" | cut -f1)"
