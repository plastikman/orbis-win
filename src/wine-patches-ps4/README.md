# PS4 Wine patches (ps5 tree)

These apply to **`.deps/wine-ps5/source`** — the unix/PRX side: `ntdll.prx`,
`win32u.prx`, `wineserver.prx`, `libvulkan.prx`. PE-side changes live in
`src/wine-patches-host/`; see that README for why the distinction matters.

Audit presence **by content, never by patch number** — upstream reuses numbers:

    scripts/audit-patch-presence.py src/wine-patches-ps4 <wine-ps5> <wine-host>

## This series does not reproduce the tree

As of 2026-11-16 that audit reports, over 310 patches:

    157 present    112 absent    40 partial    1 no-code

Most of the absent ones are tracing that was added and later removed; the
partial ones are code upstream has since rewritten underneath us. The series is
for review and porting — what a change was, and which tree it belongs to.

To rebuild a tree, use the pinned bundles in `src/wine-trees/`
(`scripts/restore-wine-trees.sh`), which are verified to restore both trees
byte-for-byte.
