# Splinter Cell: Conviction handoff — 2026-11-17

## Goal and current result

Get Splinter Cell: Conviction into gameplay. The known run reaches the intro and cutscene, then either stalls at the loading screen with audio stopping or exits back to the Orbis-Win launcher. The latest run on app version 02.62 reached the cutscene and then crashed to the launcher. Gameplay has not been reached.

The 02.62 test was intended to make Ubisoft offline resolution use the prefix `hosts` file. That behavior is confirmed in the logs. The crash is a separate Wine synchronization failure so far; there is no evidence yet that the resolver change caused it.

## Console and offline resolver state

- Console: `10.168.2.52`, title ID `GLDS10043`.
- App version tested: `02.62`, installer filename `IV0000-GLDS10043_00-GLDS100430000000.pkg`.
- Runtime log build marker still says `GLDS10043-02.59-pw5d1cb4f753`; the package version and runtime marker are different pieces of metadata.
- Profile: `splinter-cell-conviction`, executable `C:\Games\SplinterCellConviction\src\system\conviction_game.exe`, arguments `-offline -offline_mode`, CPU `native`, D3D11 via DXVK.
- Prefix hosts file: `/data/prospero-win/prefixes/splinter-cell-conviction/drive_c/windows/system32/drivers/etc/hosts`:
  ```text
  127.0.0.1 localhost
  127.0.0.1 onlineconfigservice.ubi.com
  127.0.0.1 lb-rdv-as-prod01.ubisoft.com
  ```
- Runtime evidence: `onlineconfigservice.ubi.com` resolved to `127.0.0.1`; the attempted connection was refused (`0xc00000a3`), as expected for the local sink. `gconnect.ubi.com` was also queried in an earlier run and is not in this hosts file; whether it matters is unresolved.

## Crash trace

The 10:29:17.923 first exception is in the 32-bit guest `ntdll.dll`, not a PS4 GPU timeout:

- Thread `0050`, `EXCEPTION_ACCESS_VIOLATION`, read from address zero.
- Runtime EIP `0x7bf583f0`, with 32-bit `ntdll.dll` loaded at `0x7bf20000`. The exact package DLL maps this to RVA `0x383f0`, instruction `mov (%esi),%edx` in `RtlWakeAddressAll`; `ESI=0`.
- The wake key in `EDI` is `0x02e79990`; the queue lock in `ECX` is `0x7bfd50ac`.
- The thread snapshot shortly before the fault shows another guest thread (`0054`) contending on the same wait queue. This points to a damaged or inconsistent Wine address-wait list. The trace does not identify which earlier insertion/removal caused it.
- No GoldHEN `.sorbisdmp` was retrieved. The in-process `PW_EXCEPTION32` trace and the exact package DLL were sufficient to map the fault.
- The `PW_WINE64 alive` counters in this run are not enough to explain the reported audio cutoff: `audio` continued increasing, while `audible` paused for part of the run, rose again before the crash, and then stopped when the guest crashed. Correlate audio counters with scene transitions on the next run.

Captured files:

- `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/crash-window-1029.log`
- `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/runtime-tail-at-crash-1029.log`
- `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/klog.log`
- Exact staged DLLs: `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/symbols/`

## Diagnostic candidate prepared, not installable yet

The exact Slackian `wine-host` source already had `PW_PS4_FUTEX_LOG` wait/wake tracing, but the shipped 02.62 `i386-windows/ntdll.dll` did not contain it. I added an address-bucket filter so the next trace can log only the queue bucket that crashed. The key `0x02e79990` hashes to bucket `153` using Wine's `(address >> 4) % 256` rule. This avoids logging every wait/wake in the game.

- Diagnostic DLL SHA-256: `5ac89a4c22d1c1cfd1b93665a9fd041d44f9766473093490d24a4748b4dec99c`.
- Candidate package built from the 02.62 stage, replacing only `win/wine/lib/wine/i386-windows/ntdll.dll`; version set to 02.63.
- Candidate filename: `IV0000-GLDS10043_00-GLDS100430000000.pkg`.
- Candidate SHA-256: `19891804a9c95e74569d67d231411fc7508e06f30199114b41e55aa1d376d363`.
- Candidate size: `506593280` bytes.
- Candidate path: `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/package-0263/`.
- **Do not install this candidate yet.** `check-ps4-package-parity.py` did not pass, and `PkgTool.Core pkg_validate` was not run.

The candidate profile copy adds these `[debug]` entries:

```ini
env = PW_PS4_FUTEX_LOG=1
env = PW_PS4_FUTEX_BUCKET=153
```

It is at `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/splinter-cell-conviction-futex.profile` and has **not** been uploaded to the console. The original console profile was downloaded to `splinter-cell-conviction.profile`; it currently has `PW_NATIVE_PROFILE=1` and `PW_WAIT_WATCHDOG=1`.

## Why the package gate failed

The parity command was given `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/prx`, which is an older 11/04 PRX build directory. It does not match the packaged baseline PRXs:

- 02.59 stage `ntdll.prx`: `81d0e7d3957f4217b1b86d1b1d8afbdeb8281f2b6da8f13bcec4f5c5e1cd1dea`.
- 02.59 stage `wineserver.prx`: `1e5864578ca42b2a0c06e8483cddac8fdfcea0c63b77d61334296183e5af45b3`.
- Supplied 11/04 PRX directory has different hashes (`d7eca...` and `0b5e...`), so its export checks were skipped and its ELF files produced `SIG_BLOCK` failures that do not describe the staged PRXs.
- The current Slackian `.deps/wine-ps5/prx` output has an `ntdll.prx` matching the stage but a different `wineserver.prx` (`7e9eb436...`). It is not a matching build directory either.

Parity output is saved at `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/package-0263/parity.txt`. Before installing anything, recover or recreate the exact PRX build directory for the staged 02.59/02.62 PRXs and rerun parity with that directory and the matching upstream source. Do not bypass the gate by relabeling or copying PRXs into an unrelated build directory.

The attempted `--upstream-root` was the local `splinter-prefix-hosts-source` checkout, which has no nested `.deps/wine-host/source/dlls/kernelbase/debug.c`; parity therefore warned that `PW_EXCEPTION32` reachability was not checked. When resuming, use a source root that includes the matching nested Wine source as well.

## Tree state — preserve these changes

Local Playden/Orbis-Win integration worktree:

- `/home/zpeirce/codex_scratch/splinter-prefix-hosts-source`
- Branch `codex/splinter-prefix-hosts-20261117`, based on `75f25351354b866e8cae8c17e828e386651ddb7e`.
- Uncommitted intended change: `wine/ps5/pw_ws2_32_libc.c`, reading prefix `hosts` before the SCE resolver. Keep it; it is the tested offline-resolver change.

Slackian build host (`slackian`):

- Orbis-Win root `/home/zpeirce/codex_scratch/abi4-upstream-port-20261104/source` is back at detached commit `5d1cb4f`; no changes there.
- PE Wine source `/home/zpeirce/codex_scratch/abi4-upstream-port-20261104/source/.deps/wine-host/source` is on branch `codex/splinter-futex-trace-20261117`, based on `0f6e2e6`. It has an **uncommitted** `dlls/ntdll/sync.c` bucket-filter patch. The i386 `ntdll.dll` rebuilt successfully. Preserve this branch and diff if resuming; do not apply the earlier full-trace patch again, because that code already existed in the source.
- PS4 Wine source `/home/zpeirce/codex_scratch/abi4-upstream-port-20261104/source/.deps/wine-ps5/source` remains on `codex/splinter-osi-trace-20261117` at `07492ab46e`, clean. It was not changed during this trace work.

The top-level `/home/zpeirce/ps4-gladius` checkout has pre-existing user changes (`AGENTS.md`, two handoffs, a Risk of Rain 2 profile, and `worktrees/`). Leave them untouched.

## Resume sequence

1. Confirm the console is still at the Orbis-Win launcher and re-arm the runtime/klog/coredump listeners before the next launch.
2. Resolve the exact matching PRX build-directory issue first. Use the 02.59 source/build inputs recorded in `/home/zpeirce/junk/codex_scratch/orbis-hk-0259/BUILD-MANIFEST.txt`; the later 11/17 PRX outputs are not interchangeable with the staged PRXs.
3. Rerun parity against the 02.59 baseline and the 02.63 stage with the exact matching `--elf-dir` and upstream root. Then run `PkgTool.Core pkg_validate`. Install only if both required gates pass.
4. If installed, upload the filtered profile so only bucket 153 is traced. Reproduce once and compare `PW_FUTEX wait/woke/wake-all/wake-one` entries for that bucket to find how its list becomes invalid.
5. Continue tracking the loading stall and audio independently; reaching the gameplay menu or first controllable scene is the success criterion.
