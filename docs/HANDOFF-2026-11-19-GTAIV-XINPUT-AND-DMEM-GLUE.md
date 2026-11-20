# GTA IV's dead controller was a stale dmem glue in ntdll.prx (2026-11-19)

The GTA IV controller fix was verified in **02.92**. The current installed
candidate is **02.97**, built with the real release marker and the tested 02.96
runtime payload plus the bounded guest-sampler table fix. It passed parity and
PKG validation, was installed, and reached the Half-Life 2 menu. Binding of
Isaac still exits normally before its first frame after successfully
discovering the Zink provider on 02.96; it has not been retested on 02.97.

## Session update (2026-11-19, latest state)

### 02.94 rebuilt and tested

- The 02.93 Titan Quest run was not a valid test of the rebuilt alert object:
  its `build_marker=GLDS10043-02.93-dmem-osi-diagnostics` confirmed it was still
  running the installed 02.93 package. The 02.94 package was uploaded afterward
  and installed through Debug Settings > Game > Package Installer.
- The Wine PS4 source is at `ee7b06d32113629e28234bf6d1e1011cc8152203`, which
  contains the Titan Quest alert-latch fix. Its old `sync.o` was timestamped
  14:12, before the source commit at 15:06. I saved the old object, `ntdll.so`,
  and PRX under
  `/home/zpeirce/ps4-package-scratch/orbis-0293-diagnostics/evidence/pre-sync-rebuild/`,
  rebuilt only `dlls/ntdll/unix/sync.o`, and ran `scripts/prx-ps4.sh` against
  the ABI-v4 tree. The new object timestamp is 18:47. Only `ntdll.prx` changed
  against the 02.93 stage; its two package copies match. This was incremental:
  one object compile and the PRX link, not another full Wine compile.
- Rebuilt `sync.o` SHA-256 is
  `ce6d440b15eed24495b82dd79ab6151c2e9d616e1b681a20a6dde04946326559`;
  02.94 `ntdll.prx` SHA-256 is
  `d6d9a8aca93a966ea538f993a28e8b8a763e5b222bf0cf62ca3bf5df4558c110`.
- The `make dlls/ntdll/ntdll.so` target is unsuitable in this PS4 build: its
  `-z defs` link omits PS4 PRX shims and deletes the output on failure. The PRX
  script links the Wine objects with the required shims directly. The old
  `ntdll.so` intermediate was restored before using that script.
- Candidate installer:
  `/home/zpeirce/ps4-package-scratch/orbis-0294-alert-rebuild/IV0000-GLDS10043_00-GLDS100430000000.pkg`
  (531,890,176 bytes; SHA-256
  `68ef7088e68ed9a1ca801de5aad46f2488dd32f98cbc46f8129164c13357197c`). It is
  also on the console at
  `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`; FTP size matched exactly.
- The candidate passed `check-ps4-package-parity.py` against the 02.93 stage
  with zero FAILs and passed all 27 `PkgTool.Core pkg_validate` checks. Parity
  still reports the known WARN that host `kernelbase/debug.c` is not present
  under this PS4 source tree, so PW_EXCEPTION32 reachability is not checked by
  that one rule; the package's i386 `kernelbase.dll` contains 25
  `PW_EXCEPTION32` strings.
- The package installer displayed the 02.94 candidate and accepted the
  reinstall prompt. After installation, `/user/app/GLDS10043/app.json`'s
  `packageDigest` matched the local package header digest at `0xFE0`
  (`4BFFCDBF...697652A8`), confirming the installed app points at this PKG.
- 02.94 retains the 02.93 app PRX, so its runtime marker still says
  `GLDS10043-02.93-dmem-osi-diagnostics`. Use the package digest / installer
  identity to distinguish this targeted A/B; the marker was not rebuilt.
- Titan Quest launch at 19:06:01 used profile `titan-quest-anniversary`, native
  WoW64, and `/data/prospero-win/prefixes/titan-quest-anniversary`. It reached
  the Titan Quest main menu, past the prior `galaxy.dll+0x113887` crash point.
  Runtime log: `/home/zpeirce/ps4-gladius/build-ps4-logs/ps5log-20261119-161212.log`
  (02.94 run begins 19:06:01.185). No `PW_EXCEPTION32` or guest-fault record
  followed that launch. The run was closed from the PS4 Quick Menu after the
  main-menu check; the app returned to the PS4 home screen.
- The console profile had very verbose `PW_ALERT` tracing active: the initial
  appended log grew to about 75 MB, with over 172,000 records. I then set
  `PW_PS4_ALERT_LOG=0` in the Titan Quest profile and `wait_watchdog=0` in
  `/data/prospero-win/settings.conf` for the final TQ run. Both original files
  are saved under
  `/home/zpeirce/ps4-package-scratch/orbis-0294-alert-rebuild/evidence/` and
  were restored and read back byte-for-byte. Original settings SHA-256:
  `9c5f240bce9f607ec8cabf631e75700cf443c37ff68ef8baf19f7eda9c6c4121`;
  original TQ profile SHA-256:
  `554e24de09cea3bfc90eeaca2c6bf78db16193c3fbf2dc2627ea8f116e6d42a0`.
- The full suite log is
  `/home/zpeirce/ps4-gladius/build-ps4-logs/ps5log-20261119-161212.log` (about
  684 MB). The watchdog's `wake_up` traces made it grow quickly while
  `wait_watchdog=1`; it is retained for evidence. `ps5logd` PID 770617 is still
  listening on port 9300, and the klog receiver PID 714692 is still running.

### Other console coverage with 02.93

- Fallout: New Vegas reached its main menu with native WoW64.
- Half-Life 2 reached its main menu after a slow startup.
- GTA IV reached its title menu with the controller working.
- Titan Quest on 02.93 crashed at the known `galaxy.dll+0x113887` null read.
  That run used 02.93, not the rebuilt 02.94 binary; do not count it as a
  counterexample to the 02.94 result.

### PE32 validation with the installed 02.94 candidate

I ran all **13 PE32** titles listed in the Orbis-Win launcher. The earlier
handoff called this a 12-title suite; the launcher actually has 15 game entries
(13 PE32, two PE64) plus the Settings card. These were startup/UI checks, not
gameplay certification. Identify 02.94 runs by the installed package digest,
because the repackage still reports the embedded 02.93 marker.

| PE32 title/profile | 02.94 result |
|---|---|
| Binding of Isaac Rebirth / `binding-of-isaac-rebirth` | Setup refused with `zink-provider-missing` before Wine started. Profile requests OpenGL. The 02.94 PKG extraction contains both architecture providers, so this is a runtime path/visibility or provider-validation issue, not missing package content and not a guest crash. |
| Vampire: The Masquerade – Bloodlines / `bloodlines-gog` | Reached the game's main menu. |
| Fallout: New Vegas / `fallout-new-vegas` | Reached the game's main menu. |
| Fallout 3 GOTY / `fallout3-gog` | Reached the game's main menu. |
| Grand Theft Auto IV / `gtaiv-test` | Reached the game's title menu. |
| Half-Life 2 / `half-life-2` | Reached the main menu after a slow startup. Wait-watchdog snapshots showed long-lived threads during load; no guest exception was recorded. |
| Half-Life GOTY + Opposing Force / `half-life` | Same `zink-provider-missing` setup refusal as Isaac; profile requests OpenGL. The provider DLLs are in the extracted 02.94 PKG. |
| Left 4 Dead 2 / `left-4-dead-2` | Reached the `-insecure` warning screen. Cross did not dismiss it, so controller navigation past this dialog is unverified. |
| MDK / `mdk-windows` | Rendered its intro credits; main-menu reach was not checked. |
| The Elder Scrolls IV: Oblivion / `oblivion-gog` | Reached the game's title menu. |
| Space Cadet Pinball / `pinball` | Game table rendered and ran at 800x600. |
| Splinter Cell Conviction / `splinter-cell-conviction` | Reached its red intro, then a black loading screen with a spinner. It remained alive for about a minute, with no guest exception; the latest stall snapshot had `frames_put=6, shown=0`. Closed from PS Quick Menu. This matches the previously known load stall and was not investigated further. |
| Titan Quest Anniversary / `titan-quest-anniversary` | Reached the main menu in both 02.94 runs, including the quiet-logging rerun. Gameplay beyond the menu was not validated; attempted controller/mouse input did not activate Play. |

Hollow Knight and Risk of Rain 2 are PE64 and were outside this PE32 validation
pass. This is not an all-library compatibility claim.

The OpenGL provider is present in the actual 02.94 package, not only in its
staging directory: `PkgTool.Core pkg_extract` at
`/home/zpeirce/ps4-package-scratch/orbis-0294-alert-rebuild/pkg-extracted`
shows `uroot/win/mesa-zink/{i386-windows,x86_64-windows}/{opengl32.dll,libgallium_wgl.dll}`.
Both console failures logged `zink provider=not-found`; that result currently
collapses a missing runtime directory, missing core DLLs, and provider-open
failures into one status. The 02.95 diagnostic package now logs each attempted
runtime root, provider path, and `stat` result before the provider install call.

The PS4 MCP transport is running locally through Chiaki Remote Play. Current
API tools did not expose PS4 controls, so the console was driven through the
installed `ps4-mcp` Linux Chiaki client. The user authorized package install and
testing; keep the parity and PKG validation gates for every next candidate.

02.94 was a targeted A/B package, not a finished 0.0.8 release. The
working source trees and unpushed repo state are recorded below; no push or
release has been made.

Source working trees to preserve:

- `/home/zpeirce/junk/orbis-fromsource/prospero-win-abi4`, branch
  `codex/wowprospero-pinned-ancestor-20261119`, has local edits in
  `native/wine64_main.c` (02.95 Zink path diagnostics),
  `tools/build_wine_ps5.sh`, `tools/build_wowprospero.sh`, and
  `wine/ps5/pw_ws2_32_libc.c`.
- Its nested PS4 Wine source at `.deps/wine-ps5/source`, branch
  `codex/orbit-osi-pipe-trace-20261119`, has local diagnostics edits in
  `server/async.c`, `server/fd.c`, and `server/named_pipe.c`. The alert-latch
  fix is committed as `ee7b06d`.
- `/home/zpeirce/ps4-package-scratch/wine-host-1043-20261119/source` is also on
  `codex/orbit-osi-pipe-trace-20261119` with those same three server diagnostic
  files modified. Preserve these edits; do not reset or clean these trees.

## The bug, end to end

GTA IV had no controller at all. The chain:

1. GTA IV is Vista-era: it uses `XINPUT9_1_0.dll`, which is a shim that does
   `LoadLibraryExW(L"xinput1_4.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32)`
   (`dlls/xinput9_1_0/main.c:52`). In a WoW64 process that resolves to syswow64.
2. That DLL's `.text` never became executable:
   `err:virtual:map_image_into_view_impl failed to set 60000020 protection on
   L"\??\C:\windows\syswow64\xinput1_4.dll" section .text, noexec filesystem?`
3. DllMain then jumped into it and faulted:
   `PW_EXCEPTION_SETUP ... code=c0000005 addr=78e51270 params=2 p0=0 p1=78e51270`
   -- the fault address **equals the instruction address**, i.e. executing a
   non-executable page. `warn:module:process_attach Initialization of
   L"xinput1_4.dll" failed`, then `free_modref`.
4. `init_xinput1_4_funcs` leaves all three function pointers NULL, so
   `XInputGetState` / `XInputGetCapabilities` / `XInputSetState` return
   `ERROR_DEVICE_NOT_CONNECTED` **for the life of the process** --
   `InitOnceExecuteOnce` never retries.

## Root cause: two modules, two different copies of the glue

`pw_wine_dmem_glue_ps4.c` is compiled twice -- fresh by `scripts/prx-ps4.sh`, and
baked into the **cached** `build/ps4-wine-sdk/libps4stubs.a` by
`scripts/prepare-ps4-toolchain.sh`. 02.91 shipped with the two disagreeing:

    relocated_wine_app.prx  ->  has "default-unlimited"   (current glue)
    sce_module/ntdll.prx    ->  no "unlimited" at all     (STALE, 256 KiB default)

`ntdll.prx` is where `map_image_into_view` runs, so **its** copy governed.
klog showed both, from the same run:

    exec-migrate-range-max bytes=0x40000             source=default           (47x, ntdll)
    exec-migrate-range-max bytes=0xffffffffffffffff  source=default-unlimited  (2x, app)

The stale default of 256 KiB forces the per-page exec path. The current source
comment on that knob is explicit:

    unset / 0  -> no limit (default; 32-bit titles must stay here)

GTA IV is `architecture = pe32`. klog recorded `exec-range-per-page` **14,427**
times in the failing run.

`/home/zpeirce/ps4-gladius/build/ps4-wine-sdk/libps4stubs.a` was dated **Oct 7**
(16,144 B, no `unlimited`). `docs/BUILDING-FROMSOURCE.md` already warns that a
stamp "keyed too narrowly" silently skips a `src/native` change and ships the
previous objects. That is exactly what happened.

### Proof, both directions

| run | knob | per-page events | xinput1_4 | controller |
|---|---|---|---|---|
| 02.91 stock | `0x40000 source=default` | 14,427 | protection failure, DllMain fault | dead |
| 02.91 + profile env override | `0x100000000 source=env` | 0 | clean | **works** |
| **02.92** (rebuilt ntdll.prx, no override) | `0xffffffffffffffff source=default-unlimited` | **0** | clean | **works** |

The 02.92 run is the one that matters: the profile override was **removed**
first (profile restored to its original 679 bytes), so it proves the binary.

## What shipped: Orbis-Win 02.92

Installer on console: **`IV0000-GLDS10043_00-GLDS100430000000-0292.pkg`**
(`/user/data/pkg/`, 532,021,248 B, verified with `ftp-size.py` -- `ftp-put.py`
can report success on a short write).

Local: `/home/zpeirce/ps4-package-scratch/orbis-0292-glue/`
SHA-256 `25c46f0f1a2fbea103d66af048262fcb0c8d09c4bec07790d0d13ff956d93b97`.

One module changed vs 02.91, purely additive:

| marker | 02.92 | 02.91 |
|---|---|---|
| `default-unlimited` (the fix) | 1 | 0 |
| `PW_ALERT_DROPPED` (Titan Quest fix) | 1 | 1 |
| `PW_PS4_KQ_PROBE` | 1 | 1 |
| `PW_PS4_SAMPLE_TIMER` | 1 | 1 |
| `kq-probe` | 8 | 8 |

Gates: parity **0 FAIL** (exit 0); `PkgTool.Core pkg_validate` **27/27 [OK]**.

⚠ **02.92 still reports `build_marker=GLDS10043-02.69-touchpad`.** It is an A/B
repackage that never rebuilt `relocated_wine_app.prx`, which is where the marker
lives. This misled this session once already -- identify an installed package by
`/user/app/<TITLE>/app.json`'s `url` plus the PKG header digest at `0xFE0`, never
by the marker. 02.91 and 02.92 both report 02.69.

## Two traps worth keeping

**Build the glue from `ps4-gladius/src/native`, not the clean-room repo.** The
first rebuild used `junk/orbis-fromsource/repo/src/native` and silently dropped
**11** PS4-specific diagnostics (`PW_PS4_KQ_PROBE`, `PW_PS4_SAMPLE_TIMER`,
`kq-probe`, the guest sampler). The parity gate caught it as a WARN listing every
missing string. Both copies have the exec-migrate fix; only ps4-gladius has the
diagnostics.

**The package carries TWO `ntdll.prx` copies** -- `sce_module/ntdll.prx` and
`win/wine/lib/wine/x86_64-unix/ntdll.prx`. Replacing only the first is a hard
parity FAIL ("sce_module and win/wine/lib/wine/x86_64-unix copies differ").

## Landed in the repo (committed, NOT pushed)

- `ac7a13a` -- **parity check 11**: any `sce_module` PRX carrying the
  `exec-migrate-range-max` format string must also carry `default-unlimited`.
  Tested both ways: 02.92 PASSes ("agrees across 2 modules"), **02.91 FAILs**, so
  this defect could not have shipped again.
- `defb2fa` -- Wine pins moved to the Titan Quest fix (`wine-ps5`
  `b5acab7 -> ee7b06d`, `wine-host` `0f6e2e6 -> 7892a81`), `VERSION` -> **0.0.8**,
  and `docs/HANDOFF-2026-11-19-TITAN-QUEST-NTDLL.md` rewritten with the root cause
  (it previously pointed at the wrong lead, 1040/1041, and named a non-existent
  env var; the real knob is `PW_PS4_ALERT_LOG`).
- `166cd14` -- the original GTA IV / stale-dmem handoff.
- `f530fcc` -- this 02.96 update and restoration of the bounded guest-sampler
  values (`PW_GUEST_SAMPLE_MAX=400`, 16 tracked threads).

At review start (`7fa2b32`), the local branch was **98 commits ahead of
`origin/launcher-settings`**, but that is a stale comparison point. The remote
refs have diverged: relative to their merge base, `origin/launcher-settings`
has 10 commits and `origin/main` has 90. This branch contains both histories
plus a merge and was **18 commits ahead of `origin/main`**. Review the local
delta against current `origin/main` before publishing; do not treat the count
against stale `origin/launcher-settings` as entirely new work. Nothing has
been pushed.

Also fixed on disk, not in git: `build/ps4-wine-sdk/libps4stubs.a` regenerated
(16 KB Oct 7 -> 102 KB, now carrying the current glue). The original is kept at
`/home/zpeirce/ps4-package-scratch/libps4stubs.a.oct07-backup`.

## Original build failure and reproducible command

A full from-source build was started to get an honest marker and a package built
from the pins. Both trees are already **at** their pins, so no cold restore is
needed:

    wine-ps5   junk/orbis-fromsource/prospero-win-abi4/.deps/wine-ps5/source   ee7b06d  == pin
    wine-host  ps4-package-scratch/wine-host-1043-20261119/source              7892a81  == pin

Command used (recorded so it need not be re-derived):

    PW_ROOT=/home/zpeirce/junk/orbis-fromsource/prospero-win-abi4 \
    PW_HOST_WINE=/home/zpeirce/ps4-package-scratch/wine-host-1043-20261119 \
    PW_ORBIS_COMPAT=/home/zpeirce/junk/orbis-fromsource/orbis-compat-src \
    TITLE_ID=GLDS10043 TITLE="Orbis-Win" PW_BUILD_ID=GLDS10043-02.93-glue-fix \
    PKG_OUT=.../orbis-0293-full PKG_BASE_OUT=.../orbis-0293-full-base \
    PW_MESA_ZINK_DIR=<0292 stage>/win/mesa-zink \
    PS4_KERNELBASE32_DLL=<0292 stage>/win/wine/lib/wine/i386-windows/kernelbase.dll \
    PS4_IPHLPAPI32_DLL=<0292 stage>/win/wine/lib/wine/i386-windows/iphlpapi.dll \
    WOW64NATIVE_ABI=4 WOW64NATIVE_DLL=<0292 stage>/.../wow64native.dll \
    WOW64NATIVE_ABI4_SHA256=$(sha256sum ...) \
    WOW64NATIVE_ABI4_PRX_SHA256=$(sha256sum <prx>/sce_module/wow64native.prx) \
      ./scripts/build-app-ps4.sh --pkg

**The first attempt stopped here:**

    X no wowprospero.dll in the PE runtime

and building that from the pinned tree was refused by a pristine-revision
assertion -- a **fourth** instance of the defect already recorded in
`orbis-win-builds-from-source`:

    tools/build_wowprospero.sh:22  WINE_COMMIT=490f6d5dcbb2a5047345b8af88d114bbcaad69a8
    tools/build_wowprospero.sh:44  [ "$commit" = "$WINE_COMMIT" ] || fail "Wine source is $commit, expected $WINE_COMMIT"
    -> build_wowprospero: Wine source is 7892a817..., expected 490f6d5dcbb...

The same hardcoded base commit appears in `tools/build_wine_ps5.sh`,
`tools/build_wow64native.sh`, `tools/build_wine_runtime.sh` and
`build_wine_ps5.sh.orig`. The pinned `wine-host` is a **descendant** of that base,
which is correct and expected. The `build_wowprospero.sh` assertion is now an
ancestry check (`git merge-base --is-ancestor $WINE_COMMIT HEAD`); the other
build scripts were not changed as part of this targeted unblock. Do not work
around it by copying the shipped `wowprospero.dll` out of the 02.92 stage --
that would make the "built from pins" claim false.

### Remaining for 0.0.8

1. The former Zink-provider refusal is resolved: both OpenGL profiles find the
   provider. Half-Life reached its menu in 02.95, and Half-Life 2 reached its
   menu in 02.96. Isaac still exits before rendering in both 02.95 and 02.96;
   the 02.96 log shows provider discovery, native OpenGL DLL loads, one WGL
   thread-context error, and a normal guest exit with no exception. This is not
   enough to identify why the game exits. Decide separately whether to pursue
   L4D2's controller warning and Splinter Cell's loading stall.
2. Titan Quest reaches its menu with alert tracing disabled, but gameplay is
   not validated because the current input attempt did not activate Play.
3. Sampler limits were restored to the main-branch release values
   (`PW_GUEST_SAMPLE_MAX=400`, 16 tracked threads), and `libps4stubs.a` was
   rebuilt for 02.95. Keep the rebuilt archive when making the next package.
4. **02.96 is a built, gated, and installed 0.0.8 candidate** with a correct
   marker. The smoke checks passed for the launcher and Half-Life 2; Isaac's
   early exit remains unresolved. It is not a release: do not tag or publish
   it until the remaining release review and chosen validation scope are done.
5. Review the local delta against `origin/main` before pushing anything. At
   review start it was 18 commits; the 98-commit count against
   `origin/launcher-settings` includes the newer main history because that
   tracking ref is behind/diverged. No push, tag, or release has happened.

## Previous console state after 02.94 (superseded by 02.95 below)

- Orbis-Win **02.94 targeted A/B** installed. It retains the 02.93 marker; the
  installed `app.json` package digest was verified against this 02.94 PKG.
- Console is at the PS4 home screen with Orbis-Win selected, after closing the
  final Titan Quest run from Quick Menu. Original `settings.conf` and
  `titan-quest-anniversary.profile` were restored and byte-verified on-console.
- Latest Orbis-Win launcher run reported 15 game entries and
  `video=ok pad=ok hid=ok`. The 9300 collector is armed at `10.168.2.188:9300`.
- `gtaiv-test.profile` **restored to its original 679 bytes** (the
  `PW_PS4_EXEC_MIGRATE_RANGE_MAX` override removed). Backup of the modified copy
  is at `/data/prospero-win/profiles/gtaiv-test.profile.bak-20261119`.
- `/data/prospero-win/prefixes/gtaiv-test/drive_c/windows/syswow64/xinput1_4.dll`
  was replaced with the current build's (40,974 B); the original Oct 20 copy is
  preserved beside it as `xinput1_4.dll.bak-20261119`. This was a dead-end test --
  the replacement failed identically before the real fix -- but the current file
  is the correct one, so it was left in place.
- The 9300 collector remains listening after the last title closed; confirm it
  is still active before the next test with `ss -lntp | grep 9300`.

## 02.95 Zink lookup diagnostic candidate (2026-11-19)

02.95 is installed for a focused test of the two profiles that failed with
`zink-provider-missing` under 02.94. Both now pass provider discovery. The
remaining Isaac exit is downstream of Zink provider lookup; Half-Life proves
the same OpenGL path can reach a game's menu.

- Exact installer:
  `/home/zpeirce/ps4-package-scratch/orbis-0295-zink-diagnostics/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`
  (532,414,464 bytes; SHA-256
  `1771b65b0ef9e6f7ae326e09cd01607080019d837968e484beedd554bbf16810`). The
  console copy is `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`; its FTP
  size matched the local artifact.
- Installed identity was verified through
  `/user/app/GLDS10043/app.json`: `packageDigest` is
  `14A673602D48F18271BF53B6503E4554D9A1442D5B2D53DF1034204D80FE2148`, matching
  the digest in the local PKG header at offset `0xFE0`.
- `scripts/check-ps4-package-parity.py` passed with zero FAILs against the
  02.94 stage, using the ABI4 PRX build directory and upstream source tree.
  `PkgTool.Core pkg_validate` also passed. Evidence is in
  `/home/zpeirce/ps4-package-scratch/orbis-0295-zink-diagnostics/{parity.txt,pkg_validate.txt}`.
- 02.95 carries the known-good 02.92 `wow64native.prx` / DLL pair. A freshly
  rebuilt PRX had a different hash from the pinned expected binary, so it was
  preserved as evidence at
  `/home/zpeirce/ps4-package-scratch/orbis-0295-zink-diagnostics/evidence/wow64native.prx.rebuilt-700f96c6`
  and excluded from this candidate. Do not treat 02.95 as a validation of that
  rebuilt native-WoW64 PRX.
- The fresh `libvulkan.prx` initially failed the parity rule because it linked
  the pinned compatibility archive. It was rebuilt with the SDK bundle archive
  as the link input, then parity passed. The SDK bundle's `signal.h` cannot be
  used as the compile header for this build: it omits the PS4 `SIG_UNBLOCK=2`
  ABI delta and `prospero-clang` rejects it. The build therefore retained the
  PS4-compatible headers from `orbis-compat-src` and temporarily substituted
  only the bundle archive for the RADV link; the pinned archive was restored
  immediately after the link. See
  `/home/zpeirce/ps4-package-scratch/orbis-0295-zink-diagnostics/evidence/`.
- `build/ps4-wine-sdk/libps4stubs.a` was regenerated from the restored glue
  source with `PW_GUEST_SAMPLE_MAX=400` and `seen_tid[16]`. The older archive is
  retained at `/home/zpeirce/ps4-package-scratch/libps4stubs.a.oct07-backup`.
- ABI4 `native/wine64_main.c` now logs the Zink root, candidate path, `stat`
  result and errno for each attempted provider before installation. The source
  edit is local and uncommitted. This should distinguish an absent/invisible
  runtime path from a provider-open or install failure.
- Isaac (`binding-of-isaac-rebirth`) was launched at 20:54:51.738. It logged
  `zink root=/app0 path=/app0/win/mesa-zink/i386-windows stat=0 errno=0
  result=ok copied=2`, then `zink provider=ok copied=2 architecture=pe32`.
  Wine loaded both `libgallium_wgl.dll` and `OPENGL32.dll`. The process exited
  to the launcher at 20:55:01.874 with `reason=guest-exit`, after about 10 s;
  `frames_put` remained zero and there was no guest exception. This no longer
  reproduces the former setup refusal; Isaac's early exit remains a separate
  game-start issue.
- Half-Life GOTY + Opposing Force (`half-life`) was launched at 20:59:24.785.
  It logged `zink root=/app0 path=/app0/win/mesa-zink/i386-windows stat=0
  errno=0 result=ok copied=0` and `zink provider=ok copied=0 architecture=pe32`;
  `copied=0` is expected when the provider files are already present. The log
  reports `dll_overrides=opengl32=n`. Wine logged
  `err:wgl:internal_context_create Failed to create internal thread context`
  at 20:59:32.557, then continued. By 20:59:59 it had produced 203 frames at
  640x480, and Remote Play showed the Half-Life main menu. Treat this WGL error
  as nonfatal in this run; the title-menu result is positive.
- An intervening run selected Half-Life 2 (DXVK), not the OpenGL `half-life`
  profile. It is not part of the Zink validation.
- After verifying the Half-Life menu, the Orbis-Win app was closed through the
  PS4 close-application dialog. The console is now at the PS4 home screen with
  Orbis-Win 02.95 selected; it is not running a title. The 9300 receiver is
  still listening, and the run evidence is in
  `/home/zpeirce/ps4-gladius/build-ps4-logs/ps5log-20261119-161212.log` (last
  connection closed at 21:03:53). Next useful step: inspect Isaac's final
  process-exit path with provider presence confirmed; do not retry Half-Life
  merely to establish Zink discovery again.
- Candidate title text is `Orbis-Win 0.0.8 Candidate 02.95`; this is a focused
  diagnostic build, not a release candidate. No push, tag, or release was made.

## 02.96 correctly marked 0.0.8 candidate (2026-11-19)

02.96 rebuilds the launcher/app layer from the current `ps4-gladius` sources,
using the 02.95 tested runtime as input. This replaces the 02.95 diagnostic
repackage's stale app marker with `GLDS10043-02.96-release-candidate`; it does
not rebuild the Wine runtime or native WoW64 pair.

- Exact installer:
  `/home/zpeirce/ps4-package-scratch/orbis-0296-release-candidate/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`
  (532,414,464 bytes; SHA-256
  `47f7bc263e5caf1ba56645e62f34c9c91f90f7d429f211f422193abee456ac2a`).
- 02.96 carries the exact tested ABI-4 PE/PRX pair from 02.95:
  `wow64native.dll` SHA-256
  `e531a51bb19ae4f92e65556f0f6d4f89e930b9c7490d8a02988feb1d5ee9c044`, and
  `wow64native.prx` SHA-256
  `20eee436ae5856f06d39b9f9fa57720806612f15e1ebea4ab15b4638da5b729d`. It also
  carries the tested 02.95 `libvulkan.prx`, Zink providers, and i386
  `kernelbase.dll` diagnostics.
- The complete stage comparison against 02.95 found exactly three changed
  files: `pkg.gp4`, `sce_sys/param.sfo` (title text), and
  `sce_module/relocated_wine_app.prx` (fresh app code/build marker). All other
  staged payload files, including every Wine/RADV PRX and PE DLL, are
  byte-identical to 02.95. The package keeps APP_VER `01.00` and the standard
  PS4 attribute (`ATTRIBUTE=0`), matching 02.95.
- `scripts/check-ps4-package-parity.py` against the 02.95 stage passed with **0
  FAILs**. It emitted one known WARN: the host source tree lacks
  `dlls/kernelbase/debug.c`, so the gate cannot inspect PW_EXCEPTION32
  reachability; the packaged i386 `kernelbase.dll` contains 25 diagnostic
  strings. `PkgTool.Core pkg_validate` passed every check.
- Uploaded to `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`; FTP size
  matched. The PS4 installer displayed `Orbis-Win 0.0.8 Candidate 02.96` and
  completed the reinstall. `/user/app/GLDS10043/app.json` now contains package
  digest `C94912479F744D0D60244541F25323776A0817B738979834C698E863D0C86040`,
  equal to the local PKG header digest at `0xFE0`.
- Orbis-Win started with
  `build_marker=GLDS10043-02.96-release-candidate`, 15 games, and
  `video=ok pad=ok hid=ok`.
- Binding of Isaac Rebirth (`binding-of-isaac-rebirth`) launched at
  21:22:50.814. Zink provider lookup succeeded (`stat=0`, `copied=0`, provider
  `ok`); Wine loaded `steam_api.dll`, `libgallium_wgl.dll`, and `OPENGL32.dll`.
  At 21:22:55.600 it logged
  `err:wgl:internal_context_create Failed to create internal thread context`.
  At 21:22:58.930 the runtime returned to the launcher with
  `reason=guest-exit`; `frames_put=0`, `vk_shown=0`, and no guest exception was
  recorded. This matches the 02.95 result. The WGL error is correlated but
  does not prove the exit cause.
- Half-Life 2 (`half-life-2`, DXVK) launched at 21:24:13.437 with the 02.96
  marker and native WoW64. Remote Play showed the Half-Life 2 main menu by
  21:27. The Wine internal-context WGL error also appeared during this run, but
  was nonfatal. DXVK reported 701 Vulkan presents, and no guest exception was
  logged.
- The console is currently left at the Half-Life 2 main menu in the installed
  02.96 app. The 9300 receiver is listening. Both current runs are in
  `/home/zpeirce/ps4-gladius/build-ps4-logs/ps5log-20261119-161212.log`.
  `wait_watchdog=1` generated many `wake_up` records; the log reached about
  749 MB by 21:36, so disable it for later tests if they need extended waits. No push,
  tag, or release was made.
- Current Git references at this report: the 02.96 candidate and handoff note
  were at `7fa2b32`; that branch point was 98 commits beyond the stale
  `origin/launcher-settings` ref and 18 commits beyond `origin/main`. The refs
  diverged (10 commits unique to the old branch and 90 unique to main at their
  merge base); the local branch includes main via merge. Review the local delta
  against current `origin/main` before publication.

## Not pursued

Soul Reaver fails separately at OpenGL context creation
(`wgl:internal_context_create`, `wined3d_caps_gl_ctx_create Failed to find a
suitable pixel format`, `dll_overrides=-`). Setting it to DXVK did not launch it
either, and per Zak it has never worked. That is the `opengl-zink` path, unrelated
to this.

## Parity gate follow-up

During the follow-on review, I found that the PE capability-provider gate only
checked a candidate DLL when that file existed. If the baseline had the hosted
driver provider but the candidate omitted the whole PE file, the gate skipped
that path instead of failing. `scripts/check-ps4-package-parity.py` now reports
that as a missing `wine-driver-threads` provider.

- The normal 02.95-to-02.96 parity check still reports **0 FAILs** (with the
  known kernelbase source WARN).
- A temporary symlinked candidate stage with only the i386 `ntoskrnl.exe`
  removed correctly fails the gate and identifies
  `i386-windows/ntoskrnl.exe (file missing)`. The fixture was removed after the
  check; no package or console files were changed.
- This local parity-gate correction is not pushed. Review it with the rest of
  the local delta before publishing.

## 02.97 sampler bounds fix and console smoke test (2026-11-19)

The guest sampler had an out-of-bounds table access: `seen_tid` held 16
entries, while `seen_hits` held 128 and both lookup loops iterated 128 times.
The source fix is committed locally as `5aa7c67` (`Fix bounded guest sampler
thread table`). It defines `PW_GUEST_SAMPLE_THREADS` as 16, sizes both arrays
from that constant, and uses the same bound in both loops. The path is still
opt-in; this build does not enable sampling globally.

- Build 02.97 used the ABI4 source tree and the known-tested ABI4 native pair
  from 02.96. The PE/PRX hashes stayed
  `e531a51bb19ae4f92e65556f0f6d4f89e930b9c7490d8a02988feb1d5ee9c044` and
  `20eee436ae5856f06d39b9f9fa57720806612f15e1ebea4ab15b4638da5b729d`.
- `scripts/prx-ps4.sh` rebuilt `ntdll.prx`. Its matching
  `.deps/wine-ps5/prx/ntdll.shared.elf` reports `seen_tid` as 128 bytes and
  `seen_hits` as 64 bytes (16 entries each). The package contains that PRX in
  both `sce_module/ntdll.prx` and
  `win/wine/lib/wine/x86_64-unix/ntdll.prx`.
- The complete 02.96-to-02.97 staged comparison contains exactly five changed
  files: `pkg.gp4`, `sce_sys/param.sfo`, `sce_module/relocated_wine_app.prx`,
  and the two `ntdll.prx` copies. No baseline payload is missing.
- The parity gate passes with 0 hard failures when given the matching PRX
  directory (`.deps/wine-ps5/prx`) and ABI4 upstream root. It reports the
  existing warning that the host Wine source lacks `dlls/kernelbase/debug.c`;
  `kernelbase.dll` in the candidate still has 25 `PW_EXCEPTION32` strings.
- `PkgTool.Core pkg_validate` passes all package digest and signature checks.
  On this host the command needs
  `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` and the library path returned by
  `scripts/find-openssl11.sh`.
- Exact installer:
  `/home/zpeirce/ps4-package-scratch/orbis-0297-sampler-bound/trace/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`
  (532,414,464 bytes; SHA-256
  `b5a077eb2ac06c7f9338d9bd9d83d0fbcbf4b1221f61fab34497d14c1a75f8bc`).
  Build marker: `GLDS10043-02.97-sampler-bound`.
- Uploaded over GoldHEN FTP to
  `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg` and installed through
  Debug Settings > Game > Package Installer. The app's installed
  `packageDigest` is
  `DDE70CF947CADCF57F1737CA186B02FF3178DCBEC8D3F04929D2B37364971C02`, equal
  to the package header digest at `0xFE0`.
- Orbis-Win started with the 02.97 marker and reported 15 games plus
  `video=ok pad=ok hid=ok`. Half-Life 2 (`half-life-2`, XInput) then reached
  its main menu. At 22:24 it was still running; the log had recurring `alive`
  records and Vulkan presents, with no guest exception or return-to-launcher
  record in this run. This is a runtime regression smoke test, not direct
  validation of the opt-in sampler. The 13-title PE32 startup/UI suite in this
  handoff was run on 02.94, before 02.97; the only 02.97 title check so far is
  HL2. The 02.94 suite results remain useful baseline coverage but are not a
  claim that the full suite was rerun on 02.97.
- Current log: `build-ps4-logs/ps5log-20261119-161212.log` (about 851 MB at
  the last check); receiver on port 9300 is still active. The console is left
  at the Half-Life 2 main menu in 02.97. Avoid extended wait tests with
  `wait_watchdog=1`, which rapidly grows this log.
- The first full wrapper attempt stopped at the ABI hash guard. A subsequent
  `bash -x` run with the same explicit ABI4 pair completed without bypassing
  the guard; the issue did not reproduce. No GitHub push, tag, or release was
  made. The handoff and code fixes are local only.

## 02.98 sampler-table candidate and console test (2026-11-19)

The earlier 02.97 handoff described the sampler table as 16 entries. Review of
the recent commits and the diagnostic's intended use changed that decision:
Hollow Knight had 32 worker threads before the target was sampled, so a
16-entry table can miss the thread of interest. Keep the sampler opt-in and
bounded, but restore its documented 128-thread table and 20,000 timer-sample
cap. The 20,000 cap applies only when the separate 10 Hz timer is explicitly
enabled; ordinary sampler mode leaves that timer off. The code fix is local
commit `12405ec` (`Restore bounded 128-thread guest sampler`).

- Candidate: **Orbis-Win 0.0.8 Candidate 02.98**, marker
  `GLDS10043-02.98-guest-sampler-128`.
- Exact installer:
  `/home/zpeirce/ps4-package-scratch/orbis-0298-guest-sampler/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`
  (532,414,464 bytes; SHA-256
  `6932b8532766a33afca2a386697a62b8a6c95cc2c46802fc38f185c8edb8d3bf`).
  Package header digest at offset `0xFE0`:
  `6E8904E78CB916FFD7C28D7F7ED7653C9F5A9C12418A3170DFB2DD50535B6235`.
- The matching `ntdll.shared.elf` reports `seen_tid` as 1,024 bytes and
  `seen_hits` as 512 bytes: both arrays have 128 entries. The sampler source
  and loops use the same `PW_GUEST_SAMPLE_THREADS` bound.
- 02.97-to-02.98 staged comparison: exactly five changed files, `pkg.gp4`,
  `sce_sys/param.sfo`, `sce_module/relocated_wine_app.prx`, and both `ntdll.prx`
  copies. No staged payload files were added or omitted. The 02.98 parity gate
  passed with zero hard failures (the existing `kernelbase/debug.c` warning
  remains); `PkgTool.Core pkg_validate` passed all checks. Both `ntdll.prx`
  copies have SHA-256
  `d6d9a8aca93a966ea538f993a28e8b8a763e5b222bf0cf62ca3bf5df4558c110`.
  The known-tested ABI4 pair was retained: DLL SHA-256
  `e531a51bb19ae4f92e65556f0f6d4f89e930b9c7490d8a02988feb1d5ee9c044`, PRX
  SHA-256 `20eee436ae5856f06d39b9f9fa57720806612f15e1ebea4ab15b4638da5b729d`.
- Uploaded to GoldHEN FTP `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`
  and installed through the Package Installer. The installed
  `/user/app/GLDS10043/app.json` package digest matches the 02.98 header digest.
- On 02.98, Orbis-Win reported the candidate marker and 15 library entries.
  Half-Life 2 loaded to its main menu and remained alive, presenting frames.
  This is a startup/regression smoke test, not evidence that the guest sampler
  works.
- A temporary `[debug] env = PW_PS4_GUEST_SAMPLER=1` was added to the HL2
  profile. The launcher logged `debug_env=PW_PS4_GUEST_SAMPLER`, and klog
  recorded `guest-sampler env="1" len=1` plus
  `guest-sampler sigaction=0 setitimer=0`. The sampler emitted 12 samples and
  12 stack records for 12 distinct threads while HL2 reached its menu and
  remained running. `setitimer=0` is the return status; the free-running
  `PW_PS4_SAMPLE_TIMER` was not enabled. The run exercises the sampler but did
  not exceed 16 distinct threads, so the 128-entry capacity itself is verified
  by the matching ELF symbol sizes, not by reaching entries above index 15 at
  runtime. The original 2,808-byte HL2 profile was restored over FTP and its
  readback SHA-256 matches the pre-test backup
  (`274061cd737917d04c0d426b256270252e2b997c3c27fd6ee79cf9d400af05e8`).
- The active klog capture is
  `build-ps4-logs/ps4-klog-20261119-111421-watch.log`; the relevant records are
  at 22:48:21.997-22:48:53.019. The separate UDP log is
  `build-ps4-logs/ps5log-20261119-161212.log`; both receivers remain active.
  These logs are large and grow quickly under `wait_watchdog=1`.
- The console is left running 02.98 at the Half-Life 2 menu, with the original
  profile restored. No GitHub push, tag, or release was made.

Next: investigate why the enabled profile flag did not produce the native
sampler startup marker before claiming runtime validation. Keep the 02.97
package as rollback and 02.98 as the installed candidate. Before any 0.0.8
publication, review the remaining local changes against `origin/main` and
complete the requested suite/release review. No push, tag, or release is
authorized by this handoff.
