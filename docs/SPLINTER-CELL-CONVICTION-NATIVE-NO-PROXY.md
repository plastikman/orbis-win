# Splinter Cell: Conviction without the game-directory proxy

The author's `dinput8.dll` proxy is a useful reference, but an Orbis-Win
package does not become proxy-free merely because the source patches exist.
The PS4 package must contain the matching PE modules and Unix companions, and
the game must be tested without `dinput8=n,b`.

## Native coverage

| Proxy behavior | Native runtime path | Required package input |
|---|---|---|
| Return a valid adapter when PS4 NSI cannot enumerate one | `iphlpapi` PS4 NetCtl fallback (Prospero-Win patch 1009; Orbis-Win archive 1038) | PS4-built `iphlpapi.dll` for both architectures; `WINE_PS4_NETCFG` is supplied by the app |
| Let Gear find the installed drive | `kernelbase` probes drive roots when no drive letters are published (Prospero-Win patch 1010; Orbis-Win archive 1072) | PS4-built `kernelbase.dll` for both architectures |
| Keep audio endpoint names from nesting | `mmdevapi` preserves persisted names (Prospero-Win patch 1011; Orbis-Win archive 1036) | PS4-built `mmdevapi.dll` for both architectures |
| Let DirectInput enumerate the title's XInput pad | PS5/PS4 Winebus HID bus (Prospero-Win patch 1013) | `winebus.sys` for both architectures and `winebus.prx` staged in both Wine's Unix directory and `sce_module` |
| Downmix the game's 5.1 stream to the console's stereo sink | Existing `pw_audio_mix.c` path | Present in the built runtime; no game-local proxy needed |
| Avoid the level-load worker deadlock without reducing gameplay workers | 32-bit `kernelbase.dll` recognizes the two known Conviction PE builds and changes the game's CPU tier to 1 while its loading-screen ticker is active, then restores the saved tier when either stop path runs | The pinned Wine host source must build the patched i386 `kernelbase.dll`; the package build forces `main.o` to recompile and checks its source marker |

The hook is restricted to the two known standalone and Ubisoft Connect builds.
It checks the image base, the tier-function signature, and all three ticker
call targets before patching; unknown game builds and other titles are left
alone. Remove `WINE_CPU_TOPOLOGY=1` from the test profile so the hook can save
and restore the game's normal tier. The old static setting remains a fallback,
but it keeps the game at one reported processor during gameplay too.

## Build and stage requirements

Build the PE files from the pinned, patched Wine source into
`$PW_ROOT/.deps/wine-ps5/pe/{i386,x86_64}-windows/`. The PS4 package build now
selects those files by default and fails if they are absent; this prevents a
stock host DLL from silently replacing a native fix. `scripts/prx-ps4.sh` also
links `winebus.so` as `winebus.prx`. The package gate compares the staged
`kernelbase.dll`, `iphlpapi.dll`, `mmdevapi.dll`, `winebus.sys`, and
`winebus.prx` byte-for-byte with those build inputs.

The source/build support for these paired modules is in
`plastikman/prospero-win` branch `codex/issue8-native-parity` (commit
`fd3c54f`). `src/prospero-win-HEAD.txt` pins that exact build revision, and
`scripts/ci/checkout-prospero-win.sh` selects it for local and source CI builds.
An older Prosperowin checkout does not produce all required PE inputs.

The cache-backed ABI-v4 package path applies
`src/wine-patches-ps4/conviction-loading-tier-abi4.patch` to its Wine host source
before rebuilding `kernelbase.dll`, then reverts the source edit. This carries
the same build-specific hook as the pinned host-Wine bundle into the cached
package build without leaving the cache's patch-series source dirty.

The first ABI-v4 package attempt with this hook compiled `kernelbase.dll` and
the PS4 PRXs, but stopped before staging a package: the attached ABI-v4 Wine
build predates the pinned Prosperowin Winebus patch and has no `winebus.so`
link input (`Build PS4 package`, run 45782989081). That cache is not a valid
input for testing the native DirectInput path. Refresh or rebuild the ABI-v4
Winebus PE and Unix outputs from the pinned patched Wine source, then rerun the
package parity and package validation gates. No package from this branch has
been installed or console-tested yet.

## Console validation

Use the same known-good Conviction install and prefix. Move the game-local
`dinput8.dll` proxy out of the game directory, remove `dinput8=n,b` from the
profile, and remove `WINE_CPU_TOPOLOGY=1` if it is present. Then verify one run
end to end: the loading-tier hook reports that it installed, logs tier
1 on load start and restores the saved tier on load completion; the adapter
fallback marker appears, the game
reaches its menu on repeated starts, DirectInput lists and accepts the
controller, Gear opens the sound packages and audio works in-game, and every
level load completes. Record the exact package build marker and check the staged
module hashes before attributing a successful run to these changes. A launch
without the proxy is not validated until this console run succeeds.

Until that console run passes, this is an implemented native path with package
wiring, not a verified replacement for the proxy.
