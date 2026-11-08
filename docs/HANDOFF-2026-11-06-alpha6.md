# Handoff — 2026-11-06: alpha.6 candidate waiting for its hardware run

> **Superseded by [HANDOFF-2026-11-08.md](HANDOFF-2026-11-08.md)** for the current state. This file keeps the history.

**State:** GLDS10043 **01.38** is built and uploaded to the console's `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg` (readback hash matched). Zak will install it and run the titles later.

- Package `codex_scratch/release-0138/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`, sha256 `cdd5723bb7b58471b6c051def4c09dc132a77fae1f9dab3480c81b4d25702464`.
- Built release-style: no `dev.conf` inside (`app_log=none`). This exact file is the alpha.6 package if it passes.
- Provenance:
  - `root_commit=9749fcd` (orbis-win `main`);
  - `prospero_win_abi4_commit=108194e` (fork `main`), empty diff.
- Gates: parity 0 FAIL (WARN: no `dev.conf`, expected); `pkg_validate` all OK.

**What 01.38 adds over alpha.5 (01.35):**
- `[input] mouse = touchpad`: the touchpad as a trackpad-style pointer. Smoothed; the default speed is 400 when the profile sets no `mouse_speed`.
- The log switch: a package without `/app0/dev.conf` logs when `/data/prospero-win/dev.conf` exists. ⚠ It exists on the console now, so every launch logs until it is deleted.
- Half-Life 2 (`src/profiles/half-life-2.profile`): Options opens the pause menu, the touchpad is the mouse, `mouse_speed = 400`.

**Test plan:** nine titles. Load each and quit to the launcher; Bloodlines' quit hang is known.
- GTA IV, FNV, FO3, Oblivion (native);
- MDK (translator);
- Half-Life (Zink), Bloodlines, Titan Quest, Half-Life 2.
- In Half-Life 2 also check that the touchpad no longer darts.

**If all pass:**
1. Publish `v0.0.1-alpha.6` from `codex_scratch/release-0138/`, the same way as alpha.5: `gh release create … --prerelease --target 9749fcd`, attaching the `.pkg`, `BUILD-MANIFEST.txt` and `parity.txt` (alpha.5 uploaded them renamed with the version, e.g. `BUILD-MANIFEST-01.35.txt`). Use alpha.5's notes plus a section for these three additions.
2. Cancel the tag's workflow run; it fails at the version step.
3. Promote the 01.38 stage as the baseline (`pkgout/abi4-0138-baseline`, repoint `pkgout/baseline`).

**Still open:**
- CI cache re-sync: `scripts/ci/sync-cache.sh --abi4-only`, before the next CI build.
- Titan Quest: the descriptor ceiling (~512 by number vs RLIMIT 1443) and the controller layout.
- Bloodlines' quit hang.
- The translator crash in Titan Quest.
- A controller pass for Half-Life (`goldsrc`).

## Update: published without the full run (Zak: "publish to GH")

- **`v0.0.1-alpha.6` is published**: https://github.com/plastikman/orbis-win/releases/tag/v0.0.1-alpha.6 (pre-release, tag at `9749fcd`).
  - Assets: the 01.38 `.pkg` (501,219,328 B, sha256 `cdd5723b…`), `BUILD-MANIFEST-01.38.txt`, `parity-01.38.txt`.
  - The tag's workflow run 42265536858 was cancelled.
- The release notes say plainly that this package has **not** had the nine-title run. Each title's last result and build are listed: Half-Life 2 on 01.37, the rest on 01.34.
- **The baseline stays 01.34** until 01.38 passes the nine titles. Then promote `pkgout/abi4-0138-baseline` as planned above.

## Update (16:30–17:15): install guide tested end to end; New Vegas idle

- **`docs/INSTALLING-GAMES.md`** (new): installing games and troubleshooting them. Its quick start was run as written from a fresh Debian 13 Hyper-V VM to the console with Half-Life 2 (Zak: "everything works").
  - Route: upstream prospero-win's `tools/build_host_wine.sh` (26 min on the VM), then `tools/build_wowprospero.sh --build .deps/wine-host/build --source .deps/wine-host/source` (10 s, no second Wine build). Next, `wineboot --init` with `USER=prospero`, `WINEARCH=win64`, `WINEDLLOVERRIDES='winemenubuilder.exe=d;mshtml=;mscoree='`. Then the game files and DXVK 2.6.2 x32. Last, `pw_prefix.py push --port 2121` (3,183 files, 5.23 GiB, 5 min 41 s).
  - **`pw_prefix.py` works against GoldHEN's FTP server.** Its anonymous login did not crash it, unlike `lftp` on 2026-10-06.
  - **Don't make prefixes with the old host Wines here.** `prospero-win/.deps/wine-host` (2026-10-08) carries `PW_WOW64_PRE_IRET` diagnostics: its 32-bit side overflows the stack, so `syswow64` stays empty. `abi4-upstream-port-20261104/source/.deps/wine-host` crashed its wineserver in `wineboot`. The working one is `codex_scratch/quickstart-test/ps4-wine/prospero-win/.deps/wine-host`.
  - The fresh prefix matches the old console one: 17,087 vs 17,080 registry keys, the same DXVK sizes. Font values name host paths (`Z:\home\...`) in both; on the console Wine adds `Z:\app0\...` entries.
- **Console Half-Life 2 is now the end-to-end prefix.** The old one was renamed `/data/prospero-win/prefixes/half-life-2.before-e2e-20261106` (~5 GB); Zak is deleting it from the console. GoldHEN refuses `MLSD` (501), so `pw_prefix.py pull`/`status`/`--trust-size` do not work on the PS4; the guide says so. `hl2/cfg/autoexec.cfg` (`joy_inverty 1`) was restored into the new prefix. The `pw_prefix` manifest for this prefix is in the VM test library (`codex_scratch/quickstart-test/ps4-wine/prospero-library/.pw/`). A push from 10.168.2.188's library would now need `--force`.
- **New Vegas idle, 01.38: no stall.** Zak left it idle; it ran 62 min and quit normally (`session_end reason=guest-exit`, no `PW_EXCEPTION32`). `flexible_free` was flat at 303,104 KiB from minute 55 to 62. On 2026-11-04 (1102 A/B) it reached 0 KiB at ~48 min and graphics stalled. The session log keeps only the last ~2 MiB, so minutes 0–55 are not on record. Logs: `codex_scratch/quickstart-test/fnv-idle/session-0*.log`.

## Update (17:50–18:05): Fallout 3 crash opening the Pip-Boy, 01.38

- **Crash** (`session-1.log`, profile `fallout3-gog`, native, about 12 min in, Zak opening the Pip-Boy):
  1. DXVK failed an 8,355,840-byte allocation (32 KiB alignment, types 0,2,3,5) for a 1920x1080 `A8R8G8B8` render target (`d3dFormat=0x15`, `vkFormat=0x2c`, usage 0x1).
  2. D3D9 logged that the image had no backing storage.
  3. In the same millisecond, `Fallout3.exe` read `0x30` at EIP `0x006ECD51` (`mov ecx,[ecx+0x30]`, `ecx=0`) and Wine ended it.
- **Same signature as New Vegas** on its second V.A.T.S. entry, 2026-11-04 (`HANDOFF-2026-11-03.md`): the same 8.36 MB texture failure, then a `0x30` read in the same millisecond. Fallout 3 already has `iMultiSample=0`, and there were none of the 75 MB depth failures, so MSAA is not the cause here.
- **Memory looked healthy:**
  - DXVK heap 0: 314 of 661 MiB used.
  - `flexible_free=301056K`, `dmem_failures=0`; dmem flat around 805 MiB for two minutes.
  - No `PW_RADV_*` or `PW_ORBIS_*` records in the session log. klog had been silent since 15:17 (receiver connected, nothing arriving).
- **Repro attempt:** about 9 min, Pip-Boy opened, clean exit, no failure.
- **Diagnostic gap:** Fallout 3 loads DXVK from the game folder, `C:\Games\Fallout3\d3d9.dll`. That file is diagnostic7 (`96373c2d…`) and has no per-allocation trace; `syswow64/d3d9.dll` is Wine's built-in one.
- **Next, if pursued:**
  - Swap in diagnostic8, `fnv-d3d-alloc-trace-1082/d3d9-diagnostic8.dll` (`2a7a1447…`), which adds `PW_DXVK_VKALLOC_FAIL`.
  - Restart klog first.
  - New Vegas's traced failures came back VkResult -1 (`VK_ERROR_OUT_OF_HOST_MEMORY`), pointing at mapping into the 32-bit address space rather than GPU memory. Unproven for this 8 MB case.
- **Artifacts** in `codex_scratch/fo3-crash-20261106/`:
  - `console-logs/` (session logs, including `session-1.previous.log`);
  - the live log `ps5logd.out`;
  - both fetched `d3d9.dll` files;
  - `FalloutPrefs.ini`.
- **Cause: the GPU arena is full.** L4D2 (19:36) failed the same way: a DXVK allocation failed, then a null read (`0x20` at `0x7789d2ce`).
  - The failed request was only 1,264 bytes. DXVK held 52 + 804 = 856 MiB; Fallout 3 held 384 + 436 = 820 MiB.
  - The orbis-drm arena is 1024 MiB: the top of `orbis_arena_ladder`, logged as `arena 1024 MiB, RADV's window 0x20a404000..0x248400000`, a 992 MiB window.
  - `orbis_query_memory` reports that pool as both VRAM and GTT, and RADV's APU path (`radv_physical_device_init_mem_types`) adds the two: 661 + 1,322 = 1,983 MiB advertised, about twice what exists.
  - DXVK's ~820–856 MiB plus RADV's own allocations fill the window.
  - `docs/FINDINGS.md` §3 notes another port ships `ORBIS_ARENA_MIB=1280` because 1024 ran out.
- **Proposed A/B** (not run):
  - Fallout 3 with `env = ORBIS_ARENA_MIB=1280` in `[debug]`, so only the arena size changes.
  - If it works, raise the ladder and/or report the real pool size so games see the true limit.
  - A forced size that the kernel refuses has no fallback, so Vulkan would fail at startup.
- **01.39 test package** (Zak: "Build and push"), on the console at `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`; the readback hash matched.
  - Package: `codex_scratch/candidate-0139/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`, sha256 `e3b9c113…adbd48`.
  - Change: 01.38 plus `ORBIS_` added to the `[debug] env` families in `src/pw_game_profile.c`, with matching header, doc and unit-test changes. 01.38 refused `ORBIS_ARENA_MIB` as `unsupported`.
  - These edits are uncommitted in `abi4-upstream-port-20261104/source`; provenance diff sha `e145dc38…`.
  - Gates: parity 0 FAIL (WARN: no `dev.conf`, expected).
  - Changed files vs 01.38:
    - `relocated_wine_app.prx`.
    - i386 `kernelbase.dll`: PE timestamp and checksum only (4 bytes); 25 `PW_EXCEPTION32` strings either way.
    - `param.sfo` and `pkg.gp4`.
  - Test: Fallout 3 with `env = ORBIS_ARENA_MIB=1280`, played until the Pip-Boy has been opened repeatedly.
- **First result on 01.39 with `ORBIS_ARENA_MIB=1280`** (L4D2, 19:54).
  - The launcher passed the variable on (`PW_WINE64 debug_env=ORBIS_ARENA_MIB`).
  - The game played past the point where 01.38 failed (~3.5 min); at 4+ min there was no `Memory allocation failed` and no exception.
  - At 19:58:41: `flexible_free=169984K`, `dmem=762880K`, `dmem_failures=0`.
  - Zak reports it working. The klog arena line was not captured.
  - Still to do: a Fallout 3 Pip-Boy run with the same line.

## Update (2026-11-07): GPU window extension in the PS4 RADV layer (01.40)

- **Fallout 3 idle on 01.39 without the arena variable:** ~45 min, `dmem_failures=0`, no allocation failures. The crash needs a heavier load, such as opening the Pip-Boy.
- **`/data/prospero-win/radv.log`** is rewritten on every launch (`MESA_LOG_FILE`, set by the launcher). The FO3 and L4D2 crash logs were already gone. `grab-radv-on-fail.py` in `codex_scratch/fo3-crash-20261106/` now copies it on the first failure.
- **Change** (Zak: "Let's do it at the ps4 layer"), in `mesa-build/mesa-ps4/src/amd/common/ac_orbis_drm.c`, uncommitted. Diff: `codex_scratch/fo3-crash-20261106/ext.diff`; pre-change copy beside it.
  1. **One reservation.** Arena setup reserves arena + extension addresses together, trying 4 GiB alignment first and then 2 MiB. It maps the arena into the front with `MAP_FIXED`. If that fails, the old unreserved mapping is used with no extension.
  2. **The extension opens after the window is protected.** `orbis_va_end` grows by `ORBIS_ARENA_EXT_MIB`, default 1024 (0 = off). The flat arena (`ORBIS_FLAT_ARENA`) gets no extension.
  3. **Its own memory per range.** A range mapped in the extension gets its own direct memory: GARLIC for VRAM buffers (ONION if GARLIC is refused), ONION otherwise. It is recorded by address (`orbis_ext_tab`), since RADV's pad page maps the same BO twice. Retirement through the existing retire queue (`orbis_protect_now`), or reuse of the addresses, re-reserves them and releases the memory. If re-reserving fails, the range is removed from the allocator permanently.
  4. **Allocator.** First-fit from the bottom, so a title that fits in the arena never uses the extension. No range may start in the arena and end in the extension.
  5. **The CPU alias (placed map) finds extension memory through the table.**
  6. **Honest sizes.** `orbis_query_memory` splits the pool 1/3 GTT, 2/3 VRAM, so RADV's APU sum equals the window instead of twice it. `query_heap_info` reports usage under VRAM only, so the budget counts it once. Expected heaps with the extension: ~672 + 1344 MiB over a ~2016 MiB window (was 661 + 1322 over 992).
- **Log markers in `radv.log`:**
  - `PW_ORBIS_EXT window …` / `PW_ORBIS_EXT none`;
  - `PW_ORBIS_EXT in use: … live, peak …`, once and then at every 64 MiB step;
  - failures: `PW_ORBIS_MAP_FAIL stage=ext-alloc|ext-map|ext-straddle|ext-table|ext-rereserve`.
- **Package 01.40**, uploaded to `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`; the readback hash matched.
  - Package: `codex_scratch/candidate-0140/app/…pkg`, sha256 `2307205c…c939`.
  - Gates: parity 0 FAIL (WARN: no `dev.conf`).
  - Changed vs 01.39: both copies of `libvulkan.prx` (`b6591dd6…`, 4 `PW_ORBIS_EXT` strings).
  - `relocated_wine_app.prx`: build-marker string only, same size.
  - i386 `kernelbase.dll`: PE timestamp only.
- **Test plan:**
  1. Remove `ORBIS_ARENA_MIB` from the L4D2 profile, so the extension alone has to carry it.
  2. Play past 3.5 min, and run Fallout 3 with Pip-Boy use.
  3. Pull `radv.log` before the next launch and check the `PW_ORBIS_EXT` lines.
  4. Smoke test FNV native + MDK translator; the change touches every Vulkan title.
- **01.40 results with L4D2.**
  - With `ORBIS_ARENA_MIB=1280` still in the profile (Zak's keybinding push restored it), it played without the earlier crash. FPS was "way better", probably from the honest budget (DXVK no longer sees itself over budget). Not measured.
  - Without the variable, it crashed at 09:20:07, ~5 min in. `radv.log` (`codex_scratch/fo3-crash-20261106/radv-092007-memory-1.log`): the extension was used in 128 MiB GARLIC ranges, up to 983,152 KiB live, then `PW_ORBIS_VA_FAIL stage=window-exhausted` for 128/64/32 MiB requests. DXVK reported only 84 + 876 MiB allocated: about 1 GiB of the 2 GiB window was held by freed ranges.
- **Root cause: freed VA ranges are never handed back under continuous rendering.** `orbis_retire_ranges` released anything only when `label == newest`. That was written when present waited for GPU idle every frame. Present now waits for its own frame while the next is submitted (deferred present). The function is called only from submit, unmap and VA free, where that is essentially never true.
- **Fix (01.41)**, `ac_orbis_drm.c` + `wsi_orbis.c`. Backups: `*.before-retire` beside the diff.
  - `ac_orbis_frame_boundary()` runs from the WSI present after its GPU wait. It stamps unstamped retired VA nodes and retire-queue entries with `newest`, then drains.
  - `orbis_retire_ranges` releases a node or entry when the label passes its stamp, as well as on full idle as before.
  - Same guarantee (every submission handed out before the release point has finished), measured at the first frame boundary after the free.
  - Telemetry every 600 boundaries: `PW_ORBIS_RETIRE boundary N: … freed ranges (… KiB) waiting for the GPU`.
- **Package 01.41**: uploaded, readback hash matched. sha256 `4cae83ce…b1e1`. Gates: 0 FAIL. Changed vs 01.40: both `libvulkan.prx` copies, plus the build marker, kernelbase timestamp and metadata.
- **01.41 L4D2 result: passes the 01.40 failure point.**
  - It ran 09:26:11–09:33:57 (7 m 45 s); Zak closed it, no crash. 01.40 crashed at ~5 min.
  - `radv.log` (`radv-0141-l4d2-end.log`): zero `PW_ORBIS_VA_FAIL`. Every `PW_ORBIS_RETIRE` line up to boundary 17401 shows 0 freed ranges waiting, with `label` 1–4 behind `newest` at every boundary; that lag is why the old full-idle rule never released anything.
  - The extension carried real usage beyond the arena.

## Update (2026-11-07 10:05): 01.41 passes the full run, promoted, published as `v0.0.1`

- **Every title reached gameplay on 01.41** (Zak: "yes all passed"), with no GPU allocation, VA or guest-fault records in any session:
  - GTA IV, FNV, FO3 (Pip-Boy fine), Oblivion (native).
  - MDK (translator; `wowprospero.dll` + `BTCpuSimulate` confirmed).
  - Half-Life (Zink), Bloodlines, Titan Quest, Half-Life 2.
  - Space Cadet Pinball (GDI, translator). Its device opens but it never presents through the Vulkan WSI, so 0042's frame boundary does not run for it.
  - Also Zak's L4D2 test, 7 m 45 s.
- **Promoted:** `pkgout/abi4-0141-baseline` (stage, `.pkg` `4cae83ce…`, parity, pkg_validate, manifest); `pkgout/baseline` now points at it. 01.34 stays in `pkgout/`.
- **Source of 01.41:**
  - orbis-win `main`: Mesa patches 0041–0042, so the series rebuilds the shipped `libvulkan.prx`.
  - prospero-win fork `main` `2e7f76a`: `ORBIS_` env family. Same tree as the build's `pw108194ec78+dirty` marker (diff sha `e145dc38…`).
  - Mesa: `1a59cc1` + `src/mesa-patches-ps4/0001–0042`.
- **Still open:**
  - CI cache resync (`scripts/ci/sync-cache.sh --abi4-only`); it now must carry the 01.41 stage and the Mesa tree.
  - Max's PR: branch `orbis-gpu-window-retire` in `codex_scratch/max-ps4-wine`, not pushed. The push was blocked by the permission check and needs Zak.
  - Bloodlines' quit hang. Titan Quest: descriptor ceiling, controls, translator crash. Half-Life `goldsrc` controller pass.

## Update (2026-11-07 11:30): MP3 through DirectShow without GStreamer; `v0.0.2` = 01.43

- **Cause of Oblivion's music problem.** quartz's MPEG-I Stream Splitter and l3codecx's MPEG Layer-3 Decoder only wrapped winegstreamer classes. Our Wine has no GStreamer, so no `.mp3` could be rendered. Oblivion retried forever and leaked file handles (WineHQ 19967), which is why it ran with `bMusicEnabled=0` since Oct 20. Fallout 3 logged the same `MPEG-I Stream Splitter` failure.
- **Fix: fork Wine patch 1069** (prospero-win `407b1cc`).
  - `dlls/quartz/mpegaudiosplit.c`: an elementary MPEG audio splitter, used when the wg class is missing.
  - `l3codecx.ax` hosts `mp3dmod` in the DMO Wrapper.
- **How the package gets these DLLs.** It takes Wine's PE DLLs from `wine-host/install/usr/lib/wine`, not `build/wine-ps5/pe` (only `wow64native` comes from there). The two modules were rebuilt in `wine-host/build` and installed stripped.
- **PC test:** upstream host Wine 490f6d5 with the patch, Oblivion's `tes4title.mp3`. `RenderFile` → splitter → decoder → DirectSound; 110.94 s; full decode to EC_COMPLETE twice. The test program is in `codex_scratch/mp3-test/`.
- **Hardware, 01.43** (`2465e806…`):
  - Oblivion: music on, no lag, ~9 min, 3 track changes, quit normally, no file-handle errors.
  - New Vegas: MP3 audio plays.
  - Fallout 3: MP3s play.
  - Harmless log noise: `mp3dmod` fixme lines for `IMediaSample2` and similar optional interfaces, once per sample when logging is on.
- **Published as `v0.0.2`** (Zak: "this is a good release").
  - Baseline for parity stays 01.41; 01.43 differs only in quartz/l3codecx and version stamps.
  - CI cache resynced afterwards; see the 2026-11-08 update below.
- **Open: the fork's Wine series has two `0740` patches** (since `661e3ad`), so `tools/build_wine_ps5.sh --check-patches`, and with it `build_host_wine.sh`, refuses to build a fresh host Wine from fork `main`.
