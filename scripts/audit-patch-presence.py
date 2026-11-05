#!/usr/bin/env python3
"""Audit which archived PS4 patches are actually present in a source tree, by content.

    scripts/audit-patch-presence.py ARCHIVE_DIR TREE [TREE ...] [--json OUT] [--all]

ARCHIVE_DIR is a directory of .patch files (e.g. src/wine-patches-ps4). Each
TREE is a source root the patched files are looked up in, in order (for the
ABI-v4 Wine port: the Unix build tree, then the wine-host PE tree).

⚠ WHY BY CONTENT AND NOT BY NUMBER. The 2026-11 ABI-v4 sync lost PS4 patches
because the upstream series reused the same patch numbers for different patches
(40 collisions; e.g. archive 0878 "a headless surface on ps4" vs upstream 0878
"crypt32 root certificates"). A number- or filename-based check reports such a
patch as present. This script instead takes every substantive line a patch
adds and checks whether that exact line exists in the patched file of the tree.

Each patch is classified:
  present   >= 90% of its added lines are in the tree
  partial   30-90% (often superseded by an upstream rewrite; review it)
  absent    < 30%
  no-code   nothing substantive to check

and tagged "diagnostic" when its subject is a trace/log/report/dump-style
change. The default report lists absent and partial functional patches grouped
by component; --all lists every patch. A partial or absent result is a
worklist entry, not a verdict: confirm each one is either ported, superseded by
named upstream code, or deliberately excluded, and record that disposition.
"""
import argparse
import collections
import json
import os
import re
import sys

DIAGNOSTIC = re.compile(
    r'\b(trace|log|logs|report|dump|snapshot|sample|samples|name the|say where|'
    r'ask what|diagnos\w*|count|counters|tag|print|record|instrument|probe|watch)\b', re.I)
TRIVIAL = re.compile(r'[/*{}();,\s]*|/?\*.*|//.*|#(else|endif).*')
COMPONENTS = ('win32u', 'winevulkan', 'dinput', 'xinput', 'hidclass', 'winebus', 'dxgi',
              'd3d', 'user32', 'ntdll', 'server', 'kernelbase', 'ws2_32', 'iphlpapi',
              'secur32', 'crypt32', 'winmm', 'dsound', 'mmdevapi', 'faudio', 'dcomp',
              'gdi32', 'opengl', 'wow64')


def norm(line):
    return re.sub(r'\s+', ' ', line.strip())


def parse_patch(path):
    text = open(path, errors='replace').read()
    subject = re.search(r'^Subject: (?:\[PATCH[^\]]*\] )?(.*)$', text, re.M)
    subject = subject.group(1).strip() if subject else ''
    added, current = {}, None
    for line in text.splitlines():
        if line.startswith('+++ '):
            name = line[4:].split('\t')[0].strip()
            current = None if name == '/dev/null' else (name[2:] if name.startswith('b/') else name)
            continue
        if current and line.startswith('+') and not line.startswith('+++'):
            s = norm(line[1:])
            if len(s) >= 14 and not TRIVIAL.fullmatch(s):
                added.setdefault(current, []).append(s)
    return subject, added


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('archive')
    ap.add_argument('trees', nargs='+')
    ap.add_argument('--json', help='write every result to this file')
    ap.add_argument('--all', action='store_true', help='list every patch, not just the worklist')
    args = ap.parse_args()

    cache = {}

    def tree_lines(rel):
        for root in args.trees:
            p = os.path.join(root, rel)
            if os.path.isfile(p):
                if p not in cache:
                    cache[p] = {norm(l) for l in open(p, errors='replace')}
                return cache[p]
        return None

    rows = []
    for name in sorted(os.listdir(args.archive)):
        if not name.endswith('.patch'):
            continue
        subject, added = parse_patch(os.path.join(args.archive, name))
        total = found = 0
        missing_files = []
        for rel, lines in added.items():
            have = tree_lines(rel)
            total += len(lines)
            if have is None:
                missing_files.append(rel)
            else:
                found += sum(1 for s in lines if s in have)
        frac = found / total if total else None
        status = ('no-code' if not total else 'present' if frac >= 0.9 else
                  'partial' if frac >= 0.3 else 'absent')
        files = ' '.join(sorted(added))
        component = next((c for c in COMPONENTS if c in files), files.split('/')[1] if '/' in files else files)
        rows.append(dict(patch=name, subject=subject, status=status, found=found, added=total,
                         frac=None if frac is None else round(frac, 2),
                         diagnostic=bool(DIAGNOSTIC.search(subject)), component=component,
                         files=sorted(added), missing_files=missing_files))

    if args.json:
        with open(args.json, 'w') as out:
            json.dump(rows, out, indent=1)

    counts = collections.Counter(r['status'] for r in rows)
    print(f"{len(rows)} patches: " + ', '.join(f"{k}={counts[k]}" for k in
                                                ('present', 'partial', 'absent', 'no-code')))
    show = rows if args.all else [r for r in rows if r['status'] in ('absent', 'partial')]
    functional = [r for r in show if not r['diagnostic']]
    diagnostic = [r for r in show if r['diagnostic']]
    for title, group in (('FUNCTIONAL', functional), ('DIAGNOSTIC', diagnostic)):
        print(f"\n== {title} ({len(group)})")
        by = collections.defaultdict(list)
        for r in group:
            by[r['component']].append(r)
        for comp in sorted(by, key=lambda c: (-len(by[c]), c)):
            print(f"-- {comp} ({len(by[comp])})")
            for r in by[comp]:
                frac = '-' if r['frac'] is None else f"{r['frac']:.2f}"
                print(f"   {r['status']:<8}{frac:>5}  {r['patch'][:60]:<60} {r['subject'][:70]}")
    return 0


if __name__ == '__main__':
    import signal
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)   # quiet when piped into head/less
    sys.exit(main())
