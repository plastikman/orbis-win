# Handoff: 64-bit rendering on PS4, the RoR2/HK stall, and Wine tree pins

Date: 2026-11-16 (America/Anchorage)
Tree: `/home/zpeirce/ps4-gladius`, branch `launcher-settings`
Companion: `docs/HANDOFF-2026-11-16-RELEASES.md` covers the separate Orbis-Win
v0.0.7 / Playden v0.3.1 release work from the same day. This handoff covers the
debugging line: *"i want to start on making the games that i have work, work."*

## Headline

**64-bit titles render on PS4 for the first time.** That was the blocker behind
Hollow Knight and Risk of Rain 2 showing nothing, and it is fixed and committed.

Neither title is finished. RoR2 now reaches **26%** and stalls there; HK reaches
spinning dots. Both are the *same remaining* defect, diagnosed but not fixed —
see "Where RoR2 and HK stand".

## What was wrong, and what fixed it

Two defects in the PS5 Vulkan driver path, both in `.deps/wine-ps5/source`:

1. **`ps5_map_device_extensions()` was an empty function.** The six extension
   name pairs that `nulldrv_map_device_extensions` carries were simply not
   there, so no 64-bit title could negotiate external memory.
   → patch `1036-win32u-ps5-map-external-memory-to-win32.patch`

2. **A failed `vkGetMemoryFdKHR` was treated as fatal.** This console's RADV
   answers `VK_ERROR_OUT_OF_DEVICE_MEMORY` (-2) when asked to export memory as
   an opaque fd. It cannot do it, and it does not need to: **the wineserver is a
   thread of the same process**, and `d3dkmt_create_resource` accepts `fd = -1`.
   The allocation is now kept and the export failure swallowed.
   → patch `1037-win32u-ps4-no-fd-export-keep-the-allocation.patch`

Commit `9033c14` — *Let 64-bit titles render: map external memory, and survive
no fd export*. Wine-ps5 commits `ff7bd4f32a` and `2a4609ff51`.

Fallout New Vegas was re-checked after the change and is **good** — no 32-bit
regression from the Vulkan work.

## Diagnostics built today

`4c0b47b` and `a146a57`. The 64-bit guest had no equivalent of the 32-bit
`PW_EXCEPTION32` records, so the first half of the day was spent making it
answerable at all:

- `dump_guest_stack64()` in `server/thread.c` — reads TEB+0x378
  (`syscall_frame`), `rip` at +0x70, `rsp` at +0x88. Wine's own saved PE
  context, not a guess from the unix stack.
- Wait-object identity (`obj=%p`) in wait dumps, `wake_up` tracing,
  `PW_PS4_POKE_REPEAT`.
- Futex wait/wake pairing in the **host** tree's `dlls/ntdll/sync.c`, tagged
  with `__builtin_return_address(0)` so a wait names its caller. PE-side ntdll
  has no `getenv`; the gate uses `RtlQueryEnvironmentVariable_U`.
- A guest sampler in `src/native/pw_wine_dmem_glue_ps4.c`, armed by
  `PW_PS4_GUEST_SAMPLER`.

Patches are written out split **by which tree they apply to** —
`src/wine-patches-ps4/1039`–`1042` (ps5/PRX side) and
`src/wine-patches-host/0001`–`0003` (PE side). That split is not cosmetic; see
"Standing hazards".

## Where RoR2 and HK stand

Diagnosed, not fixed. The evidence chain, in order:

1. The **poke workaround** (SIGALRM → EINTR, `PW_PS4_POKE_REPEAT`) took RoR2
   from 2% to 26% and freed HK's main thread. That it helps at all located the
   problem in waiting, not in rendering.
2. Every outstanding wait at the stall comes from **`RtlSleepConditionVariableSRW`**.
3. Those addresses **are** being woken — measured, not assumed.
4. The waits return `ret=00000101` = `STATUS_TIMEOUT`. They are *timed* waits in
   a loop, not a wedge.

**So the sync layer is behaving. A condition is never becoming true.** Several
earlier theories were tested and killed by measurement — "stuck in the heap"
(disproven by the real `rsp`), "the alert was dropped" (`PW_ALERT_DROPPED` = 0),
"EVFILT_USER doesn't wake kevent" (probe returned `wake=1`), and a pipe fix that
turned out to be a regression and was reverted in 02.53. Do not re-run those.

### Next lead: Wwise audio

The strongest remaining signal, and where to start next session:

- The main thread sits in `AkSoundEngine` → `WaitForSingleObject`.
- **Four Wwise worker threads are created and never exit.**
- There is no `mmdevapi` and no `xaudio2` in the process, and `audio=0`.

That shape — an audio engine waiting on worker threads that can never report
ready because there is no audio backend — fits "a condition never becomes true"
exactly. It is a hypothesis with good support, **not** a confirmed root cause.
Worth noting: the v0.0.7 release carried an MMDevAPI fix, so the audio-stack
picture may differ from what was measured here.

Last package used for this work: `~/codex_scratch/orbis-hk-0259`, runtime hash
`cbcaeb2c091642a0`, installer `IV0000-GLDS10043_00-GLDS100430000000.pkg`.

## Wine trees are now reproducible — verified

They were not, and the patch series never could rebuild them. Audited by
content over 310 patches: **157 present, 112 absent, 40 partial, 1 no-code.**
The absent ones are mostly tracing added and later removed; the partial ones are
code upstream rewrote underneath us. Worse, four port sources appear in **no
patch at all** — `dlls/ntdll/pw_qpc_clock.h`, `pw_title_menu.h`,
`unix/native_libkernel_resolver.{c,h}` — and were sitting untracked in
wine-host, one `git clean` from gone.

Both trees turned out to share one **public** upstream base,
`490f6d5dcbb2a5047345b8af88d114bbcaad69a8`, in WineHQ `wine/wine`. So each tree
is that SHA plus a delta, and the deltas bundle to ~0.5 MB each.

| tree | builds | pin |
|---|---|---|
| `.deps/wine-ps5/source` | `ntdll.prx`, `win32u.prx`, `wineserver.prx`, `libvulkan.prx` | `b5acab7bff` |
| `.deps/wine-host/source` | every PE DLL under `win/wine/lib/wine/<arch>-windows/` | `0f6e2e67f1` |

- `scripts/restore-wine-trees.sh <dir>` — rebuild both from upstream + bundles
- `scripts/pin-wine-trees.sh <source-root>` — re-export; **refuses a dirty tree**

**Proof, not assertion:** restored both on the build host from a fresh WineHQ
clone and diffed against the live trees — **0 differing paths each.** Commit
`879709c`.

Two defects the verification caught, which would otherwise have shipped as a pin
that silently did not restore:

- `--filter=blob:none` leaves the base commit's blobs lazy, so checking out a
  pinned HEAD asks WineHQ for *our* commit: `fatal: not our ref`.
- The bundles' only ref is `HEAD`, so a `refs/*` refspec matches nothing and
  **fetches silently**, leaving a repo that cannot check out the pin.

Both are guarded in the scripts now.

**Standing rule: re-pin after landing changes in either tree.** A stale pin
lies, and the pin is the only thing between us and another irreplaceable tree.

Caveat: each delta is one squashed commit, so it does not separate Leo's
prospero-win fork changes from ours. It pins *what was built*, which is what was
missing. Splitting that is separate work and blocks nothing.

## Carried but untested

- **Dare engine / `GetAdaptersInfo` fallback** from `codex/splinter-adapter-0239`,
  as `1038-iphlpapi-ps4-legacy-adapter-info.patch`. Marker to look for:
  `PW_ADAPTERS_INFO PS4 NetCtl fallback`. Needs a Splinter Cell run to confirm.

## Standing hazards (these cost real time today)

- **Two trees.** PE DLLs build from `wine-host`; PRXs from `wine-ps5`. Editing
  `dlls/ntdll/loader.c` in the wrong tree produced four consecutive packages
  with a byte-identical, markerless PE `ntdll.dll`.
- **The build scripts assemble; they do not compile.** `prx-ps4.sh` and
  `radv-prx-ps4.sh` relink from whatever objects exist. **A green build proves
  nothing** — verify artifact content (`strings` / `sha256sum`) in pkg-stage.
  Stale artifacts shipped four separate times today.
- **`PS4_DEV_CONF=<host>:<port>` is mandatory** on a test build or the runtime
  logs nowhere. Package 03.06 shipped without it and produced two completely
  silent runs that were briefly misread as success.
- **Never create `/data/<TITLE_ID>/`.** Doing so moved the runtime data root and
  made every Orbis-Win game disappear.
- **Do not cap debug output.** Thread/hit/sample caps set small destroyed the
  very data the runs existed to collect, three times.

## Open items

1. **RoR2 26% / HK hang** — chase the Wwise worker-thread lead above.
2. Test the Dare engine adapter fallback with Splinter Cell.
3. DXVK has no build script; `dxvk-instrumented/` is hand-staged.
4. Playden kit update is unsupported on PS4 — `update_service.cpp` is not in
   `ps4/CMakeLists.txt`.
5. `/data/playden/dev/web-probe` is still on the console, inert. **Not
   authorised for deletion** — ask before removing.
6. From the release handoff: install and test Playden 0.3.1 on-console, and keep
   the Orbis-Win full-source build failure visible (v0.0.7 was a repackage).

## Workspace

`launcher-settings` is clean apart from the untracked `worktrees/` directory,
which predates this work — **inspect before cleaning**. Wine tree work happened
on the build host `slackian` under
`~/codex_scratch/abi4-upstream-port-20261104/source/.deps/`; pins and the
restore verification are in `~/codex_scratch/wine-tree-pins-2026-11-16` and
`~/codex_scratch/wine-pin-verify-2026-11-16`.
