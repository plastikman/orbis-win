# Wine tree pins

Orbis-Win builds from **two** Wine trees, and neither can be rebuilt from the
patch series. These pins make both reproducible from public sources.

| tree | builds | pinned HEAD |
|---|---|---|
| `.deps/wine-ps5/source`  | unix/PRX side: `ntdll.prx`, `win32u.prx`, `wineserver.prx`, `libvulkan.prx` | `b5acab7bff83d68b4d069cf67b0c41976dadd9d6` |
| `.deps/wine-host/source` | PE side: every DLL under `win/wine/lib/wine/<arch>-windows/` | `0f6e2e67f19abe47266d9816102711a63b124598` |

Both sit on the **same** upstream Wine base:

    490f6d5dcbb2a5047345b8af88d114bbcaad69a8
    d3dx: Check for NULL new_data in convert_dib_to_bmp()   (Andrey Gusev, 2026-09-07)

That commit is in public WineHQ `wine/wine`, so a pin is just that SHA plus the
delta bundle in this directory. Each bundle is ~0.5 MB.

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

Each bundle's port delta is one squashed commit, so it does not separate Leo's
prospero-win fork changes from ours. It pins *what was built*, which is what was
missing. Splitting fork-vs-ours is a separate job and does not block builds.

## Refreshing after tree changes

Re-run `scripts/pin-wine-trees.sh` after landing changes in either tree, and
commit the updated bundles. A pin that is stale is a pin that lies.
