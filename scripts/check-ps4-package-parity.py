#!/usr/bin/env python3
"""Check a PS4 package stage for the port's required behaviour before any install.

    scripts/check-ps4-package-parity.py BASELINE_STAGE CANDIDATE_STAGE \
        [--elf-dir PRX_BUILD_DIR] [--upstream-root PROSPERO_WIN_SOURCE]

BASELINE_STAGE is the last known-good package stage (e.g.
pkgout/falloutnv-no-relro-kept-data-1090/pkg-stage). CANDIDATE_STAGE is the
stage about to be packaged. --elf-dir is the PRX build directory holding the
candidate's unstripped *.shared.elf files (enables the signal-mask check).

Every hard gate below failed silently at least once during the 2026-11 ABI-v4
sync, each costing console cycles; see docs/UPSTREAM-SYNC-PLAYBOOK.md. A
FAIL means: do not install. WARN items need a written disposition.
Exit status: 0 = no FAIL, 1 = at least one FAIL.
"""
import argparse
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

    # 1. Relocation: the eboot must be the no-RELRO stub that loads the app PRX.
    eboot = os.path.join(cand, 'eboot.bin')
    app = module(cand, 'relocated_wine_app')
    eb = read(eboot)
    if b'/app0/sce_module/relocated_wine_app.prx' in eb and len(eb) < 200_000:
        report('PASS', f"eboot.bin is the relocation stub ({len(eb)} bytes, loads relocated_wine_app.prx)")
    else:
        report('FAIL', f"eboot.bin ({len(eb)} bytes) does not load relocated_wine_app.prx: "
                       "the full app at 0x400000 was packaged instead of the no-RELRO stub")
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

    # 4. PS4 RADV, not the upstream bundle's driver.
    v = strings(module(cand, 'libvulkan'))
    ps4_radv = [x for x in v if x.startswith(('PW_ORBIS_VA_FAIL', 'wsi/orbis: 0031', 'RADV_ALLOC_CMD_BUFFER'))]
    report('PASS' if ps4_radv else 'FAIL', 'libvulkan.prx is the PS4 RADV (mesa-ps4 + src/mesa-patches-ps4)'
           if ps4_radv else 'libvulkan.prx lacks the PS4 Mesa markers: rebuild it with scripts/radv-prx-ps4.sh')

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

    print(f"\n{'NOT INSTALLABLE' if failures else 'hard gates passed'}: {failures} FAIL")
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
