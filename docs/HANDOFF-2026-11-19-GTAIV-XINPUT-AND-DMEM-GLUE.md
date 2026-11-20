# GTA IV's dead controller was a stale dmem glue in ntdll.prx (2026-11-19)

Fixed and verified on console in Orbis-Win **02.92**. The 0.0.8 release build is
**blocked** on one thing, described in "Where to pick up".

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

Branch `launcher-settings`, 2 commits ahead of `origin/main` beyond the earlier
merge. Working tree clean. **Nothing pushed.**

Also fixed on disk, not in git: `build/ps4-wine-sdk/libps4stubs.a` regenerated
(16 KB Oct 7 -> 102 KB, now carrying the current glue). The original is kept at
`/home/zpeirce/ps4-package-scratch/libps4stubs.a.oct07-backup`.

## Where to pick up: the 0.0.8 build is blocked

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

**It stops here:**

    X no wowprospero.dll in the PE runtime

and building that from the pinned tree is refused by a pristine-revision
assertion -- a **fourth** instance of the defect already recorded in
`orbis-win-builds-from-source`:

    tools/build_wowprospero.sh:22  WINE_COMMIT=490f6d5dcbb2a5047345b8af88d114bbcaad69a8
    tools/build_wowprospero.sh:44  [ "$commit" = "$WINE_COMMIT" ] || fail "Wine source is $commit, expected $WINE_COMMIT"
    -> build_wowprospero: Wine source is 7892a817..., expected 490f6d5dcbb...

The same hardcoded base commit appears in `tools/build_wine_ps5.sh`,
`tools/build_wow64native.sh`, `tools/build_wine_runtime.sh` and
`build_wine_ps5.sh.orig`. The pinned `wine-host` is a **descendant** of that base,
which is correct and expected; the assertion simply has not been taught about
pins. Decide whether to relax it to an ancestry check
(`git merge-base --is-ancestor $WINE_COMMIT HEAD`) or to pass an override. Do not
work around it by copying the shipped `wowprospero.dll` out of the 02.92 stage
without recording why -- that would make the "built from pins" claim false.

### Remaining for 0.0.8, after that unblocks

1. Finish the 02.93 full build; confirm `build_marker=GLDS10043-02.93-glue-fix`
   and `PW_RELEASE_VERSION` 0.0.8 reach the binary.
2. Parity gate vs the 02.92 stage, then `pkg_validate`.
3. **Run the 12-title suite.** The exec path changed for *every* 32-bit title,
   not just GTA -- FNV, Titan Quest, Half-Life and MDK are all `pe32` and were all
   taking the per-page path until now. Titan Quest especially: its fix is in the
   same module.
4. **Decide the sampler limits.** `launcher-settings` carries
   `PW_GUEST_SAMPLE_MAX = 20000` and 128 tracked threads (commented "debugging a
   wedge: we want the data, not a tidy log") against 400/16 on `main`. That is a
   debugging configuration and it is baked into the `ntdll.prx` now on the
   console. Probably should not ship in a release.
5. Push, in the agreed order: prospero-win, then orbis-win, then playden. Then
   tag v0.0.8.

## Console state as left

- Orbis-Win **02.92** installed; GTA IV launches and the controller works.
- `gtaiv-test.profile` **restored to its original 679 bytes** (the
  `PW_PS4_EXEC_MIGRATE_RANGE_MAX` override removed). Backup of the modified copy
  is at `/data/prospero-win/profiles/gtaiv-test.profile.bak-20261119`.
- `/data/prospero-win/prefixes/gtaiv-test/drive_c/windows/syswow64/xinput1_4.dll`
  was replaced with the current build's (40,974 B); the original Oct 20 copy is
  preserved beside it as `xinput1_4.dll.bak-20261119`. This was a dead-end test --
  the replacement failed identically before the real fix -- but the current file
  is the correct one, so it was left in place.
- The `ps5logd` collector on **9300 died mid-session** and one GTA run produced no
  log at all (the title never blocks when the listener is missing, so the game
  looks fine and tells you nothing). Confirm it is listening before any test:
  `ss -lntp | grep 9300`.

## Not pursued

Soul Reaver fails separately at OpenGL context creation
(`wgl:internal_context_create`, `wined3d_caps_gl_ctx_create Failed to find a
suitable pixel format`, `dll_overrides=-`). Setting it to DXVK did not launch it
either, and per Zak it has never worked. That is the `opengl-zink` path, unrelated
to this.
