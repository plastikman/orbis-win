#!/usr/bin/env python3
"""Check a PS4 package stage for the port's required behaviour before any install.

    scripts/check-ps4-package-parity.py BASELINE_STAGE CANDIDATE_STAGE \
        [--elf-dir PRX_BUILD_DIR] [--upstream-root PROSPERO_WIN_SOURCE]

BASELINE_STAGE is the last known-good package stage (e.g.
pkgout/baseline/pkg-stage, a symlink to the promoted build). CANDIDATE_STAGE is the
stage about to be packaged. --elf-dir is the PRX build directory holding the
candidate's unstripped *.shared.elf files (enables the signal-mask check).

Every hard gate below failed silently at least once during the 2026-11 ABI-v4
sync, each costing console cycles; see docs/UPSTREAM-SYNC-PLAYBOOK.md. A
FAIL means: do not install. WARN items need a written disposition.
Exit status: 0 = no FAIL, 1 = at least one FAIL.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

UNIX = 'win/wine/lib/wine/x86_64-unix'
I386 = 'win/wine/lib/wine/i386-windows'
DUPLICATED = ('ntdll', 'win32u', 'wineserver', 'winevulkan', 'libvulkan', 'wow64native',
              'wowprospero', 'opengl32', 'ws2_32', 'crypt32', 'dwrite', 'xinput1_3')
INTEREST = re.compile(r'PW_|PS4|ps4|ps5|PS5|orbis|sink|pw_wine|prospero|__wine_ps5|relocwine|headless')

failures = 0


def report(level, msg):
    global failures
    if level == 'FAIL':
        failures += 1
    print(f"[{level}] {msg}")


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def strings(path, minimum=6):
    data = read(path)
    return {m.decode('latin-1') for m in re.findall(rb'[\x20-\x7e]{%d,}' % minimum, data)}


def module(stage, name):
    return os.path.join(stage, 'sce_module', name + '.prx')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('baseline')
    ap.add_argument('candidate')
    ap.add_argument('--elf-dir', help='directory with the candidate *.shared.elf files')
    ap.add_argument('--upstream-root', help='prospero-win source root the candidate was built from '
                                            '(its tools/build_wine_ps5.sh holds the export lists)')
    args = ap.parse_args()
    base, cand = args.baseline, args.candidate

    # 0. Both stages must exist. A missing baseline used to compare against an empty tree and pass
    # with "0 baseline payload files absent"; a missing candidate died in a traceback.
    for label, path in (('baseline', base), ('candidate', cand)):
        if not os.path.isdir(path):
            report('FAIL', f"{label} stage {path!r} is not a directory (missing, or a dangling symlink); "
                           "nothing was compared")
    if failures:
        print(f"\nNOT INSTALLABLE: {failures} FAIL")
        return 1

    # 1. Relocation: the eboot must be the no-RELRO stub that loads the app PRX.
    eboot = os.path.join(cand, 'eboot.bin')
    app = module(cand, 'relocated_wine_app')
    eb = read(eboot)
    wine_stub = b'/app0/sce_module/relocated_wine_app.prx' in eb
    playden_stub = (b'/app0/sce_module/playden_ui.prx' in eb and
                    b'playden_ps4_start' in eb)
    playden_ui = module(cand, 'playden_ui')
    if playden_stub:
        ui_strings = strings(playden_ui) if os.path.isfile(playden_ui) else set()
        handoff = {'/app0/sce_module/relocated_wine_app.prx', 'pw_relocated_wine_start'}
        missing_handoff = sorted(handoff - ui_strings)
        report('PASS' if len(eb) < 200_000 and not missing_handoff else 'FAIL',
               f"eboot.bin is the Playden relocation stub ({len(eb)} bytes); playden_ui.prx hands off to Wine"
               if len(eb) < 200_000 and not missing_handoff else
               f"Playden relocation chain incomplete: eboot size={len(eb)}, "
               f"playden_ui.prx missing {missing_handoff}")
    elif wine_stub and len(eb) < 200_000:
        report('PASS', f"eboot.bin is the relocation stub ({len(eb)} bytes, loads relocated_wine_app.prx)")
    else:
        report('FAIL', f"eboot.bin ({len(eb)} bytes) does not load a verified relocation chain: "
                       "the full app at 0x400000 may have been packaged instead of the no-RELRO stub")
    if os.path.isfile(app):
        s = strings(app)
        need = {'pw_relocated_wine_start', 'pw_relocated_wine_release_eboot',
                'PW_WINE64 relocatable eboot release status=%d'}
        missing = need - s
        report('FAIL' if missing else 'PASS', f"relocated_wine_app.prx contract/markers missing: {sorted(missing)}"
               if missing else "relocated_wine_app.prx exports start/release and logs the release marker")
        marker = sorted(x for x in s if x.startswith('PW_WINE64 build_marker='))
        report('PASS' if marker else 'WARN', f"app build marker: {marker[0] if marker else 'none (runs will be unattributable)'}")
    else:
        report('FAIL', 'sce_module/relocated_wine_app.prx is missing')

    # 2. Duplicate runtime copies must match byte for byte.
    for name in DUPLICATED:
        a, b = module(cand, name), os.path.join(cand, UNIX, name + '.prx')
        if os.path.isfile(a) and os.path.isfile(b):
            if read(a) != read(b):
                report('WARN' if name == 'libvulkan' else 'FAIL', f"{name}.prx: sce_module and {UNIX} copies differ")
        elif os.path.isfile(a) != os.path.isfile(b):
            report('FAIL', f"{name}.prx present in only one of sce_module / {UNIX}")

    # 3. Vulkan surface: PS4 RADV offers VK_EXT_headless_surface, not VK_KHR_display.
    w = strings(module(cand, 'win32u'))
    if 'headless surface: res %d' in ' '.join(w) or any('headless surface: res' in x for x in w):
        report('PASS', 'win32u has the PS4 headless-surface arm (VK_KHR_win32_surface is advertised)')
    else:
        report('FAIL', 'win32u lacks the PS4 headless-surface arm: every DXVK title fails vkCreateInstance '
                       '(archive patch 0878, series 1036)')
    report('PASS' if 'WINE_PS5_SCANOUT' in w else 'FAIL',
           'win32u has the headless scanout extent (0861/0862)' if 'WINE_PS5_SCANOUT' in w else
           'win32u lacks WINE_PS5_SCANOUT: frames render but never reach the display (0861/0862)')

    # 3b. OpenGL provider: graphics = opengl games are refused without it.
    missing_zink = [f"{a}/{d}" for a in ('i386-windows', 'x86_64-windows')
                    for d in ('opengl32.dll', 'libgallium_wgl.dll')
                    if not os.path.isfile(os.path.join(cand, 'win/mesa-zink', a, d))]
    report('FAIL' if missing_zink else 'PASS',
           f"Mesa Zink OpenGL provider missing ({', '.join(missing_zink)}): every graphics = opengl "
           "title is refused at startup (pass PW_MESA_ZINK_DIR)" if missing_zink else
           'win/mesa-zink carries the WGL/Zink OpenGL provider for both architectures')

    # 4. PS4 RADV, not the upstream bundle's driver.
    v = strings(module(cand, 'libvulkan'))
    ps4_radv = [x for x in v if x.startswith(('PW_ORBIS_VA_FAIL', 'wsi/orbis: 0031', 'RADV_ALLOC_CMD_BUFFER'))]
    report('PASS' if ps4_radv else 'FAIL', 'libvulkan.prx is the PS4 RADV (mesa-ps4 + src/mesa-patches-ps4)'
           if ps4_radv else 'libvulkan.prx lacks the PS4 Mesa markers: rebuild it with scripts/radv-prx-ps4.sh')

    # 4b. The title shows its GDI frames / movies / spinner through the driver once a game has a Vulkan
    # surface; without these exports they are dropped (WON Half-Life menu black, 2026-11-05; Mesa 0038).
    missing_vo = [n for n in ('pw_videoout_idle', 'pw_videoout_show_tiled', 'pw_videoout_quiesce') if n not in v]
    report('FAIL' if missing_vo else 'PASS',
           f"libvulkan.prx lacks {missing_vo}: the title's non-Vulkan frames vanish once a game has a Vulkan "
           "surface (src/native/pw_vulkan_radv_ps4.c, scripts/radv-prx-ps4.sh)" if missing_vo else
           'libvulkan.prx exports pw_videoout_idle/show_tiled/quiesce for the title\'s own frames')

    # 4b-2. The orbis-compat split. RADV links the BUNDLE archive; every other PRX links the PIN. Each half
    # is load-bearing and they are not interchangeable:
    #   * libvulkan.prx against the PIN faults 0xc0000005 at libvulkan.so+0x16a6dba dereferencing address 8,
    #     during driver init, so no title ever renders -- it either hangs with frames_put=0 or drops back to
    #     the launcher (solved 2026-11-17, reintroduced in Playden 01.31 / Orbis-Win 02.67 and caught only on
    #     hardware because nothing here checked it).
    #   * every other PRX against the BUNDLE loses the pin's signal.h fix (SIG_UNBLOCK=2), which is what makes
    #     native WoW64 work; without it every title silently drops to the translator.
    # The marker is the archive's own content, not a hash, so this survives a rebuild: the pin carries
    # orbis_jit, the bundle carries ORBIS_THREAD_STACK. libc.prx and libSceFios2.prx are SDK modules that
    # link neither and are exempt.
    SDK_MODULES = ('libc', 'libSceFios2')
    if 'ORBIS_THREAD_STACK' in v and not any(x.startswith('orbis_jit') for x in v):
        report('PASS', 'libvulkan.prx links the bundle orbis-compat, as RADV requires')
    else:
        report('FAIL', 'libvulkan.prx links the PIN orbis-compat: it will fault 0xc0000005 at +0x16a6dba in '
                       'driver init and NO title will render. Rebuild it against the bundle archive '
                       '(sdk/orbis-sdk-v1/orbis-compat, 114,252 B) with that same tree\'s headers')
    mismatched = []
    for prx in sorted(glob.glob(os.path.join(cand, 'sce_module', '*.prx'))):
        name = os.path.basename(prx)[:-4]
        if name == 'libvulkan' or name in SDK_MODULES:
            continue
        if not any(x.startswith('orbis_jit') for x in strings(prx)):
            mismatched.append(name)
    report('FAIL' if mismatched else 'PASS',
           f"{mismatched} link the bundle orbis-compat instead of the pin: without the pin's signal.h fix "
           '(SIG_UNBLOCK=2) native WoW64 stops working and every title falls back to the translator'
           if mismatched else 'every non-RADV PRX links the pin orbis-compat, keeping native WoW64')

    # 4c. Window-sized swapchains are fitted to the screen (Mesa 0039) and win32u reports the window's size
    # (series 1054). Either half alone is wrong: 1054 without 0039 shows a small swapchain in a corner of the
    # display, and 0039 without 1054 leaves GL titles drawing into a corner of a 1920x1080 swapchain
    # (WON Half-Life, 2026-11-05).
    fit = any('swapchain scaled to' in x for x in v)
    client = 'WINE_PS5_SURFACE_EXTENT' in w
    report('PASS' if fit and client else 'FAIL',
           'wsi_orbis fits any swapchain size (0039) and win32u reports the window size (1054)' if fit and client
           else f"swapchain sizing half-applied: wsi_orbis fit (Mesa 0039) {'present' if fit else 'MISSING'}, "
                f"win32u client extent (series 1054) {'present' if client else 'MISSING'}")

    # 5. Descriptor exports. The app and the Unix libraries find ntdll/wineserver
    # calls by name (pw_prx_lookup/dlsym), so a stale export list in
    # scripts/prx-ps4.sh silently breaks them (01.05: controller lost because
    # pw_wine_pad_at & co. were not exported). Check upstream's lists, and the
    # names xinput looks up (xinput defines no pw_wine_* symbol of its own).
    def upstream_exports(desc):
        script = os.path.join(args.upstream_root, 'tools', 'build_wine_ps5.sh')
        text = open(script, errors='replace').read().replace('\\\n', ' ')
        m = re.search(r'gen_prx_descriptor\.py"\s+"\$prx/obj/%s_desc\.c"([^\n]*)' % desc, text)
        names, skip = set(), False
        for tok in (m.group(1).split() if m else []):
            if skip:
                skip = False
            elif tok.startswith('--'):
                skip = True       # --optional-from FILE, --nm TOOL, --optional-export NAME
            elif re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', tok):
                names.add(tok)
        return names
    # ⚠ The exported set is the generated descriptor, not the string table: a
    # function compiled into ntdll keeps its name as a string even when the
    # descriptor does not export it (01.05 had pw_wine_pad_at as a string and
    # still lost the controller). So read <elf-dir>/obj/<module>_desc.c, after
    # proving that build directory produced this stage's PRX.
    def exported(prov):
        if not args.elf_dir:
            return None
        built = os.path.join(args.elf_dir, 'sce_module', prov + '.prx')
        desc = os.path.join(args.elf_dir, 'obj', prov + '_desc.c')
        if not (os.path.isfile(built) and os.path.isfile(desc)) or read(built) != read(module(cand, prov)):
            report('WARN', f"{prov}: --elf-dir PRX does not match the stage; export check skipped")
            return None
        return set(re.findall(r'^extern char ([A-Za-z_][A-Za-z0-9_]*)\[\];', open(desc).read(), re.M))
    checks = []
    if args.upstream_root:
        checks += [('ntdll', upstream_exports('ntdll')), ('wineserver', upstream_exports('wineserver'))]
    else:
        report('WARN', 'upstream export lists not checked (pass --upstream-root)')
    xi = module(cand, 'xinput1_3')
    if os.path.isfile(xi):
        checks.append(('ntdll', {x for x in strings(xi, 4) if re.fullmatch(r'pw_wine_[a-z_]+', x)}))
    # Quit-to-launcher (series 1053): the app polls the in-process server's flag by name. Without the
    # poll, or without the export it resolves, a game's own Quit leaves Wine's empty desktop on screen
    # until the player closes the app from the PS button.
    app_strings = strings(app, 4) if os.path.isfile(app) else []
    quit_poll = any('guest processes ended' in x for x in app_strings)
    report('PASS' if quit_poll else 'FAIL', 'relocated_wine_app returns to the launcher on guest exit (1053)'
           if quit_poll else 'relocated_wine_app lacks the guest-exit poll: a game\'s own Quit strands the '
           'player on an empty desktop (series 1053 + native/wine64_main.c)')
    checks.append(('wineserver', {x for x in app_strings if re.fullmatch(r'pw_wineserver_[a-z_]+', x)}))
    for prov, names in checks:
        have = exported(prov)
        if have is None:
            if not args.elf_dir:
                report('WARN', f"{prov}: export check needs --elf-dir (the PRX build directory)")
            continue
        missing = sorted(n for n in names if n not in have)
        report('FAIL' if missing else 'PASS',
               f"{prov}.prx descriptor does not export {missing} (merge upstream tools/build_wine_ps5.sh "
               "into the list in scripts/prx-ps4.sh)" if missing else
               f"{prov}.prx descriptor exports all {len(names)} required names")

    # 6. Guest-fault diagnostics in the 32-bit kernelbase.
    kb = os.path.join(cand, I386, 'kernelbase.dll')
    n = sum(1 for x in strings(kb) if 'PW_EXCEPTION32' in x) if os.path.isfile(kb) else 0
    report('PASS' if n else 'FAIL', f"i386 kernelbase.dll PW_EXCEPTION32 strings: {n}")
    # ⚠ Present is not reached. A title always takes UnhandledExceptionFilter's
    # no_debugger branch, which returns before start_debugger(); unless that
    # branch calls the logger (archive 1012, series 1049), the strings above
    # are dead code and a guest fault leaves no PW_EXCEPTION32 record.
    if args.upstream_root:
        dbg = os.path.join(args.upstream_root, '.deps/wine-host/source/dlls/kernelbase/debug.c')
        if os.path.isfile(dbg):
            src = open(dbg, errors='replace').read()
            m = re.search(r'if \(no_debugger\)\s*\{(.*?)\n        \}', src, re.S)
            ok = bool(m and 'log_exception_context32' in m.group(1))
            report('PASS' if ok else 'FAIL',
                   'kernelbase no_debugger path calls log_exception_context32' if ok else
                   'kernelbase no_debugger path never calls log_exception_context32: PW_EXCEPTION32 '
                   'is compiled in but unreachable in a title (port archive 1012)')
        else:
            report('WARN', f"{dbg} missing; PW_EXCEPTION32 reachability not checked")

    # 7. Signal-mask operations must use FreeBSD values (SIG_BLOCK=1, UNBLOCK=2, SETMASK=3).
    if args.elf_dir:
        for name in ('ntdll', 'wineserver'):
            elf = os.path.join(args.elf_dir, name + '.shared.elf')
            if not os.path.isfile(elf):
                report('WARN', f"{elf} missing; signal-mask check skipped")
                continue
            dis = subprocess.run(['objdump', '-d', '--no-show-raw-insn', elf],
                                 capture_output=True, text=True).stdout.splitlines()
            zero = 0
            for i, line in enumerate(dis):
                if re.search(r'call\s+\S+ <(pthread_sigmask|sigprocmask)(@plt)?>', line):
                    window = ' '.join(dis[max(0, i - 5):i])
                    if re.search(r'xor\s+%edi,%edi', window) and not re.search(r'mov\s+\$0x[0-9a-f]+,%edi', window):
                        zero += 1
            report('FAIL' if zero else 'PASS',
                   f"{name}: {zero} sigmask call(s) pass 0 (Linux SIG_BLOCK; invalid on the PS4) - rebuild "
                   "the objects compiled before the orbis-compat signal.h fix" if zero else
                   f"{name}: no sigmask call passes Linux SIG_BLOCK=0")
    else:
        report('WARN', 'signal-mask check skipped (pass --elf-dir)')

    # 8. Payload manifest against the baseline.
    def files(root):
        out = set()
        for d, _, fs in os.walk(root):
            for f in fs:
                rel = os.path.relpath(os.path.join(d, f), root)
                if not rel.endswith(('.pkg', '.log')) and rel not in ('pkg.gp4', 'sce_sys/param.sfo'):
                    out.add(rel)
        return out
    bf, cf = files(base), files(cand)
    if not bf:
        report('FAIL', f"baseline stage {base!r} holds no payload files: it is not an unpacked package "
                       "stage, so the comparison would pass vacuously")
    else:
        gone = sorted(bf - cf)
        report('WARN' if gone else 'PASS', f"{len(gone)} baseline payload files absent from candidate"
               + (': ' + ', '.join(gone[:12]) + (' ...' if len(gone) > 12 else '') if gone else ''))

    # 9. PS4-specific strings present in the baseline but not the candidate (review list).
    for name in ('ntdll', 'win32u', 'wineserver', 'winevulkan', 'libvulkan', 'xinput1_3'):
        a, b = module(base, name), module(cand, name)
        if not (os.path.isfile(a) and os.path.isfile(b)):
            continue
        only = sorted(x for x in strings(a, 10) - strings(b, 10)
                      if INTEREST.search(x) and not x.startswith('/'))
        if only:
            report('WARN', f"{name}: {len(only)} PS4-specific baseline strings missing; review each: "
                           + ' | '.join(o[:60] for o in only[:6]) + (' ...' if len(only) > 6 else ''))

    # 10. Capability providers in the PE payload. Check 9 above only reads sce_module/*.prx,
    # so it cannot see the PE side at all -- and the PE side is where several capability
    # providers live, because win/wine/lib/wine/<arch>-windows/ is built from the wine-HOST
    # tree while the PRXs come from wine-ps5 (src/wine-trees/README.md). A provider can
    # therefore vanish from a package with every PRX check still passing.
    #
    # That is not hypothetical: Orbis-Win 02.17 and Playden 01.26 shipped the hosted-driver
    # provider in both architectures, and 02.69 / Playden 01.31 / 01.34 do not. It was lost
    # when the build moved to the pinned wine-host tree (0f6e2e67), which carries neither
    # archive patch 1043 nor 1076 -- the implementation lives only in wine-ps5. Nothing
    # failed, because scripts/ps4-kit-view.py derives its claims from the staged provider:
    # it honestly stopped claiming wine-driver-threads, so the capability silently
    # disappeared from the kit instead of the build complaining. AGENTS.md's additive rule
    # says a known-good fix must be preserved in every new package, so losing a provider the
    # baseline shipped is a hard failure, not a review note.
    #
    # A marker is given as text and matched in BOTH encodings, because a PE carries both and
    # which one a provider lands in is an implementation detail of the code that reads it.
    # WINE_NTOSKRNL_HOSTED below is the opt-in switch for this very capability and it is a
    # UTF-16 literal (RTL_CONSTANT_STRING / GetEnvironmentVariableW), so an ASCII-only scan --
    # `strings` without -el, and the first draft of this check -- reports it absent from every
    # package including the known-good ones. Checking the provider but not its switch would
    # pass a package whose capability cannot actually be turned on.
    def marker_in(path, text):
        data = read(path)
        return text.encode('ascii') in data or text.encode('utf-16-le') in data

    PE_PROVIDERS = (
        ('wine-driver-threads', 'ntdll.dll', 'hosted driver thread'),
        ('wine-driver-threads', 'ntoskrnl.exe', 'wine_ntoskrnl_host_start'),
        ('wine-driver-threads', 'ntoskrnl.exe', 'WINE_NTOSKRNL_HOSTED'),
    )
    lost, kept = {}, set()
    for cap, fname, marker in PE_PROVIDERS:
        for arch in ('i386-windows', 'x86_64-windows'):
            rel = os.path.join('win', 'wine', 'lib', 'wine', arch, fname)
            a, b = os.path.join(base, rel), os.path.join(cand, rel)
            if not (os.path.isfile(a) and os.path.isfile(b)):
                continue
            if marker_in(a, marker):
                if marker_in(b, marker):
                    kept.add(cap)
                else:
                    lost.setdefault(cap, []).append(f'{arch}/{fname} ({marker})')
    for cap, where in sorted(lost.items()):
        report('FAIL', f"the {cap} provider is in the baseline but gone from the candidate "
                       f"({', '.join(dict.fromkeys(where))}). The PE side builds from the wine-HOST tree, so "
                       'restore the provider there (the wine-ps5 copy does not reach these '
                       'files) -- otherwise the kit view just stops claiming the capability '
                       'and the package ships quietly degraded')
    for cap in sorted(kept - set(lost)):
        report('PASS', f'the {cap} provider is still present in the PE payload')

    # 11. Every module that carries the direct-memory glue must carry the SAME glue.
    #
    # The glue is compiled twice: scripts/prx-ps4.sh builds it fresh for the PRXs, and
    # scripts/prepare-ps4-toolchain.sh bakes it into build/ps4-wine-sdk/libps4stubs.a, which is
    # then CACHED and reused. BUILDING-FROMSOURCE.md already warns that a stamp "keyed too
    # narrowly" silently skips a src/native change and ships the previous objects.
    #
    # That is not hypothetical. Orbis-Win 02.91 shipped with the two modules disagreeing:
    # relocated_wine_app.prx had the current glue while sce_module/ntdll.prx had a six-week-old
    # copy whose exec_migrate_range_max() defaulted to 256 KiB instead of unlimited. ntdll.prx is
    # where map_image_into_view runs, so ITS copy won. Every exec mapping took the per-page path
    # the source comment reserves for Hollow Knight and explicitly warns 32-bit titles away from
    # ("unset / 0 -> no limit (default; 32-bit titles must stay here)").
    #
    # The visible cost was a completely dead controller in GTA IV: xinput1_4.dll's .text never
    # became executable, DllMain faulted c0000005 at its own instruction address, and
    # dlls/xinput9_1_0/main.c then returned ERROR_DEVICE_NOT_CONNECTED from every entry point for
    # the life of the process. Nothing in the build complained; the package was green.
    #
    # The invariant is cheap to state: any module holding the range-max format string must also
    # hold the default label the CURRENT source emits. A module with the format string but
    # without the label was built from an older glue.
    GLUE_FORMAT = 'exec-migrate-range-max'
    GLUE_CURRENT = 'default-unlimited'
    stale_glue, fresh_glue = [], []
    for prx in sorted(glob.glob(os.path.join(cand, 'sce_module', '*.prx'))):
        data = read(prx)
        if GLUE_FORMAT.encode('ascii') not in data:
            continue
        (fresh_glue if GLUE_CURRENT.encode('ascii') in data else stale_glue).append(
            os.path.basename(prx))
    if stale_glue and fresh_glue:
        report('FAIL', f"dmem glue mismatch: {', '.join(stale_glue)} carries an older "
                       f"pw_wine_dmem_glue_ps4 than {', '.join(fresh_glue)} (no "
                       f"'{GLUE_CURRENT}'). ntdll.prx's copy is the one that governs "
                       'exec protection, so a stale one silently caps exec-migrate at 256 KiB '
                       'and breaks 32-bit titles. Delete the objects AND '
                       'build/ps4-wine-sdk/libps4stubs.a, re-run prepare-ps4-toolchain.sh + '
                       'prx-ps4.sh, and confirm with: strings <pkg>/sce_module/ntdll.prx | '
                       f'grep -c {GLUE_CURRENT}')
    elif stale_glue:
        report('WARN', f"every module with the dmem glue ({', '.join(stale_glue)}) lacks "
                       f"'{GLUE_CURRENT}'; if the current source still emits that label they "
                       'were all built from a stale libps4stubs.a')
    elif fresh_glue:
        report('PASS', f"the dmem glue agrees across {len(fresh_glue)} module(s) "
                       f"({', '.join(fresh_glue)})")

    print(f"\n{'NOT INSTALLABLE' if failures else 'hard gates passed'}: {failures} FAIL")
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
