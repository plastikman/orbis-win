# Host-tree Wine patches

⚠ These apply to **`.deps/wine-host/source`**, not `.deps/wine-ps5/source`.

Orbis-Win builds from TWO separate Wine checkouts:

- `.deps/wine-ps5` → the unix side: `ntdll.prx`, `win32u.prx`, `wineserver.prx`, `libvulkan.prx`
- `.deps/wine-host` → the PE side: every Windows DLL under `win/wine/lib/wine/<arch>-windows/`

The package stages PE DLLs from `.deps/wine-host/install/usr/lib/wine/<arch>-windows/`,
which is why `build-abi4-package.sh` runs `make -C "$HOST_WINE/build" …` for kernelbase.

Editing `dlls/ntdll/loader.c` in the **wine-ps5** tree and rebuilding produced four
packages in a row whose shipped PE `ntdll.dll` was byte-identical and markerless
(2026-11-16). To change a PE-side DLL:

1. edit `.deps/wine-host/source/…`
2. `make -C .deps/wine-host/build dlls/<dll>/<arch>-windows/<dll>.dll`
3. install it the way the package stages it:
   `( cd $H/build && tools/install -m 644 -s --strip-program="tools/winebuild/winebuild --builtin --strip-cmd=<arch>-w64-mingw32-strip" -t $H/install/usr/lib/wine/<arch>-windows <dll> )`
4. build the package, then **verify by content in pkg-stage** — these scripts
   assemble from whatever artifacts exist and do not fail when a compile fails.

Note PE-side ntdll has no `getenv`; use `RtlQueryEnvironmentVariable_U`.
