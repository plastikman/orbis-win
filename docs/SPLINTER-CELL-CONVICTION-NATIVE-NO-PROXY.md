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
| Avoid the level-load worker deadlock | Existing `WINE_CPU_TOPOLOGY` support (Prospero-Win patch 1012; Orbis-Win archive 1070) | Game profile sets `WINE_CPU_TOPOLOGY=1` in `[environment]` |

The CPU setting is a static fallback: it keeps the game at one reported
processor during gameplay too. The proxy switches back to the full tier after
the loading ticker stops. Do not claim exact behavioral parity or performance
until the static profile is tested. If static topology makes the levels load
but materially hurts gameplay, implement the loading-only switch separately.

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

## Console validation

Use the same known-good Conviction install and prefix. Remove
`dinput8=n,b` from the profile and add:

```ini
[environment]
WINE_CPU_TOPOLOGY=1
```

Then verify one run end to end: the adapter fallback marker appears, the game
reaches its menu on repeated starts, DirectInput lists and accepts the
controller, Gear opens the sound packages and audio works in-game, and every
level load completes. Record the exact package build marker and check the staged
module hashes before attributing a successful run to these changes.

Until that console run passes, this is an implemented native path with package
wiring, not a verified replacement for the proxy.
