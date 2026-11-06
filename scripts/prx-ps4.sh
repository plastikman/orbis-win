#!/bin/sh
# Build the Wine PRX modules for PS4.
#
# prospero-win's own PRX stage (tools/build_wine_ps5.sh, link_prx) is skipped on
# PS4 -- it needs ps5-native-app-boilerplate's ps5-native-tool, which does not
# exist for this console. Steps 1-3 below are upstream's, unchanged in intent;
# only the final container step differs: where the PS5 runs
#     ps5-native-tool link --module   +   ps5-native-tool self --sign
# PS4 uses OpenOrbis create-fself -lib, which does both.
#
# The export lists are upstream's, verbatim. Exports come from the generated
# PRXDESC1 descriptor, NOT from the .so's dynamic symbol table -- converting a
# .so directly produces a module that exports libc and nothing prospero-win
# looks up.
set -eu
# Resolve libc from the shared module so the title and every PRX share one
# environ and one TLS regime (docs/FINDINGS.md). Unset to go back to static.
: "${PW_SHARED_LIBC:=1}"; export PW_SHARED_LIBC
gladius=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
root=${PW_ROOT:-$gladius/prospero-win}
sdk=$gladius/build/ps4-wine-sdk
oo=$gladius/sdk/orbis-sdk-v1/sdk
work=$root/.deps/wine-ps5
build=$work/build
prx=$work/prx
CC=$sdk/bin/prospero-clang
export OO_PS4_TOOLCHAIN=$oo
mkdir -p "$prx/obj" "$prx/sce_module"

link_objects() {
    python3 - "$work/make.log" "$1" <<'PY'
import shlex, sys
text = open(sys.argv[1], errors="replace").read().replace("\\\n", " ")
lines = [l for l in text.splitlines() if f"-o {sys.argv[2]} " in l]
if lines:
    print(" ".join(a for a in shlex.split(lines[-1])
                   if a.endswith(".o") and not a.startswith("/")))
PY
}

echo "== 1. platform units =="
for unit in pw_wine_prx pw_wine_dl pw_wine_dl_libc pw_wine_compat pw_wine_compat_libc \
        pw_wine_threads pw_wine_threads_libc pw_wine_sink pw_wine_cwd pw_wine_cwd_libc; do
    # Overlay the BSD headers the OpenOrbis SDK omits or spells differently.
    # Each wrapper include_nexts the SDK header and adds only the missing API.
    $CC -DPW_WINE_PRX_BUILD -std=gnu11 -O2 -Wall -Wextra -Werror -fPIC \
        -I"$gladius/src/freebsd-compat" \
        -c "$root/wine/ps5/$unit.c" -o "$prx/obj/$unit.o"
done

echo "== 1b. heap + direct-memory objects =="
# ntdll's allocator and its anonymous memory (patch 0600). link_objects() keeps
# only relative .o paths from make.log, so these never appear there and must be
# named here, exactly as upstream's link_prx takes them as its $3.
mkdir -p "$prx/heap"
heap=""
for unit in pw_wine_heap pw_wine_heap_libc; do
    $CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -c "$root/wine/ps5/$unit.c" -o "$prx/heap/$unit.o"
    heap="$heap $prx/heap/$unit.o"
done
# pw_wine_dmem is portable; its PS5 half is replaced by this port's PS4 glue,
# which supplies the five __wine_ps5_* entry points over PS4 direct memory.
dmem=""
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -c "$root/wine/ps5/pw_wine_dmem.c" -o "$prx/heap/pw_wine_dmem.o"
$CC -std=c11 -O2 -fPIC -I"$root/wine/ps5" ${PW_PRX_EXTRA_CFLAGS:-} -c "$gladius/src/native/pw_wine_dmem_glue_ps4.c" -o "$prx/heap/pw_wine_dmem_glue_ps4.o"
dmem="$prx/heap/pw_wine_dmem.o $prx/heap/pw_wine_dmem_glue_ps4.o"
$CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -I"$root/wine/ps5" \
    -c "$gladius/src/native/pw_wineserver_heap_ps4.c" -o "$prx/heap/pw_wineserver_heap_ps4.o"

echo "== 2. descriptors (upstream's export lists) =="
gen() { python3 "$root/tools/gen_prx_descriptor.py" "$@"; }
# ⚠ ABI-v4 upstream (tools/build_wine_ps5.sh) added per-index pad, rumble and
# menu calls to ntdll's export list. xinput1_3's unixlib dlsyms
# pw_wine_pad_at/pw_wine_set_rumble_at, and the app looks up
# pw_wine_set_pad_at, pw_wine_rumble_at, pw_wine_pads_wanted and
# pw_wine_set_menu in ntdll's descriptor. Without them xinput finds no pad and
# the app cannot feed one: the controller is simply lost (GLDS10043 01.05,
# 2026-11-05). Export each only where this tree's sink defines it, so the
# ABI-v3 tree still links.
sink_exports=""
for s in pw_wine_set_menu pw_wine_menu pw_wine_set_pad_at pw_wine_rumble_at \
        pw_wine_pad_at pw_wine_set_rumble_at pw_wine_pads_wanted pw_wine_pad_changes; do
    grep -q -E "^[a-z_0-9 ]+[ *]$s\(" "$root/wine/ps5/pw_wine_sink.c" && sink_exports="$sink_exports $s"
done
echo "   ntdll sink exports:$sink_exports"
gen "$prx/obj/ntdll_desc.c" \
    __wine_main pw_wine_dl_adopt dlopen dlsym dlerror \
    pw_wine_heap_stats pw_wine_heap_malloc pw_wine_heap_free \
    pw_wine_heap_calloc pw_wine_heap_realloc pw_wine_heap_memalign \
    pw_wine_dl_open pw_wine_dl_sym pw_wine_dl_close pw_wine_dl_error \
    pw_wine_dl_configure \
    pw_wine_set_present_sink pw_wine_post_input pw_wine_sink_stats \
    pw_wine_present pw_wine_next_input pw_wine_input_fd \
    pw_wine_set_pad pw_wine_rumble pw_wine_pad pw_wine_set_rumble \
    pw_wine_set_audio_sink pw_wine_audio_available pw_wine_audio_output \
    __wine_virtual_stats __wine_virtual_fault_top __wine_ps5_set_output_sink \
    __wine_ps5_memory_stats __wine_ps5_wait_for_exec_migration pw_cwd_set \
    __wine_ps5_set_segv_hook __wine_ps5_set_segv_unresolved_hook \
    pw_wine_set_display_release pw_wine_release_display pw_ps4_setenv pw_wine_dl_addr \
    $sink_exports \
    --optional-from "$build/dlls/ntdll/ntdll.so" --nm llvm-nm \
    --optional-export __wine_prospero_native_wow64_caps \
    --optional-export __wine_prospero_native_profile_sample
gen "$prx/obj/win32u_desc.c" __wine_unix_lib_init
if [ "${PW_PRE_V020:-0}" = 1 ]; then
    gen "$prx/obj/wineserver_desc.c" \
        pw_wineserver_connect pw_wine_thread_register pw_wine_thread_unregister \
        pw_wineserver_call_direct pw_wineserver_try_fast_mutex pw_cwd_share_changes
else
    # The title polls this to return to its launcher after a game's own Quit
    # (wine series 1053); exported only when the server defines it.
    server_exports=""
    grep -q "pw_wineserver_guest_exit_pending" "$work/source/server/request.c" &&
        server_exports="pw_wineserver_guest_exit_pending"
    echo "   wineserver extra exports: ${server_exports:-none}"
    gen "$prx/obj/wineserver_desc.c" \
        pw_wineserver_connect pw_wine_thread_register pw_wine_thread_unregister \
        pw_wineserver_call_direct pw_wineserver_try_fast_mutex \
        pw_wineserver_mutex_backend pw_wineserver_sync_backend pw_cwd_share_changes \
        $server_exports
fi
gen "$prx/obj/wowprospero_desc.c" __wine_unix_call_funcs
gen "$prx/obj/wow64native_desc.c" __wine_unix_call_funcs
for m in winevulkan opengl32 ws2_32 crypt32 dwrite xinput1_3; do
    gen "$prx/obj/${m}_desc.c" __wine_unix_call_funcs __wine_unix_call_wow64_funcs
done
for d in ntdll win32u wineserver wowprospero wow64native winevulkan opengl32 ws2_32 crypt32 dwrite xinput1_3; do
    $CC -std=gnu11 -O2 -fPIC -I"$root/wine/ps5" -c "$prx/obj/${d}_desc.c" -o "$prx/obj/${d}_desc.o"
done

# ⚠ xinput's Unix library is the one unixlib with no .so of its own: the Wine
# build never links one, so link_objects has nothing to find in make.log and
# tools/build_wine_ps5.sh compiles it directly. This arm never did, so
# xinput1_3.prx was simply absent from the package -- and every xinput PE asks
# for it by that exact name:
#
#     UNICODE_STRING name = RTL_CONSTANT_STRING(L"xinput1_3");
#     if ((status = __wine_load_unix_lib(&name, &module, &handle)))
#         TRACE("no Unix library, status %#lx: HID controllers\n", status);
#
# which GTA IV reached 42188 times, each one answered 0xc0000135,
# STATUS_DLL_NOT_FOUND, falling back to HID controllers that do not exist here.
# The pad was never the problem and neither was the mapping: patch 0470's
# reader was not in the package.
$CC -std=gnu11 -O2 -Wall -Werror -fPIC -D__WINESRC__ -DWINE_UNIX_LIB -D_REENTRANT \
    -I"$work/source/dlls/xinput1_3" -I"$build/include" -I"$work/source/include" \
    -c "$work/source/dlls/xinput1_3/unixlib.c" -o "$prx/obj/xinput_unixlib.o" ||
    { echo "  X xinput1_3: cannot compile unixlib.c" >&2; exit 1; }

# Wine's PS4 configure cannot find the WebKit-only POSIX resolver, so
# ws2_32/unixlib.c compiles a getaddrinfo stub that returns WS_EAI_FAIL. Supply
# Winsock's Unix side with the SDK's real sceNetResolver path instead.
$CC -std=gnu11 -O2 -Wall -Wextra -Werror -fPIC -D_REENTRANT -DPW_PS4_DNS \
    -I"$oo/include" -c "$root/wine/ps5/pw_ws2_32_libc.c" \
    -o "$prx/obj/pw_ws2_32_libc_ps4.o" ||
    { echo "  X ws2_32: cannot compile the PS4 resolver shim" >&2; exit 1; }

# Configure cannot link the console-only resolver while probing libc, so the
# generated config.h leaves HAVE_GETADDRINFO undefined. Compile just this
# unixlib with the feature enabled; the local shim above supplies all three
# POSIX resolver functions it calls.
$CC -std=gnu11 -m64 -DHAVE_GETADDRINFO -DPW_PS4_DNS -c \
    -o "$prx/obj/ws2_32_unixlib_dns.o" "$work/source/dlls/ws2_32/unixlib.c" \
    -I"$build/dlls/ws2_32" -I"$work/source/dlls/ws2_32" -I"$build/include" \
    -I"$work/source/include" -I"$gladius/src/freebsd-compat" \
    -D__WINESRC__ -D_WS2_32_ -DWINE_UNIX_LIB \
    -Wall -pipe -fcf-protection=none -fvisibility=hidden -fno-stack-protector \
    -fno-strict-aliasing -Wdeclaration-after-statement -Wempty-body \
    -Wignored-qualifiers -Winit-self -Wpointer-arith -Wstrict-prototypes \
    -Wtype-limits -Wunused-but-set-parameter -Wvla -Wwrite-strings \
    -gdwarf-4 -fPIC -fasynchronous-unwind-tables -g -O2 ||
    { echo "  X ws2_32: cannot compile resolver-enabled unixlib.c" >&2; exit 1; }

stubs=$prx/stubs; rm -rf "$stubs"; mkdir -p "$stubs"

# ⚠ -ptype fake. Without it create-fself stamps a library with the same
# header as an executable (measured: eboot.bin and ntdll.prx were byte-identical
# in their first 8 bytes), and the loader rejects it:
#     load status=-2147352568 stage=1 module=0x80020008    (ENOEXEC)
# after having found the file -- the previous failure was 0x80020002, ENOENT.
echo "== 3. link + 4. container =="
# ntdll: loader, compat, sink, cwd. The thread registry belongs to the server.
ntdll_shims="pw_wine_prx pw_wine_dl pw_wine_dl_libc pw_wine_compat pw_wine_compat_libc \
             pw_wine_sink pw_wine_cwd pw_wine_cwd_libc"
# This port's own: lets the title write into ntdll's environment (see the file).
$CC -std=gnu11 -O2 -fPIC -c "$gladius/src/native/pw_prx_env_ps4.c" -o "$prx/obj/pw_prx_env_ps4.o"
$CC -std=gnu11 -O2 -Wall -Wextra -Werror -fPIC -c "$gladius/src/native/pw_pthread_stack_ps4.c" -o "$prx/obj/pw_pthread_stack_ps4.o"
$CC -std=gnu11 -O2 -Wall -Wextra -Werror -fPIC \
    -DPW_WINESERVER_STACKSIZE_PASSTHROUGH=1 \
    -c "$gladius/src/native/pw_pthread_stack_ps4.c" -o "$prx/obj/pw_wineserver_stack_ps4.o"
srv_shims="pw_wine_compat pw_wine_compat_libc pw_wine_threads pw_wine_threads_libc \
           pw_wine_cwd pw_wine_cwd_libc"
# A title cannot chdir: ntdll and wineserver each keep their own working
# directory, so their path calls are wrapped (wine/ps5/pw_wine_cwd.h).
cwd_wraps=""
for n in $(grep -o '__wrap_[a-z_]*' "$root/wine/ps5/pw_wine_cwd_libc.c" | sed 's/^__wrap_//' | LC_ALL=C sort -u); do
    cwd_wraps="$cwd_wraps -Wl,--wrap=$n"
done

export PW_PRX_LINK=1
status=0
# ⚠ -lc BEFORE the stubs. Every PRX links the static libc whole-archive, so
# ntdll.prx EXPORTS libc -- and with the stubs ahead of -lc the linker bound
# every other module's C runtime to ntdll: wineserver imported 123 symbols from
# it, asprintf/atoi/calloc/__cxa_* and the rest, and the title died with
# PRX_NOT_RESOLVED_FUNCTION when dlopen brought it in. Resolving libc locally
# first leaves only the genuine Wine cross-references.
# Linking against the already-built modules is what records DT_NEEDED; without
# it create-fself has no library to attribute an imported symbol to and fails
# with "missing library for symbol". --as-needed keeps out dependencies a
# module does not actually use.
# create-fself resolves each imported symbol to a providing library, so a module
# must be built after everything it imports: win32u needs ntdll's Rtl*, the five
# unixlibs need ntdll's __wine_dbg_*, opengl32/winevulkan need win32u's.
for step in "ntdll|dlls/ntdll/ntdll.so|$ntdll_shims" \
            "win32u|dlls/win32u/win32u.so|" \
            "wineserver|server/wineserver|$srv_shims" \
            "winevulkan|dlls/winevulkan/winevulkan.so|" \
            "opengl32|dlls/opengl32/opengl32.so|" \
            "ws2_32|dlls/ws2_32/ws2_32.so|" \
            "crypt32|dlls/crypt32/crypt32.so|" \
            "dwrite|dlls/dwrite/dwrite.so|" \
            "xinput1_3|-|"; do
    name=${step%%|*}; rest=${step#*|}; target=${rest%%|*}; shims=${rest#*|}
    # "-": compiled above rather than taken from a .so the build never makes.
    if [ "$target" = - ]; then
        objs=$prx/obj/xinput_unixlib.o
    elif [ "$name" = ws2_32 ]; then
        objs=$prx/obj/ws2_32_unixlib_dns.o
    else
        objs=$(link_objects "$target")
    fi
    [ -n "$objs" ] || { echo "  ✗ $name: no ELF link in make.log"; status=1; continue; }
    shim_objs=""
    extra_libs=""
    thread_wraps=""
    if [ "$name" = ntdll ]; then
        shim_objs="$heap $dmem $prx/obj/pw_prx_env_ps4.o $prx/obj/pw_pthread_stack_ps4.o"
        thread_wraps="-Wl,--wrap=pthread_create"
    fi
    if [ "$name" = wineserver ]; then
        shim_objs="$prx/obj/pw_wineserver_stack_ps4.o $prx/heap/pw_wineserver_heap_ps4.o"
        thread_wraps="-Wl,--wrap=pthread_create"
    fi
    # ⚠ The server needs the heap too, and upstream says so: pw_wine_heap_libc.c
    # reads "the in-process wineserver links its own copy". Only ntdll got it
    # here, so wineserver kept importing malloc from the shared libc -- the very
    # allocator pw_wine_heap exists to escape, which stops near 13 MiB. It ran
    # out mid-game: 52 bytes refused after 100565 calls and 10322 KiB asked,
    # which the client sees as STATUS_NO_MEMORY from open_unix_file and the
    # loader reports as GTA IV's 30th DLL onwards failing to load. Its own copy,
    # as upstream intends; pw_wine_heap takes its memory from anonymous mmap in
    # 1 MiB pieces, so the server draws on flexible memory instead.
    [ "$name" = wineserver ] && shim_objs="$shim_objs $heap"
    [ "$name" = ws2_32 ] && shim_objs="$shim_objs $prx/obj/pw_ws2_32_libc_ps4.o"
    [ "$name" = ws2_32 ] && extra_libs="-lSceNetCtl"
    # ⚠ And every other unixlib gets the forwarding half alone. Without it they
    # import malloc and free from the shared libc, while anything they are
    # handed by ntdll came from pw_wine_heap -- and the two allocators do not
    # know each other. NtUserCreateWindowStation is the one that found this:
    # wine_server_alloc_object_attributes() allocates in ntdll, win32u frees it,
    # and libc's free walked into a block it had never issued and faulted inside
    # libSceLibcInternal, where it read as a crash in a win32u syscall.
    #
    # pw_wine_heap_libc.c says this is how it should be -- "ntdll.so links this
    # file and exports it, so win32u.so binds its malloc family to the same
    # heap" -- but on PS4 exports come from the PRXDESC descriptor, not the
    # symbol table, so that binding never happened. Linking the forwarding half
    # locally gets it instead, and keeps one heap rather than one per module:
    # the libc names resolve here, the pw_wine_heap_* entry points they call
    # resolve to ntdll.
    #
    # ⚠ And pw_wine_dl_libc.o with it, for the same reason in a different
    # symbol. win32u reaches Vulkan by dlopen(SONAME_LIBVULKAN), and it was
    # binding a WEAK dlopen of its own (nm: "W dlopen") rather than ntdll's
    # real one, which -Bsymbolic prefers. That stub answers NULL and says
    # nothing, so libvulkan.prx was reported missing while pw_wine_dl never saw
    # the call -- its failure text names every path it tried, and the only
    # entries in the log were ntdll's own.
    #
    # The forwarding half makes each module's dlopen strong and sends it to
    # pw_wine_dl_open in ntdll, so there is one module registry rather than one
    # per PRX, exactly as with the heap.
    case $name in
    ntdll|wineserver) ;;
    *) shim_objs="$shim_objs $prx/heap/pw_wine_heap_libc.o $prx/obj/pw_wine_dl_libc.o" ;;
    esac
    for s in $shims; do shim_objs="$shim_objs $prx/obj/$s.o"; done
    # stubs go through the shim so they land after orbis-compat and -lc
    export PW_PRX_STUBS="-L$stubs -Wl,--as-needed $(ls "$stubs"/*.so 2>/dev/null | tr '\n' ' ')"
    log=$prx/$name.link.log
    tail_pad=""
    # shellcheck disable=SC2086
    while :; do
    if (cd "$build" && $CC -shared -Wl,-Bsymbolic -Wl,--eh-frame-hdr \
            -Wl,-soname,"$name.prx" -Wl,--warn-unresolved-symbols $cwd_wraps $thread_wraps \
            -o "$prx/$name.shared.elf" $objs $shim_objs "$prx/obj/${name}_desc.o" \
            $extra_libs $tail_pad \
            ) > "$log" 2>&1 &&
       "$gladius/scripts/create-fself-repro.sh" "$oo/bin/linux/create-fself" -in "$prx/$name.shared.elf" \
               -out "$prx/$name.oelf" -lib "$prx/sce_module/$name.prx" \
               -libname "$name.prx" -ptype fake -library-path "$stubs:$oo/lib" >> "$log" 2>&1
    then
        # ⚠ create-fself SIZES THE WRITABLE SEGMENT AS align16(.data) + .bss,
        # leaving out .got.plt, which sits between them, so its end falls short
        # of the real end of .bss by about .got.plt's size (0x610 in wineserver).
        # The tail is mapped only if the 16 KiB page rounding happens to cover
        # it. 01.13 (2026-11-05) added 16 bytes to wineserver and pushed
        # __cxa_new_handler past the page: rtld refused the module
        # (reloc_non_plt ... ref=wineserver.prx) and every title died at
        # server_init_process. Growing .bss moves both ends together, so the
        # fix is to pad .bss by just enough that the converted end lands early
        # in a page, letting the rounding cover the shortfall. A separate
        # section does not count: create-fself only adds .bss. Modules that
        # are fine are linked once and stay byte-identical.
        pad=$(python3 - "$prx/$name.shared.elf" "$prx/$name.oelf" <<'PY'
import struct, sys
def loads(path):
    d = open(path, 'rb').read()
    phoff, = struct.unpack_from('<Q', d, 0x20); phentsize, phnum = struct.unpack_from('<HH', d, 0x36)
    out = []
    for i in range(phnum):
        t, f, off, va, pa, fs, ms, al = struct.unpack_from('<IIQQQQQQ', d, phoff + i * phentsize)
        if t == 1 and f & 2: out.append((va, ms))
    return out
elf, oelf = loads(sys.argv[1]), loads(sys.argv[2])
va, ms = max(elf, key=lambda s: s[0] + s[1])
end = max((ov + om for ov, om in oelf if ov == va), default=0)
if ((end + 0x3fff) & ~0x3fff) >= va + ms:
    print(0)
else:   # move the converted end to 0x100 into the next page
    print((0x4100 - (end & 0x3fff)) & 0x3fff or 0x100)
PY
)
        if [ "$pad" != 0 ] && [ -z "$tail_pad" ]; then
            printf '__attribute__((used, aligned(16))) char pw_%s_bss_pad[%s];\n' "$name" "$pad" \
                > "$prx/obj/${name}_bss_pad.c"
            $CC -std=gnu11 -O2 -fPIC -fno-common -c "$prx/obj/${name}_bss_pad.c" -o "$prx/obj/${name}_bss_pad.o"
            echo "  ! $name: create-fself would leave the end of .bss unmapped; relinking with a $pad-byte .bss pad"
            tail_pad="$prx/obj/${name}_bss_pad.o"
            continue
        fi
        if [ "$pad" != 0 ]; then
            echo "  ✗ $name: end of .bss still unmapped after the .bss pad"; status=1; break
        fi
            # Later modules import from this one. The linker needs lib<name>.so
            # to resolve -l style, and create-fself opens the DT_NEEDED name
            # verbatim -- which is the soname, "<name>.prx" -- so provide both.
            cp "$prx/$name.shared.elf" "$stubs/$name.so"
            cp "$prx/$name.shared.elf" "$stubs/$name.prx"
            echo "  ✓ $name  $(du -h "$prx/sce_module/$name.prx" | cut -f1)"
    else
        echo "  ✗ $name: link/create-fself"; grep -E "error|undefined" "$log" | head -4 | sed 's/^/      /'
        tail -3 "$log" | sed 's/^/      /'; status=1
    fi
    break
    done
done
echo "== 5. wowprospero (the i386 DBT as Wine's WoW64 CPU backend) =="
# Built last because it links against ntdll, which the loop above produces.
# Not a Wine make target: tools/build_wowprospero.sh builds it with one
# compiler command over unix.c and prospero-win's DBT, so it is absent from
# make.log and link_objects() cannot see it. Same source list as upstream.
export PW_PRX_STUBS="-L$stubs -Wl,--as-needed $(ls "$stubs"/*.so 2>/dev/null | tr '\n' ' ')"
WOW_DBT="$root/src/pw_x86_engine.c $root/src/pw_x86_block.c $root/src/pw_x86_cache.c
         $root/src/pw_x86_hostexec.c $root/src/pw_x86_reencode.c $root/src/pw_x87.c
         $root/src/pw_guest_fp.c $root/src/pw_vm.c $root/src/pw_vm_posix.c"
# shellcheck disable=SC2086
# ⚠ -femulated-tls. unix.c keeps the translator's per-thread state in a
# "static __thread", which in a shared object compiles to general-dynamic TLS
# and calls the static libc's __tls_get_addr. That one returns NULL here, so
# get_thread() read self as NULL and the DBT faulted on it the instant it began
# translating guest code -- sixty thousand faults a second, each retried, which
# is why the title span rather than crashed. Upstream's equivalent module links
# emutls.o out of the PS5 SDK's libc; this SDK has none, so src/native supplies
# the same entry point.
$CC -shared -Wl,-Bsymbolic -Wl,-soname,wowprospero.prx \
    -femulated-tls \
    -D__WINESRC__ -DWINE_UNIX_LIB -D_REENTRANT \
    -DPW_WOW_PS4_BUDGET \
    -I"$root/wine/wowprospero" -I"$build/include" -I"$work/source/include" \
    -I"$root/src" -I"$root/include" \
    "$root/wine/wowprospero/unix.c" $WOW_DBT "$gladius/src/native/pw_emutls_ps4.c" "$gladius/src/native/pw_wow_log_ps4.c" "$prx/obj/wowprospero_desc.o" \
    -o "$prx/wowprospero.shared.elf" \
    > "$prx/wowprospero.link.log" 2>&1 || { echo "  ✗ wowprospero: link"; grep -E "error" "$prx/wowprospero.link.log" | head -3; }

if [ -f "$prx/wowprospero.shared.elf" ]; then
    if "$gladius/scripts/create-fself-repro.sh" "$oo/bin/linux/create-fself" -in "$prx/wowprospero.shared.elf" \
           -out "$prx/wowprospero.oelf" -lib "$prx/sce_module/wowprospero.prx" \
           -libname "wowprospero.prx" -ptype fake -library-path "$stubs:$oo/lib" \
           >> "$prx/wowprospero.link.log" 2>&1
    then echo "  ✓ wowprospero  $(du -h "$prx/sce_module/wowprospero.prx" | cut -f1)"
    else echo "  ✗ wowprospero: create-fself"; tail -3 "$prx/wowprospero.link.log" | sed 's/^/      /'; status=1; fi
fi

if [ "${PW_SKIP_NATIVE:-0}" = 1 ]; then
    echo "== 6. skip native WoW64 companion (translator control build) =="
else
echo "== 6. wow64native (native WoW64 Unix companion) =="
# The PE backend's DllMain calls __wine_init_unix_call(). That requires this
# Unix companion at x86_64-unix/wow64native.prx. The package's generic PRX
# staging loop copies every module in sce_module/ to both runtime locations;
# omitting this companion makes DllMain fail with STATUS_DLL_INIT_FAILED and
# Wine silently falls back to the prefix CPU, even while telemetry says the
# selected backend is native.
export PW_PRX_STUBS="-L$stubs -Wl,--as-needed $(ls "$stubs"/*.so 2>/dev/null | tr '\n' ' ')"
$CC -shared -Wl,-Bsymbolic -Wl,--eh-frame-hdr -Wl,-soname,wow64native.prx \
    -femulated-tls \
    -D__PROSPERO__ -D__WINESRC__ -DWINE_UNIX_LIB -D_REENTRANT \
    -I"$root/wine/wow64native" -I"$build/include" -I"$work/source/include" \
    -I"$root/src" -I"$root/include" \
    "$root/wine/wow64native/unix.c" "$gladius/src/native/pw_emutls_ps4.c" \
    "$gladius/src/native/pw_wow_log_ps4.c" \
    "$prx/obj/pw_wine_dl_libc.o" "$prx/obj/wow64native_desc.o" \
    -o "$prx/wow64native.shared.elf" \
    > "$prx/wow64native.link.log" 2>&1 || {
        echo "  ✗ wow64native: link"; grep -E "error|undefined" "$prx/wow64native.link.log" | head -4; status=1;
    }

if [ -f "$prx/wow64native.shared.elf" ]; then
    if "$gladius/scripts/create-fself-repro.sh" "$oo/bin/linux/create-fself" -in "$prx/wow64native.shared.elf" \
           -out "$prx/wow64native.oelf" -lib "$prx/sce_module/wow64native.prx" \
           -libname "wow64native.prx" -ptype fake -library-path "$stubs:$oo/lib" \
           >> "$prx/wow64native.link.log" 2>&1
    then
        cp "$prx/wow64native.shared.elf" "$stubs/wow64native.so"
        cp "$prx/wow64native.shared.elf" "$stubs/wow64native.prx"
        echo "  ✓ wow64native  $(du -h "$prx/sce_module/wow64native.prx" | cut -f1)"
    else
        echo "  ✗ wow64native: create-fself"; tail -3 "$prx/wow64native.link.log" | sed 's/^/      /'; status=1
    fi
fi
fi

exit $status
