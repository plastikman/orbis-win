# Splinter Cell: Conviction handoff — 2026-11-17

## Goal and current result

Get Splinter Cell: Conviction into gameplay. The current no-sampler A/B run avoided the earlier startup crash but hung at the same cutscene/loading transition. In-process diagnostics and exact game disassembly place the guest main thread in a game-side cleanup wait loop. Gameplay has not been reached.

The offline resolver change is confirmed in the logs. The latest crash is a native `libkernel.sprx` SIGSEGV. The guest-sampler signal path is a plausible contributor because the faulting Unix thread is the same thread the sampler poked; that relationship needs an A/B run before assigning causality.

## New run — 2026-11-18

The user installed and launched the newer Orbis-Win build, reached the menu and intro, then the loading screen stopped progressing. The user closed the game after the trace was captured.

- Runtime marker: `GLDS10043-fromsource-hosts-1118`. The Playden update checker reports this test package is still 0.0.6 and that v0.0.7 is available.
- Exact profile: `splinter-cell-conviction`, `C:\Games\SplinterCellConviction\src\system\conviction_game.exe`, args `-offline -offline_mode`, native WoW64 CPU, DXVK, XInput.
- Captured log: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/ps5log-20261118-060751.log`, SHA-256 `05361b8bb46f2ff00659572c7ee508bf9095d5828d08e48e8ade85706e01a446`.
- RADV continued submitting and presenting frames at roughly 156 presents per five seconds with no GPU wait. This rules out a GPU-submit stall for that run.
- The wait watchdog repeatedly found guest thread `0024` outside a Wine wait, with the same stack for over 17 minutes. Disassembly of the exact `conviction_game.exe` maps the game frames to `FCleanupDestroyedMT`: the code at `0x456038` polls a counter pointer until it clears, yielding through `Sleep(0)` at `0x456032`. Its constructor/caller passes the outer object's member at `this + 0x2b4` as that counter. This establishes an application-side cleanup wait; it does not yet identify which worker failed to decrement the counter.
- The watchdog also reports an async operation for thread `0024` that remains pending and queued, with no fd details. Wine request 31 is `event_op`. These records are concurrent with the cleanup wait; their causal connection is not proven.
- The `gconnect.ubi.com` and `onlineconfigservice.ubi.com` lookups occur after the main thread has entered the cleanup wait. They are not a strong explanation for the initial stall, though later offline-service behavior remains unverified.
- `PW_PS4_FUTEX_LOG=1` produced 4.64 million futex records and a 769 MB log. Waits at `0x02d6f2d8` and `0x02d6f2dc` largely return `STATUS_TIMEOUT`; recorded wake counts are close to wait counts. This trace did not establish a lost futex wake. The log was moved to the scratch mount to free root space.

### Next run is prepared

The console profile now removes `PW_PS4_GUEST_SAMPLER=1`, which triggers one-time SIGALRM pokes and runs the native signal handler. `PW_NATIVE_PROFILE=1` and `PW_WAIT_WATCHDOG=1` remain enabled. This is a controlled A/B for the crash below; the watchdog still logs guest PCs/stacks without injecting signals. Full `PW_PS4_FUTEX_LOG` remains off.

- Original sampler profile backup: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/profile-readback.profile`, SHA-256 `47d79f49e9ffede9335ed5634117f6c441e1ae4b8aa95db40114c8ef072c58bb`. The console copy is retained as `/data/prospero-win/profiles/splinter-cell-conviction.sampler-20261118.profile`.
- Current profile readback: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/profile-no-sampler-readback.profile`, SHA-256 `ca87b05b3db380ab952d773366b77758fa48f7133f59712ea9ebcca83edaad53`.
- Runtime log listener is armed on TCP port 9300 and writes under `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/build-ps4-logs/`.
- Current PS4 klog: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/ps4-klog-20261118-072139-watch.log`. The klog reconnect watcher and a coredump watcher are running for title `GLDS10043`.
- No Wine source change or new package was retained from the attempted async-origin instrumentation; that attempt was reverted. Slackian Wine source remains on `codex/splinter-osi-trace-20261117`.

The no-sampler rerun was launched at 07:40:32 and stayed active until 08:01:19, when klog recorded `SceLncService BlockingKill` and the Wine logger disconnected. It did not crash; the user confirmed it hung at the same point. This separates the two symptoms: the sampler is correlated with the earlier fast crash, while the loading/cutscene hang also occurs with sampler disabled.

- The runtime logged `debug_env=PW_NATIVE_PROFILE,PW_WAIT_WATCHDOG`; there was no `PW_PS4_GUEST_SAMPLER` and no futex logging. The read-back profile hash is recorded above.
- The latest snapshots repeatedly show guest thread `0024` at Wine's `NtDelayExecution` return site `0x7bf2d5b0`, with game return addresses `0x00456038` and `0x007d45f6`. The same PCs recur across snapshots minutes apart. A second guest thread, `011c`, is independently at the same Wine return site with game PCs `0x00456fd8` and `0x00455fdb`.
- Disassembly of the exact executable (`conviction_game.exe`, SHA-256 `8816fb0ff9417822f933d6e2fa057e387fbbb27a32582b295c9ca9ddbedbf370`) shows thread `0024` at `0x456038` loading `[esi+0x10]`, testing it, and looping through `Sleep(0)` at `0x456030` until that field becomes zero. The caller at `0x7d459d` initializes a stack-local callback/wait structure, registers work, calls the cleanup routine, then waits on that counter before cleanup. This matches the previously mapped `FCleanupDestroyedMT` wait; a pending cleanup callback is not completing.
- Thread `011c` is in a different game loop: `0x456fd8` reloads `[esi+0x220]`; when it is zero, control loops through `0x456d8f` and `Sleep(0)` at `0x456fd2`. Its caller at `0x455fd8` is an indirect object method, inside code that also calls `WaitForMultipleObjects` and `SetEvent`. The logs do not expose those handles or identify why the `+0x220` state stays zero. Both guest threads are actively spinning, rather than blocked in Wine waits. This gives a concrete chain to trace: the cleanup completion wait in `0024` and the still-pending object operation in `011c`.
- At 08:01:19, after more than 20 minutes at the hang, runtime counters were `frames_put=7`, `shown=0`, `audio=228965`, `audible=25110`; the frame count never rose from 7, and audible audio stopped advancing. CPU time reached 3,485,725 ms. These counters support a stall, not normal cutscene progression.
- Guest thread `0048` remains in a Wine wait (`age_ms` over 4 minutes). The runtime log's 77 MB of repeated `wake_up` lines were reduced to a 9.6 MB filtered session log; every other line was retained.
- Filtered session log, through the 08:01:19 disconnect: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-no-sampler-20261118.log`, SHA-256 `44226d2d113e9a599cf80eeeb0acf1829d032d00a4cd7df1d96faf55a413d5d5`.

### `+sync` profile run — 2026-11-18 08:08–08:14

No package was built. The profile included `winedebug = +sync`; it kept the sampler disabled and retained native profiling and the wait watchdog. The launcher accepted the profile, but the runtime still logged its default WINEDEBUG value and emitted no actual `trace:sync` records. The only `trace:sync` match in the filtered file is its explanatory header, not a Wine log entry. Therefore this run did **not** trace event handles/results, and the setting cannot be treated as effective. The initial attempt used `env = WINEDEBUG=+sync`, which the launcher refused because profile `env=` entries are limited to `PW_*` variables; replacing it with `winedebug = +sync` fixed profile acceptance but did not change runtime WINEDEBUG.

- Installed console profile `/data/prospero-win/profiles/splinter-cell-conviction.profile` was read back and hash-verified: `01e8ef82e99ff10320455faedb0ca4872c97939e8f22e982b88765c0dc0f83fc`.
- The preceding no-sampler profile was preserved on console as `/data/prospero-win/profiles/splinter-cell-conviction.no-sampler-20261118.profile` and locally at `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/profile-before-sync-trace.profile`.
- The refused intermediate profile is preserved on console as `/data/prospero-win/profiles/splinter-cell-conviction.unsupported-env-20261118.profile` and locally as `profile-installed-sync-trace-readback.profile`.
- Local trace profile and console readback are under `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/`.
- The user launched at 08:08:23 and closed the game at 08:14:29; klog recorded `SceLncService BlockingKill` at 08:14:30. There was no crash. The main guest thread remained at the same cleanup spin (`0x456038`); the worker remained at `0x456fd8`. Counters at the last snapshot were `frames_put=7`, `shown=0`, `audio=63337`, `audible=24991`, CPU time `1,051,504 ms`.
- Filtered session log: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-sync-profile-noeffect-20261118.log`, SHA-256 `398362eef539892d61a8a855008564aed83c65394fbecedb4c10be1fdbbc8cfe`.
- Re-arm/check the runtime logger and coredump watcher before the next launch. First establish why the runtime ignored the supported profile `winedebug` field; do not spend another console run expecting `+sync` until the effective WINEDEBUG is confirmed.

### WINEDEBUG override identified and corrected

- Retrieved the exact installed package read-only from `/user/app/GLDS10043/app.pkg`: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/installed-package/app.pkg`, 532,480,000 bytes, SHA-256 `837464fec1090bca4612cf2fde3ea3c15be24a9ced991839a7c71a41ea995bcd`. Extracted payload is under `installed-package/extracted/uroot/`. Its `eboot.bin` SHA-256 is `2d79954fcd5eea1a5cdf3b3367e0a2bd694ec9e23a6bb950d35ea427d711cf7d`; `sce_module/relocated_wine_app.prx` is `32921008670eee45ef09b84124d7f9bc91df7ecf102438dc86fbd143f3ed9705`.
- The actual cause was the separate per-game settings file `/data/prospero-win/settings/splinter-cell-conviction.conf`. Its comment says these Game Card settings override the profile, and it contained `winedebug = err+all,warn+all,fixme-all,+loaddll,+process,+seh,trace+winsock,trace+wininet,trace+iphlpapi`—exactly the value logged at runtime. The profile's `winedebug = +sync` was therefore being overridden. The runtime's `debug_env=PW_NATIVE_PROFILE,PW_WAIT_WATCHDOG` also confirms profile debug environment fields were read.
- Corrected the per-game settings file to retain `mode = xinput` and set `winedebug = +sync`. Uploaded and read back the console file; both have SHA-256 `b4ddb3aad33485630fdb6955d60c228f76842c92c74ea49c7d72b5984ad7a6b3`. The local uploaded copy and readback are in `installed-package/splinter-cell-conviction.conf` and `.readback`.
- The active console profile was also re-read and still matches `01e8ef82e99ff10320455faedb0ca4872c97939e8f22e982b88765c0dc0f83fc` with `[debug] winedebug = +sync`.
- The profile directory also contains three saved backup files whose contents share the same application ID. They are not selectable: their extra dots make their filenames invalid under `pw_wine_library.c::profile_name()`, which accepts only lowercase letters, digits, hyphens, and underscores before `.profile`. The active `splinter-cell-conviction.profile` is the sole valid Splinter profile, so duplicate IDs do not explain the observed value.
- The installed package's EBOOT matches the workspace's generic relocation stub, but no retained stage or PRX build directory matches the installed app PRX. This provenance gap is not needed to proceed with the current config-only trace. No package was built or installed.

Next: the console is ready for another launch with `+sync` effective. Confirm the new `PW_WINE64 winedebug=+sync` line and capture Wine sync records around the persistent callback/event wait. Keep the sampler disabled so it does not reintroduce the unrelated startup crash. Do not switch to `/home/zpeirce/junk/orbis-fromsource/`; that is a future source path, not the current build tree.

## Crash run with guest sampler — 2026-11-18

The second run used marker `GLDS10043-fromsource-hosts-1118`, native WoW64, DXVK, and the same offline arguments. It disconnected about 30 seconds after launch; PS4 klog later confirmed an application crash.

- Isolated Wine log (excludes later Playden/HL1): `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-run-20261118-0719.log`, SHA-256 `6c96abd261a14c94a23f84c951c83c29ce42fa2f140b5de2baae617bf051f4bc`.
- PS4 klog crash snapshot: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/klog-crash-snapshot-20261118.log`, SHA-256 `90aad94980350bec6f51a3604f9402661944da400a2702bcf745acde2237f13a`. The live reconnect log continues at `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/ps4-klog-20261118-072139-watch.log`.
- GoldHEN reports `SIGSEGV` (signal 11), user-read page fault at `0x1f88`, on Unix thread `119442`. RIP is `0x80000c742`, inside the exact console `libkernel.sprx` (module text begins at `0x8000000000`). The faulting instruction is `movl (%rax),%eax` with `RAX=0x1f88`. Exact module copy: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/coredumps/libkernel.sprx`, SHA-256 `8b8c1c2f7a9eb84ae583944bf3a389bb4a64ded0058ad745c238477e766ab56a`. No matching `.shared.elf` is available locally, so the function name is unresolved.
- The crashed Unix thread `119442` is exactly guest thread `0048`, previously targeted by `poke silent tid=0048 unix_tid=119442`. This strongly correlates the fatal fault with the sampler but does not yet prove the signal caused it.
- The sampler's logged interrupted RIP for that thread was inside `libkernel.sprx`. The current source handler in `src/native/pw_wine_dmem_glue_ps4.c` calls `snprintf` and `sceKernelDebugOutText` from the SIGALRM handler. Re-entering libkernel while the interrupted thread is already inside it is a concrete safety concern.
- Separately, guest thread `004c` is repeatedly executing `Sleep(0)` from game code at `0x456fd2`, returning to the loop at `0x456fd8`, which polls `this + 0x220`. The exact executable was retrieved from the active console prefix to `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/conviction_game.exe`, SHA-256 `8816fb0ff9417822f933d6e2fa057e387fbbb27a32582b295c9ca9ddbedbf370`.
- The fatal process generated `/user/data/sce_coredumps/GLDS10043_1795018817/GLDS10043_1795018817.sorbisdmp`; Crash Reporter later deleted it. The exact FTP `RETR` returned 550. Do not plan an investigation around decrypting that dump; use in-process diagnostics and klog as specified in `AGENTS.md`.
- A separate Playden/HL1 session appears later in the same Wine log. It is unrelated to this Splinter crash and must not be mixed into its analysis.

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

## 2026-11-18 latest run — `+sync` trace, user closed at loading screen

The latest launch used the existing 02.62 package; no new package was built or installed. The console's effective per-game debug override had been corrected to `winedebug = +sync`, and the launch log confirms `PW_WINE64 winedebug=+sync`. The profile remained native WoW64, DXVK, offline arguments. The user reached the loading screen and closed the game. The Wine log ended with a normal guest-exit/disconnect; the later klog contains only Playden launcher activity and no new application crash. This is a stall reproduction, not a crash reproduction.

Captured trace:

- Complete session-filtered trace: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-sync-084555-filtered-20261118.log` (1,524,750 lines, 163,420,830 bytes, SHA-256 `e1cccc93b9e39a3f7b0346b1fbd9c2e5d7042b0502a0a7092620d361b2c4f8f1`). It omits only repetitive `wine-ps5: wake_up` and `trace:sync:RtlWakeAddress*` records; other session records are retained.
- Live targeted sync trace: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/sync-events-live-20261118.log`; it began about 90 seconds after launch and is incomplete. The complete filtered trace above is the source for startup and full-session analysis.
- Klog listener: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/ps4-klog-20261118-072139-watch.log`. The listener remains armed for a possible next run. No new dump was retrieved; the existing coredump directory contents are from earlier runs.

Stall evidence near user close:

- At 08:51:51, `PW_WINE64 alive` reported `frames_put=7`, `shown=0`, `vk_shown=167`, `vk_busy=1`, `inputs=142`, `audio=62080`, and `audible=25146`. The `audible` counter had plateaued while `audio` kept increasing. Together with the user's loading-screen observation, the game remains stalled without presenting further frames; audio generation alone does not show forward game progress.
- Watchdog snapshots show guest threads `0024` and `011c` actively running (`waiting=0`), repeatedly in game-side loops around `0x456038` and `0x456fd8`; these are not blocked in Wine waits. Their earlier disassembly maps the latter to a game-side `Sleep(0)` poll of an object field at `this + 0x220`.
- The sync trace is dominated by a repeated worker pattern: thread `0068` sets events `0x4bc` and `0x564`; `00b8` waits on `{0x4bc, 0x4c0}` and returns success; `0124` waits on `0x564`; thread `00b0` polls event `0x494` with a zero timeout and receives `STATUS_TIMEOUT`. This pattern is high-volume but not yet tied to the game-side poll or proven to be the cause.
- Snapshot async state for threads `0024` and `0044` shows outstanding queued requests (`initial=iosb=STATUS_PENDING`, `pending=1`, `signaled=0`, `queued=1`, `blocking=0`, `system=0`, no completion port). Their `fd` objects have Unix fd `-1` and no Unix name. This makes a server-managed/device-style async a candidate, but the watchdog does not print the fd type, Windows device path, or IRP operation, so the owner is unproven. Do not conflate these watchdog async-I/O records with `event_op`/`NtSetEvent`; those are separate mechanisms. The trace has not identified what completion or callback the game is polling.
- Source inspection of `server/async.c` confirms `queued=1` means the async still belongs to a server async queue; `pending=1` and `signaled=0` mean it has not completed/signaled. `fd=-1` in this record is the fd's Unix descriptor, not a null async fd. The device-file path queues an IRP and marks initial status unknown until the device callback responds, so `unknown=0` here does not prove this is a device request. The guest main thread is not deadlocked in a Wine synchronization wait. Evidence points to active game-side polling while two async requests remain pending, but does not prove they are causal or identify their subsystem.

After the Splinter session disconnected at 08:51:52, a separate session launched Risk of Rain 2 (`steam-632360`, build marker `GLDS10043-vkbun`) at 08:56:24 and returned to the launcher at 08:56:58. That later session is unrelated and must not be mixed into the Splinter trace or attributed to the current source tree/build.

Next investigation should continue from this trace and matching source, without another blind setting/package change: identify which requests created async records for `0024` and `0044`, and expose their fd type, Windows path, and device IRP operation in a future watchdog trace; then correlate their completion with the game thread's `this + 0x220` poll. Keep event-worker noise separate unless a handle can be connected to either request. The existing diagnostic package candidate remains gated by the exact-PRX parity issue above; do not install it unless parity passes.

## 2026-11-18 offline Ubisoft probe staged; not yet run

The user closed the latest Splinter Cell attempt at the loading screen. No further launch was made. Existing runtime-log, klog, and coredump listeners are still running (ps5logd on 9300; `watch-klog.sh`; `watch-coredump.py` for `GLDS10043`).

Earlier session evidence records DNS/connect attempts to Ubisoft endpoints after the game has already entered its cleanup polling loop: `gconnect.ubi.com` was queried and the game attempted `216.98.50.240:3074`; `onlineconfigservice.ubi.com` resolved to `127.0.0.1` and its connection was refused. The active prefix did not map `gconnect.ubi.com`. Ubisoft's online services for Conviction are shut down. The community `Ododo/scc-lan-restore` project documents the `gconnect.ubi.com:3074` config request and a local matchmaking-config response. This makes a local response a useful controlled experiment, but does not establish that Ubisoft networking causes the loading stall: the requests observed so far happened after the game-side cleanup loop began.

A reversible console experiment is staged, but has not been launched or evaluated:

- A small 32-bit Windows helper listens on `127.0.0.1:3074`, returns the static matchmaking-config response, logs requests to `gconnect-helper.log` in the game working directory, and starts the original `conviction_game.exe -offline -offline_mode` as a child. Source and built artifact: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/gconnect-helper/gconnect_wrapper.c` and `gconnect_wrapper.exe`; executable SHA-256 `771e9c8484757ebd75f69b09c1ad800d1732ad02abccc409e80e84b8c9f5a39f`.
- The console prefix hosts file now adds `127.0.0.1 gconnect.ubi.com`. Before/after copies are `gconnect-helper/hosts.before` (SHA-256 `122328c887c4b45561c82ce1e1275eeae2c1157eaf1a5234e18c9a5c1104114e`) and `hosts.after` (SHA-256 `4220cdf716d9df15983809c649088d16679c09886247718e5aebfa57ff71ce79`).
- The console profile now points to `C:\Games\SplinterCellConviction\src\system\gconnect_wrapper.exe`, with argument `relay`; native CPU, DXVK, XInput, watchdog, and `+sync` settings are retained. Before/after copies are `gconnect-helper/profile.before` (SHA-256 `01e8ef82e99ff10320455faedb0ca4872c97939e8f22e982b88765c0dc0f83fc`) and `profile.after` (SHA-256 `126a0a91c9544b1a64f20ac790e738be239dae5468345aef6d493d063b8c6285`). Console readbacks match the staged helper, hosts file, and profile byte-for-byte.
- The response payload was adapted from the static config in `gconnect-helper/scc-lan-restore`; no third-party server code was executed. The source project has no license file in the checkout, so do not redistribute this helper or payload as a project artifact without resolving its licensing/provenance.

If this probe is run later, first capture the helper log and verify it reports a request and a complete response. Compare the game progression and the same thread/poll diagnostics with the prior run. Restore `profile.before` and `hosts.before` to roll back; remove `gconnect_wrapper.exe` from the prefix if desired. This is a console profile/prefix experiment only: no Orbis-Win package was built or installed, and no source-tree change was made for it.

## 2026-11-18 filtered futex package ready for user install

The filtered bucket-153 diagnostic package has now been built from the Slackian 02.62 offline-hosts package and uploaded for the user to install. It preserves that package's full payload; the only changed game payload file is the i386 PE `ntdll.dll` containing the filtered futex trace. APP_VER and VERSION are 02.63. The unrelated 532,480,000-byte package previously in `/data/pkg` was the 01.01 fromsource artifact and was not used as the build base; the user had explicitly directed work to continue from Slackian's tested 2.59 generation.

- Installer path on console: `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`.
- Package size: 506,593,280 bytes. SHA-256: `8c8994df42645953d81549cb0fe331a90ba4623976f4eca008c41858e3cf9ad2`. The console readback has the same size and hash.
- Exact base package: `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/console-readback-0262.pkg`, SHA-256 `468633cdf664ec610ea54f74beeaa5fcc992788c9e33811ed8a898d55296c4cc`. It was extracted with `PkgTool.Core pkg_makegp4`, then only the i386 `ntdll.dll` plus APP_VER/VERSION were changed.
- Parity passed against both the 02.59 baseline and the full 02.62 source package. There are zero baseline payload omissions and zero parity hard-gate failures. `PkgTool.Core pkg_validate` passed every check. Extracting the final package matched all 1,820 payload files in the stage byte-for-byte.
- The staged i386 `ntdll.dll` SHA-256 is `5ac89a4c22d1c1cfd1b93665a9fd041d44f9766473093490d24a4748b4dec99c`. `strings -el` confirms both `PW_PS4_FUTEX_LOG` and `PW_PS4_FUTEX_BUCKET` are compiled in. Set bucket 153 for the queue at `0x02e79990`.
- The active profile was uploaded to `/data/prospero-win/profiles/splinter-cell-conviction.profile` and read back byte-identically (SHA-256 `428812c52400d820dbbdee420d3c1c531bef742e2f261d3fda47df206add0c5e`). It launches the local `gconnect_wrapper.exe` with the offline game args, enables futex bucket 153 tracing, and retains native WoW64, DXVK, XInput, wait watchdog, and `+sync`. The wrapper/helper and prefix hosts entry are already on the console. The local manifest and exact package/profile readbacks are in `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/package-0263-rebuilt/`.
- Runtime logger on port 9300, klog watcher, and GLDS10043 coredump watcher are alive. No game launch has occurred with this package yet. The user will install this exact installer and run it; do not install it on their behalf.

Do not use the earlier 02.63 candidate at `/home/zpeirce/junk/codex_scratch/splinter-offline-20261117/package-0263/`; it was built from a stale 02.59 stage and omitted the 02.61/02.62 changes. The correct package is the rebuilt artifact with SHA-256 `8c8994df42645953d81549cb0fe331a90ba4623976f4eca008c41858e3cf9ad2` listed above.

## 2026-11-18 wrapper chain configuration corrected

The next launch returned to the launcher because the profile itself had been changed to run `gconnect_wrapper.exe`. That left the game card's `other_program` flag unset, so the runtime logged `exec_chain=off chain=0`; when the wrapper tried to start `conviction_game.exe`, Orbis-Win correctly refused the child process. This was a launch configuration error, not a new game crash.

Corrected the console configuration using the supported game-card Program mechanism:

- The profile again launches `C:\Games\SplinterCellConviction\src\system\conviction_game.exe` with `-offline -offline_mode`; its native profile, watchdog, futex bucket-153 trace, XInput, DXVK, and `+sync` settings remain.
- `/data/prospero-win/settings/splinter-cell-conviction.conf` now sets `[application] executable = gconnect_wrapper.exe` as a relative program beside the game executable, while preserving XInput and `+sync`. This should set `other_program`, permit the wrapper's child launch, and produce `exec_chain=on` in the next startup log.
- Both files were fetched back from the console and byte-compared to the staged upload. Readback SHA-256 values: profile `bfe02ae1e928b93440a3e623e18878aa504ff6c766944e920a8c144a10388c00`; settings `e2de8be0a379fed16c8148b4001ad19ba45ac40913e0ca1e0ccb3d6faeebc977`.
- No package rebuild or installation was needed. The next launch should first confirm `game settings ... applied`, `exec_chain=on chain=0`, and the wrapper's helper log records a request/response before interpreting game progress.

## 2026-11-18 wrapper-chain run — loading stall reproduced

The user launched Splinter Cell, reported reaching the intro cutscene and then the loading screen, and closed it at 09:55:21. This run confirms the wrapper chain is now functioning, but the game still reaches the same loading stall.

- Runtime log: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/build-ps4-logs/ps5log-20261118-070641.log`. The complete retained session excerpt is `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-wrapper-chain-20261118-filtered.log`, SHA-256 `d6581f8ab719921c15079410a3f37137770d1d5f1c22fa25cf56624969364294`. It omits only repetitive `wine-ps5: wake_up` and `trace:sync:RtlWakeAddress*` lines; the full raw log remains alongside it.
- At 09:49:02 the wrapper session reported `exec_chain=on chain=0`; Wine queued the `conviction_game.exe` child. It exited normally with `reason=exec-chain`. The following session at 09:49:08 reported `exec_chain=on chain=1`, the correct game executable, and `-offline -offline_mode`. No `exec refused` occurred. The app's build marker remains `GLDS10043-02.59-pw5d1cb4f753`.
- The wrapper's append-only `gconnect-helper.log`, retrieved to `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/gconnect-helper-0949-final.log`, records `game started pid=32`. There is no request/response entry. The earlier `CreateProcess failed winerr=50` in that same file predates the successful invocation; do not attribute it to this child launch.
- The game-side signatures match the earlier loading stall: snapshots through 09:55:19 repeatedly show guest thread `0024` at `0x456038` and thread `011c` at `0x456fd8`, both spinning with `waiting=0`; async request `tid=0044` remains pending/queued. The main thread age reached about 270 seconds. At the final snapshots, `frames_put=7` and `vk_shown=238` had not advanced since early startup; audio generation continued but `audible` plateaued at 25,969.
- No helper traffic was observed before the user closed the game. This run therefore confirms the process-chain fix but does not show the local Ubisoft response affecting startup. It reproduces the same application-side stall with the helper wrapper in place.
- The user closed normally: klog records `SceLncService BlockingKill()` at 09:55:21, followed by `GameSuspended`, process termination, and app unload. There is no new crash report or dump from this run.

## 2026-11-18 async-origin probe — package uploaded for user install

The 09:49 run reproduced the loading stall with the wrapper chain working. I built the next diagnostic package on Slackian from the tested 02.63 package stage, adding only the pending-async origin fields to `wineserver.prx` and changing the SFO version/title to 02.64. The package is uploaded to the console; the user will install and run it.

- Installer: `IV0000-GLDS10043_00-GLDS100430000000.pkg`, at `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`.
- Package size: 506,593,280 bytes. SHA-256: `2a52e15a8360fbea85a9101457f19c7992bb196217b7afc0ed2361d7a965c5dd`. FTP readback from the console matched byte-for-byte.
- SFO APP_VER/VERSION: `02.64`; title `Orbis-Win Splinter Async Probe`.
- Base: tested 02.63 package stage generated from the exact 02.62 console package readback. Compared with that stage, the candidate changes only `sce_module/wineserver.prx`, `win/wine/lib/wine/x86_64-unix/wineserver.prx` (matching copies of the same PRX), and `sce_sys/param.sfo`. The two wineserver copies have SHA-256 `112308fefa2c0b05f564185a9c7e09f79fc7bde3dcc0bf446134e07317e81d52`.
- Source: Slackian Orbis-Win root `/home/zpeirce/codex_scratch/abi4-upstream-port-20261104/source`, commit `5d1cb4f7537a37e1bde29b88e3d0704f239e020f`; Wine PS4 source branch `codex/splinter-async-details-20261118`, parent `07492ab46eca09edf5e4ddc8dd03001bacef5b4f`. The source changes are in `server/async.c` and `server/fd.c`; corresponding root patch is `wine/patches/1086-server-ps4-report-pending-async-origin.patch`, SHA-256 `9d35809b09b08724e08d31675b1c698530cd15e9a9bd85a4682a1fa9cf1393cb`. The patch and source modifications remain uncommitted on their dedicated branches.
- The new watchdog output identifies each async's originating request ID and guest parameters. For its fd, it prints the fd type and bounded NT pathname as UTF-16 hex, allowing us to tell what `tid=0044` is waiting on. Both newly added message formats are present in the exact PRX ELF and the staged PRX.
- Both required parity runs completed with zero hard-gate failures: against the 02.59 known-good stage and against the 02.62 source GP4 stage. `PkgTool.Core pkg_validate` passed every check. The full outputs are in `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/package-0264-async-origin/parity-v0259.txt`, `parity-v0262.txt`, and Slackian's package build log.
- Parity WARN disposition: compared directly with the tested 02.63 package stage, the candidate has no omitted payload and only the two matching wineserver copies plus SFO differ. Against the separate 02.62 GP4 *source* directory, parity reports `Project.gp4` and `dev.conf` absent; these are GP4 build inputs, not files in the tested package stage. It also lists older `ntdll.prx`/`win32u.prx` strings that occur in that source directory but not in the exact package-derived baseline. The candidate intentionally retains the PRXs from the tested 02.63 package stage for this single-variable async probe; it does not replace them with untested source-stage PRXs. The old wineserver watchdog format is replaced by the expanded format, which contains its prior status fields plus request/fd origin details. This comparison is retained for review at `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/package-0264-async-origin/parity-warnings-disposition.txt`.
- Do not install this package on the user's behalf. On the next run, keep the currently corrected wrapper configuration and debug profile; look for the async request ID, `async_data` values, fd type, and UTF-16 NT path for `tid=0044` (and `0024` if it remains pending), then correlate those records with the two game-side polling threads. The package is uploaded and ready for the user's installation.

## 2026-11-18 async-origin run — same loading stall; device probe ready

The user installed the 02.64 async-origin probe, launched Splinter Cell, reached the loading screen, and confirmed it hung at the same point. Klog shows a normal user close at 10:30:08; there was no crash. The new request-origin fields confirm the two long-lived asyncs are Wine device-file operations, but the logged Unix-fd NT name is empty because pseudo device fds keep their full name on the owning Wine object.

- Exact run log excerpt, with only repetitive `wine-ps5: wake_up` and `trace:sync:RtlWakeAddress*` records omitted: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-async-origin-102414-closed.log`, 1,509,343 lines / 161,655,932 bytes, SHA-256 `34700e60634546d8eecec3dc31616fa5a2b7325351e15bc1d239c4ef83bddabd`. The complete raw appended log remains at `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/build-ps4-logs/ps5log-20261118-070641.log`.
- At the last snapshot, thread `0024` was still active (`waiting=0`, `last_req=31`, `age_ms=261865`); thread `011c` was also active at the same game loop around `0x456fd8` (`waiting=0`, `age_ms=263760`). Thread `0044` was in a server wait. Pending async `tid=0044` came from request 136 (`read`) on handle `0x328`; `tid=0024` came from request 138 (`ioctl`) on handle `0x30c`. Both handles report fd type 6 (`FD_TYPE_DEVICE`), no Unix fd, and remain pending/queued. These may be related to the stall, but the trace does not prove causation.
- At 10:30:08, `frames_put=7` and `vk_shown=235` were unchanged; audio generation had reached 60,058 while audible remained at 25,870. This matches the earlier stalled presentation/audio signature. The helper log was read back from the prefix; this wrapper run logged `game started pid=32` but no request/response to its local port 3074.
- The package's internal build marker still reports `GLDS10043-02.59-pw5d1cb4f753`, inherited from the tested base package. The new `req=136/138` and `type=6` watchdog fields prove the 02.64 wineserver diagnostics were active.

### Follow-up package 02.65 uploaded

I added a second diagnostic to print a device fd's owning Wine object name as bounded UTF-16 hex. This uses the `device_file` object's `get_full_name()` method, which is where Wine retains the path for pseudo fds. The change compiled and linked into the Slackian PRX; its ELF contains `device_name_utf16=`.

- The Wine source remains on branch `codex/splinter-async-details-20261118`. The follow-up patch is `wine/patches/1087-server-ps4-report-device-object-name.patch`, SHA-256 `12000bf179a67acb2a38796fb287df4a75f22dc2d79fab52b34fd5b641def2af`. It reverse-checks against the current source; the earlier async-origin patch 1086 and this patch are both present in Slackian Orbis-Win's `wine/patches/`. Source edits remain uncommitted in `server/async.c` and `server/fd.c`.
- Package 02.65 is at `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`, size 506,593,280 bytes, SHA-256 `7b72b26c41899acd0cfbf5f089463d3dc9077facc45f3de9c6e6ef576b575f2f`. FTP readback matched byte-for-byte. Its SFO title is `Orbis-Win Splinter Device Probe`; APP_VER/VERSION are `02.65`.
- Built from the 02.64 candidate stage. Bytewise comparison shows no added or omitted payload files; only both matching wineserver PRX copies and `param.sfo` changed. Both parity checks had zero hard-gate failures (against 02.59 and 02.64), and `PkgTool.Core pkg_validate` passed all checks. Logs and stage are under `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/package-0265-device-origin/`.
- The one warning against 02.59 is the expected replacement of the old wineserver async-watchdog string by the expanded diagnostic. The direct 02.64 comparison has no parity warnings. The 02.65 package is uploaded but has not been installed; the user should install it before the next run. Keep the current wrapper, offline args, native CPU, DXVK, XInput, watchdog, and `+sync` settings.

## 2026-11-18 02.65 device-name trace — same loading stall

The user installed the 02.65 diagnostic package, launched Splinter Cell, saw the cutscene and then the familiar loading stall, and closed the title at 10:56:10. This was a user-initiated close through the PS menu: klog shows `ApplicationExitScene` and `KillApp`/`suspendApp` for `GLDS10043`. The runtime logger disconnected at 10:56:10.447. No guest crash or new coredump was reported; the coredump watcher found none for this run.

- Exact 02.65 filtered session trace: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-device-origin-105014-closed-filtered.log`, 1,531,062 lines / 164,070,865 bytes, SHA-256 `6cee41e222d27d601608ede4e9c047d4e9eecea02569a3130eb24449594c1c24`. It retains the session from 10:50:14.872 through close and omits only repetitive `wine-ps5: wake_up` and `trace:sync:RtlWakeAddress*` records. The full appended runtime log remains `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/build-ps4-logs/ps5log-20261118-070641.log`; matching klog is `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/ps4-klog-20261118-072139-watch.log`.
- Device path decoding is confirmed: async `tid=0044`, request 136 (`read`), handle `0x328`, is on `\Device\NamedPipe\orbit_osi_pipe`; async `tid=0024`, request 138 (`ioctl`), handle `0x30c`, is on `\Device\NamedPipe\orbit_ipc_pipe`. Both remained queued/pending with `STATUS_PENDING`, `signaled=0`, `blocking=0`, `system=0` through 10:56:09.672.
- `PW_ORBIT_OSI_PIPE` emitted 169 records, with the last event at 10:51:37.920. The final client request (25 bytes, queued at 10:51:37.910) was read by server thread `003c`, answered with a 9-byte reply at 10:51:37.917, and consumed by the client; the client then queued its next read. After that no more pipe protocol records appeared for roughly 4½ minutes. Since the game itself creates these named pipes and its internal server thread completed requests and returned replies, this run does not support a simple “missing Ubisoft helper process” explanation. The still-pending pipe operations are correlated with the stall but not proven causal.
- The first post-transition guest snapshots match the already-symbolized game-side loops from the exact executable (SHA-256 `8816fb0ff9417822f933d6e2fa057e387fbbb27a32582b295c9ca9ddbedbf370`): at 10:51:38.912, thread `011c` has return PCs `0x456fd8`/`0x455fdb`; at 10:51:39.964, thread `0024` has `0x456038`/`0x7d45f6`. The former is the repeated `this+0x220` poll; the latter is the `FCleanupDestroyedMT` counter wait. Both snapshots recur through the final seconds. This ties the 02.65 run to the same persistent game-side cleanup/poll stall seen in prior runs.
- Timeline counters: `frames_put` first reached 7 at 10:50:55.466; `vk_shown` reached 230 at 10:50:56.648; both stayed flat through close. Orbit pipe traffic ended about 42 seconds after those presentation counters stopped advancing. `audible` first plateaued at 25,800 at 10:53:40.698, while the audio-production counter kept rising to 60,936 by 10:56:09.559. These counters and repeated game PCs confirm no forward progress, but do not identify which game worker or callback failed to complete.
- At the final watchdog snapshots, threads `0024` and `011c` remained `waiting=0` with no new Wine requests for about 273 s and 275 s, respectively. Both named-pipe asyncs stayed queued and pending. The user closed the title; this was not a guest crash.
- The run’s profile was `splinter-cell-conviction`, XInput, DXVK, offline arguments `-offline -offline_mode`, with watchdog and `+sync` diagnostics. SFO was 02.65 and the new device-name records prove the 02.65 wineserver PRX was active, despite its inherited internal build marker `GLDS10043-02.59-pw5d1cb4f753`.

The trace narrows the next step: inspect the sync/game-thread evidence around the transition at 10:51:37 and map the requests and polling threads against the exact game executable and package symbols. Preserve the completed trace and klog above. Do not treat normal, successfully answered Orbit pipe transactions as a confirmed root cause or change the offline helper/profile without a specific hypothesis.

## 2026-11-18 next A/B: remove only `-offline`

The user confirmed Conviction launches on Windows and asked to try removing `-offline` from the PS4 profile. I preserved the console profile readback before changing it: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/profile-02.65-before-online-test.profile` (SHA-256 `bfe02ae1e928b93440a3e623e18878aa504ff6c766944e920a8c144a10388c00`). The revised profile changes exactly one line from `arguments = -offline -offline_mode` to `arguments = -offline_mode`; all CPU, graphics, controller, debug, and watchdog settings are unchanged. The revised profile is uploaded to `/data/prospero-win/profiles/splinter-cell-conviction.profile`; console readback matches the local candidate byte-for-byte (SHA-256 `3a03d693c21197d1e497de776867323fd94fa7a304ce7e9fe2d69d6d1767d13a`). Local candidate and readback are `next-run/profile-remove-offline-flag.profile` and `next-run/profile-remove-offline-flag-console-readback.profile`.

This is a one-token test, not a fully online run: `-offline_mode` remains. The active prefix hosts file also still maps `onlineconfigservice.ubi.com`, `lb-rdv-as-prod01.ubisoft.com`, and `gconnect.ubi.com` to `127.0.0.1`; its verified readback is `next-run/hosts-before-remove-offline-test` (SHA-256 `4220cdf716d9df15983809c649088d16679c09886247718e5aebfa57ff71ce79`). Those mappings were left untouched so the test isolates the requested argument. On the next launch, verify runtime `arguments words=` shows only `-offline_mode`, then compare whether it reaches the same cleanup loop and monitor any local Ubisoft connection refusal. If this single-flag change has no effect, a later test can remove `-offline_mode` separately. Restore the saved profile backup to return to the previous launch arguments.

## 2026-11-18 no-offline-arguments A/B — same loading stall

The user removed `-offline_mode` as well and launched again. The first attempt still used the already-loaded wrapper chain and therefore passed both old flags; I traced this to `/data/prospero-win/settings/splinter-cell-conviction.conf` selecting `gconnect_wrapper.exe`, whose source hardcodes `-offline -offline_mode`. I removed only that executable override from the settings file (preserving XInput and `+sync`), and kept the profile's arguments field empty. A subsequent fresh launch at 11:12:29 ran `conviction_game.exe` directly with `exec_chain=off`; no `arguments words=` line was emitted, confirming no game arguments. The direct launch produced the same loading stall.

- Filtered run log: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/splinter-no-offline-args-111229-closed-filtered.log`, 1,206,425 lines / 129,003,399 bytes, SHA-256 `a40c7cc8e097dd739871fcbf805b38c382378ee86caad9420e16ead5a5e2c492`. It omits only repetitive `wine-ps5: wake_up` and `trace:sync:RtlWakeAddress*` records. Raw source remains `build-ps4-logs/ps5log-20261118-070641.log`; matching klog remains `next-run/ps4-klog-20261118-072139-watch.log`.
- Orbit OSI pipe transactions were still succeeding through 11:14:01.725. The server thread returned a 9-byte reply to the last 25-byte request, after which the client queued its next read. At 11:14:02.879, the watchdog captured thread `011c` in the same `0x456fd8`/`0x455fdb` loop; thread `0024` was captured in the `FCleanupDestroyedMT` `0x456038` counter loop seconds later. Both repeated through user close. This reproduces the same transition-to-cleanup signature with both offline flags absent; the queued named-pipe operations remain correlated, not established as causal.
- Presentation/audio counters stayed flat at `frames_put=7`, `vk_shown=227`; `audible` reached 25,740 at 11:16:03.335 and stopped advancing while audio production continued to 46,066 at 11:17:04.502. The user confirmed the cutscene ended and the loading screen was stuck. Klog records the normal PS menu `ApplicationExitScene`/`KillApp` at 11:17:04.714. No crash dump was retrieved.
- Profile is currently argument-free. Current per-game settings are in `next-run/settings-direct-game-no-offline-args-console-readback.conf` (SHA-256 `9060f233ec7d69331f19d868fecf89dd7d82f7d0fbff8c991bf5d6aae038f8d9`); the previous wrapper settings are preserved at `next-run/settings-before-direct-flag-test.conf`. The previous profile with both offline flags is backed up at `next-run/profile-02.65-before-online-test.profile`. The prefix's Ubisoft hosts still resolve to loopback, so this was a no-command-line-flags test, not a fully online-service test.

The user is now trying a direct chapter load on the new direct-game configuration; runtime logging and klog monitoring remain active. Capture whether this avoids or reproduces the same transition before changing source or profile settings again.

## 2026-11-18 direct chapter attempt — same stall; investigation paused

The user attempted to load a chapter directly after the no-offline-arguments run reproduced the loading stall. The fresh launch at 11:17:16 used the direct `conviction_game.exe` configuration with `exec_chain=off`; the `gconnect_wrapper.exe` chain was bypassed and neither `-offline` nor `-offline_mode` was supplied. The user reported this remained stuck at the same point and has now said they are done chasing this game. Do not start another run or make another speculative profile/package change unless the user reopens the investigation.

- The direct chapter run also reached the same game-side cleanup polling loop: watchdog guest snapshots repeatedly show `tid=0024` at game PC `0x456038` (return through `0x7d45f6`, the previously symbolized `FCleanupDestroyedMT` counter loop) and `tid=0130` returning through game PCs `0x456fd8`/`0x455fdb`. These are the established loading-stall PCs from the prior offline and no-argument runs. The initial transient snapshot at 11:18:17 had a different Wine stack, but subsequent snapshots returned to the same game loops.
- This run had flat presentation/audio progress as well: `frames_put=7` and `vk_shown=229` remained unchanged; audible output plateaued at `25,750` while audio production continued increasing. At the last observed alive record, 11:22:38, the runtime was still ticking (tick 18,780; audio 54,812; audible 25,750). The log continued to append at that point, so the user’s “done chasing” message is not itself evidence that the game was closed; no close or crash is recorded in the captured tail yet.
- The OSI pipe had completed requests through 11:19:42.962; after the last 25-byte client request received a 9-byte response, the next read remained queued. Do not treat this correlation as proof the pipe causes the stall. This direct chapter attempt therefore does not distinguish chapter selection from the other tested launch paths, and it does not change the existing diagnosis: the game enters the same cleanup/poll state while presentation and audible output stop advancing.
- Raw runtime log: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/build-ps4-logs/ps5log-20261118-070641.log`. Matching klog: `/home/zpeirce/junk/codex_scratch/splinter-async-origin-20261118/next-run/ps4-klog-20261118-072139-watch.log`. The exact filtered run log has not yet been cut; if this investigation resumes, preserve a run-specific filtered log and check for the eventual session-end/klog records first.

The tested launch paths now include offline args, no `-offline`, no `-offline_mode`, neither flag (direct game executable), and direct chapter loading; all reported the same loading stall. More blind flag changes or another identical run are unlikely to add information. If this is revisited, proceed from the already captured game PCs and async request evidence, and state a specific falsifiable hypothesis before changing the profile or building another package.
