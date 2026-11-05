#!/usr/bin/env python3
"""Map every payload file of a package stage to the build output that produced it.

    scripts/stage-provenance.py STAGE --root DIR [--root DIR ...] [--tsv OUT]

Walks each --root (build trees, install trees, PRX output directories) and
indexes files whose size matches some stage file, then reports, for every
stage file, the build-output paths with byte-identical content. Directories
that are themselves package stages or extracts (pkg-stage, pkg-extracted,
uroot, base-stage, preserved-payload, install-version-*) are skipped, so a
file is attributed to the build that made it, not to a stage it was copied
through.

Use it to turn "the stage that worked" into a reproducible recipe: every
payload must resolve to a build directory whose source and command are known.
Unresolved files are the provenance gaps to close before CI can rebuild it.
"""
import argparse
import collections
import hashlib
import os
import re
import sys

SKIP_DIRS = re.compile(r'^(pkg-stage|pkg-extracted|uroot|base-stage|preserved-payload|'
                       r'install-version-.*|package-extract|\.git|stubs)$')


def sha(path, cache={}):
    if path not in cache:
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        cache[path] = h.hexdigest()
    return cache[path]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stage')
    ap.add_argument('--root', action='append', required=True)
    ap.add_argument('--tsv', help='write rel-path<TAB>sha256<TAB>sources')
    args = ap.parse_args()

    stage = {}
    for d, _, fs in os.walk(args.stage):
        for f in fs:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, args.stage)
            if rel.endswith(('.pkg', '.log')) or rel in ('pkg.gp4', 'sce_sys/param.sfo'):
                continue
            stage[rel] = p
    sizes = collections.defaultdict(list)
    for rel, p in stage.items():
        sizes[os.path.getsize(p)].append(rel)

    by_hash = collections.defaultdict(list)
    for root in args.root:
        for d, dirs, fs in os.walk(root, followlinks=False):
            dirs[:] = [x for x in dirs if not SKIP_DIRS.match(x)]
            for f in fs:
                p = os.path.join(d, f)
                try:
                    if os.path.islink(p) or os.path.getsize(p) not in sizes:
                        continue
                    by_hash[sha(p)].append(p)
                except OSError:
                    continue

    rows, per_root, unresolved = [], collections.Counter(), []
    for rel in sorted(stage):
        h = sha(stage[rel])
        srcs = sorted(by_hash.get(h, []), key=lambda s: os.path.getmtime(s))
        rows.append((rel, h, srcs))
        if srcs:
            root = next((r for r in args.root if srcs[0].startswith(r.rstrip('/') + '/')), '?')
            per_root[root] += 1
        else:
            unresolved.append(rel)

    if args.tsv:
        with open(args.tsv, 'w') as out:
            for rel, h, srcs in rows:
                out.write(f"{rel}\t{h}\t{' | '.join(srcs)}\n")
    print(f"{len(stage)} payload files; resolved {len(stage) - len(unresolved)}; unresolved {len(unresolved)}")
    for root, n in per_root.most_common():
        print(f"  {n:5}  oldest match under {root}")
    if unresolved:
        print("unresolved (no byte-identical build output under any --root):")
        for rel in unresolved:
            print(f"  {rel}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
