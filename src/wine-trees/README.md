# Wine tree pins

Orbis-Win builds from **two** Wine trees, and neither can be rebuilt from the
patch series. These pins make both reproducible from public sources.

| tree | builds | pinned HEAD |
|---|---|---|
| `.deps/wine-ps5/source`  | unix/PRX side and PS4 PE modules, including the `iphlpapi` NetCtl fallback | `a11ae8d200471bd1d93ee2e8b9413492e1712537` |
| `.deps/wine-host/source` | PE side: every DLL under `win/wine/lib/wine/<arch>-windows/` | `dd0c9ea4f245dd5984cddc9c8dd11306ab4fe185` |

Both sit on the **same** upstream Wine base:

    490f6d5dcbb2a5047345b8af88d114bbcaad69a8
    d3dx: Check for NULL new_data in convert_dib_to_bmp()   (Andrey Gusev, 2026-09-07)

That commit is in public WineHQ `wine/wine`, so a pin is just that SHA plus the
delta bundle in this directory. The current host bundle is 471,059 bytes and
the PS5 bundle is 630,663 bytes.

## Restore

    scripts/restore-wine-trees.sh <destination-dir>

which is, per tree:

    git clone --filter=blob:none --no-checkout https://gitlab.winehq.org/wine/wine.git <tree>
    cd <tree>
    git fetch ../path/to/<tree>-ps4-delta.bundle 'refs/*:refs/restored/*'
    git checkout --detach $(cat <tree>-HEAD.txt)

## Why not the patch series

`scripts/audit-patch-presence.py src/wine-patches-ps4 <wine-ps5> <wine-host>`
reports, by content, over 310 patches:

    157 present    112 absent    40 partial    1 no-code

The absent ones are overwhelmingly tracing that was added and later removed
(`1019-wow64cpu-log-*`, `0977-winevulkan-trace-*`, `0987-iphlpapi-log-*`); the
partial ones are code upstream has since rewritten under us. Worse, port
sources that no patch contains at all — `dlls/ntdll/pw_qpc_clock.h`,
`dlls/ntdll/pw_title_menu.h`, `dlls/ntdll/unix/native_libkernel_resolver.{c,h}`
— were untracked files in wine-host until this pin. Replaying the series
produces a tree that does not build and is not what shipped.

The series stays useful for **review and porting** (what a change was, and
which tree it belongs to). The bundles are what reproduce a build.

## Caveat

The PS5 bundle's port delta is one squashed commit plus the incremental
`iphlpapi` commit `a11ae8d` (the PS4 NetCtl `GetAdaptersInfo` fallback, ported
from prospero-win's patch 1009 and archived as Orbis-Win patch 1038). The host
bundle contains that same kind of port snapshot plus the incremental Conviction
loading-tier hook commit. The original snapshot does not separate Leo's
prospero-win fork changes from ours. The pins record *what was built*, which is
what was missing; splitting fork-vs-ours is a separate job and does not block
builds.

## Refreshing after tree changes

Re-run `scripts/pin-wine-trees.sh` after landing changes in either tree, and
commit the updated bundles. A pin that is stale is a pin that lies.
