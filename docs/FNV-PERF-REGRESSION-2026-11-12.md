# Fallout: New Vegas performance regression — RESOLVED, not a code regression

> **Correction, 2026-11-12 16:15. The regression this document chases does not
> exist in the source.** It was an artefact of the build host. Everything below
> the "Original investigation" heading is kept as written, because the
> measurements are real and the eliminations are still valid — but its
> conclusion is wrong. Read this section first.
>
> `0193`, built on **slackian** from a tree that **contains 1084**
> (`ntdll.prx` carries 7 `exec chain` strings and `PS5 exec chain queued`),
> measured **36.2 and 37.5 in-world** on the same save — the *fast* range.
> 01.66 measured 30.5–38.1. So the 5x gap does not reproduce once the package
> is built on a working host.
>
> **SECOND CORRECTION, 16:45 — the build host was NOT the cause either.**
> 0194 (slackian, today's source) crashed at the same ; 0195 (slackian,
>  reverted to v0.0.5) runs at **37.8 in-world**. The cause is our
> own ** Migrate large executable ranges a page at a time**. It
> correlates perfectly across all six builds; the build host correlates with
> nothing. 0193 succeeded because it was built from v0.0.5 *source*, and I
> credited the host it happened to be built on — two variables moved at once.
> The 0192 "glue reverted" test only reverted to HEAD, which still contained
> , so it never removed the suspect.
>
>  was written for Hollow Knight (shadow-memory alloc error) and
> assumed "32-bit games never reached this". They do: FNV emits
>  records. It is reverted; Hollow Knight is expected to
> be covered by Leo's memory patches instead.
>
> ~~**What was actually wrong:** packages built on **linux-install**
> (10.168.2.188, the build host only since 2026-11-11) are defective. Four of
> them crashed FNV ~5 s in at an identical signature — fault address `0x1f88`,
> `rip 0x80000c742` in `libkernel.sprx`, CE-34878-0 — across *two unrelated
> Wine trees* and with `src/native` changes both present and reverted:
>
> | build | Wine tree | native glue | result |
> |---|---|---|---|
> | 0186 | hand-repaired | today's + instrumentation | fault `0x1f88` |
> | 0188 | hand-repaired | today's | fault `0x1f88` |
> | 0191 | 01.66 from kvm04 | today's | fault `0x1f88` |
> | 0192 | 01.66 from kvm04 | reverted | fault `0x1f88` |
> | **0193** | **slackian's (has 1084)** | today's | **runs, 36.2/37.5 in-world** |
>
> The slow 01.85 numbers in the table below are therefore best explained as the
> same host defect in a milder form (degraded rather than crashing), not as a
> code change. They were never reproduced from a package built elsewhere.
>
> **Cleared by this result:** patch 1084 (`ps5_chain_ends_wait`, the
> `NtCompareObjects` round trip per wait) — present in the fast 0193. Also the
> six-commit `3cca6a04 -> 4a89b392` scope, and the "ten files differ in
> `dlls/ntdll/unix`" analysis, which was in any case reading Leo's
> half-applied `git apply --reject` batch as if it were the 01.66->01.85 delta.
>
> **Still open:** why linux-install produces bad binaries. Until that is
> answered, **build on slackian** (see the memory
> `build-host-needs-a-control-build`). The first experiment on any build host
> is a control build of known-good source, before changing anything.

## Original investigation (conclusion superseded — see above)


Measured 2026-11-12 on hardware, same save (Goodsprings, "Meet Sunny Smiles"),
same prefix, same logging-off settings. Only the package differs.

| build | intro video | in-world |
|---|---|---|
| **01.66 (v0.0.5)** | **59.8** | **30.5, 37.5, 37.5, 38.1** |
| 01.85 / 0185 | 19.8–20.4 | 5.3, 5.5, 5.7, 6.5, 7.7, 12.6 |

Zak: "this normally ran at like 40-60 FPS", so 01.66 is the expected behaviour
and 01.85 is the regression. Reproduces every launch.

## Scope: 6 commits

The build manifests differ in exactly one field. `root_commit` is identical
(`017ef377`); `prospero_win_abi4_commit` goes **3cca6a04** (01.66, fast) ->
**4a89b392** (0185, slow). That is 6 commits:

```
4a89b39 runtime: keep Playden's log folders owner-only
1f53082 runtime: accept Playden launch descriptors under the title's own data root
73fcacd runtime: preserve Playden session across program chains
2ddbeb9 runtime: support Playden PS4 launch descriptors and sessions
d9bbb54 runtime: import 01.70 validated program launch changes   <- candidate
3647193 wine: Leo's effect compiler and desktop-window fixes (1076-1082)
```

`3647193` adds 7 patch files: six vkd3d-shader/d3dx9 **effect compiler**
changes (fx_2_0 pass assignment, sampler state initializers, TRUE/FALSE
states, NULL shader/texture states, ps_1_x as ps_2_0, ID3DXEffectCompiler
CompileShader) and one win32u message change (1082). Its commit message says
01.67 "passed FNV" — a *functional* pass; **nobody measured framerate**, which
is how a 5x drop got through.

## Ruled out, with evidence

- **Per-page executable migration** (ours, `src/native`, landed 01.75). 0185
  gained a runtime knob `PW_PS4_EXEC_MIGRATE_RANGE_MAX`; with it set to 0 the
  per-page path is provably off (`exec-range-per-page` count 0, down from
  71–164) and the intro still ran **19.9**. Not the cause.
- **Patch 1082** (`win32u: don't wait for the desktop window's owner`). 0186
  reverted just that hunk from `process_message()`; intro **20.7**. Not the
  cause. (The tempting story — `cache_thread_desktop_windows()` on every
  cross-thread SendMessage — is wrong: it early-outs once `top_window` caches.)
- **The translator.** FNV is native throughout: profile `[runtime] cpu =
  native`, `wow64native.prx` loaded, **zero** `wowprospero.dll` loads and
  **zero** `BTCpuSimulate`/`simulate entry` markers (AGENTS.md's own test).
  The `wowprospero` log prefix is just Orbis-Win's logging namespace — it tags
  `libkernel.sprx` and `eboot.bin` too, so it never indicated the translator.
- **Logging** — real but minor. FNV's Wine channel was emitting 28,794 lines /
  4.48 MB per 4 minutes (9,526 `fixme:mp3dmod:Unknown_QueryInterface`, plus
  the wait watchdog dumping every thread and sync object). Turning it off took
  that to +359 bytes and moved in-world ~6 -> ~8.5 FPS. Keep it off; it is not
  the 5x.

## Traps this cost us

- **The intro video is not capped at 20.** I claimed 20.4 was "the Bink videos'
  native rate" because the menu hit 57.6 at the same time. 01.66 plays the
  identical video at **59.8**. Menus are fast on both builds; only menus. Use
  the intro or in-world, never the menu, to judge this regression.
- **`log=0` does not silence everything.** It gates the app log to the PC.
  `PW_` records still go to klog through `sceKernelDebugOutText`, and
  `PW_NATIVE_PROFILE` / `PW_NATIVE_PC` / `PW_WINESERVER_HEAP_TRACE` were left
  **on in FNV's profile**, running a per-thread sampler and heap tracing. They
  also filled the 5-slot `[debug] env` array (`PW_GAME_DEBUG_ENV_MAX = 5`), so
  an added `env =` line was silently rejected as malformed.


## Isolated by package surgery, no compiling (2026-11-12)

Today's package and 01.66's differ in only **50 of 1795 files**. Extracting
01.66 with `PkgTool.Core pkg_extract` and rebuilding hybrid packages with
`pkg_build` isolates the regression without touching a compiler:

| package | PE DLLs | Wine PRXs | PS4 runtime | Obsidian intro | in-world |
|---|---|---|---|---|---|
| 01.66 | 01.66 | 01.66 | 01.66 | 59.8 | 30.5–38.1 |
| today (0185/0186) | today | today | today | 19.9 | 5.5–12.6 |
| hybrid A | 01.66 | 01.66 | **today** | **59.9** | **37.4–37.8** |
| hybrid B | 01.66 | **today** | today | **20.4** | — |

**The regression is in the six Wine unix PRXs**: `ntdll.prx`, `win32u.prx`,
`wineserver.prx`, `ws2_32.prx`, `xinput1_3.prx`, `wineps5.prx`.

Exonerated outright: the PS4 runtime (`sce_module/`, i.e. all five Playden
runtime commits incl. `d9bbb54`), and Leo's whole effect-compiler set
(`d3dx9_24`–`d3dx9_43`, `wined3d.dll`, `d3d12.dll`).

**Those PRXs are built from the hand-repaired Wine tree.** With 1082 already
ruled out, the likely cause is damage residue the five-file repair diff did not
catch — the repair verified those five files compile and define everything the
reference does, but nothing verified the rest of the tree. Rebuilding Wine from
the clean kvm04 base is therefore the fix, not a bisect step.

### Measure on the Obsidian intro, not the legal screen

The legal/Bethesda screen reads ~20 on fast **and** slow builds; only the
Obsidian video and in-world discriminate (59.8 vs 19.9). Two of today's
readings were nearly misread because of this.

### A working fast package exists

`~/junk/hybrid-win0166-out/IV0000-GLDS10043_00-GLDS100430000000.pkg` —
today's PS4 runtime over 01.66's Wine, FNV at ~37 in-world. Usable while the
rebuild happens.


### Narrowed to one binary, then two dead ends

A further hybrid (01.66 `win/` with **only** today's `ntdll.prx`) measured
**20.7** on the Obsidian frame against the fast hybrid's 59.9. So the whole
regression is in **`ntdll.prx` alone**; `win32u.prx`, `wineserver.prx`,
`ws2_32.prx`, `xinput1_3.prx` and `wineps5.prx` are clear.

Two hypotheses were then tested and **both failed**:

- **0187** made the `NtWaitForAlertByThreadId` path lock-free (the self-thread
  case needs no `tid_alert_mutex`, so it dropped two `pthread_sigmask` syscalls
  plus a process-wide mutex per wait). Obsidian **20.3** — no change.
- **0188** reverted `sync.c` **wholesale** to the 01.66 version, with no-op
  stubs for `ps5_init/free_thread_alert`. Title art **19.1** — no change.
  **`sync.c`/the 0964 alert-kqueue port is NOT the regression.**

Both hypotheses came from reading code and looking for something expensive.
Both were wrong. The isolation work (hybrids, package surgery) was reliable
every time; the mechanism stories were not. **Revert and measure; explain
only after a build agrees.**

### Remaining candidates inside dlls/ntdll/unix (vs the kvm04 copy)

`process.c` +236, `virtual.c` +144, `server.c` +61, `file.c` +29,
`socket.c` +25, `system.c` +21, `loader.c` +20, `signal_x86_64.c` +19,
`thread.c` +9, `unix_private.h` +9. (`sync.c` +175 is now excluded.)

Suggested route: revert all of them at once to confirm the bisect is sound
(ntdll.prx should then behave exactly like 01.66), then halve the set — about
three cycles rather than ten. Each cycle is ~8-10 min of build, install and
launch.


### Two more dead ends, and a constraint on how to bisect

- **0189** reverted **all eleven** `dlls/ntdll/unix/` files to the kvm04 copy.
  It **crashed** (CE-34878-0) after ~31 s and 1896 exec migrations. Today's
  `relocated_wine_app.prx` and `src/native` glue depend on interfaces that
  01.66's ntdll does not provide, so **a wholesale revert is not a valid
  configuration** and the bisect-in-halves shortcut does not work. The bisect
  has to proceed file by file, or surgically.
- **0190** disabled the one added call in `server.c`,
  `if (reply->type == FD_TYPE_DIR) track_received_directory( handle, fd );`,
  which costs an extra `get_handle_unix_name` server round-trip per received
  directory fd. It **also crashed** (CE-34878-0). `pw_cwd_track()` is
  load-bearing for PS4 path resolution, so that call cannot simply be switched
  off; the hypothesis remains **untested**, not disproved.

**Running tally of tested-and-cleared causes:** per-page exec migration, Wine/
app logging, the translator, patch 1082, and `sync.c` (the whole 0964 port).
**Still unexplained**, and confined to `ntdll.prx`.

### What to try next

1. Revert ONE file at a time, largest first: `process.c` (+236),
   `virtual.c` (+144), then `file.c`/`socket.c`/`system.c`/`loader.c`.
   `server.c` cannot be reverted wholesale (it carries `WINE_PS5_SERVER_FD`),
   and `signal_x86_64.c`/`thread.c`/`unix_private.h` are tied to `sync.c`'s
   0964 interfaces.
2. If a single-file revert also crashes, the file is load-bearing; instead
   diff it and disable individual *added* behaviours that are safe to skip.
3. Cheaper instrumentation than FPS-by-screenshot would pay for itself here:
   a counter of wineserver round-trips per second, printed once a second,
   compared between the fast hybrid and today's build. That would point at the
   hot path directly instead of by elimination.

## The known-good base is already on kvm04

`/srv/nfs4/pvcs/actions-runner-orbis-win-build-cache/deps/abi4/build/wine-ps5/source`
has **zero** `cache_thread_desktop_windows`, so it predates `3647193` — an
01.66-era Wine tree, usable as the clean base without rebuilding from scratch.

## Next

Build from that base, confirm FNV returns to ~30–38, then apply Leo's patches
forward in groups with an FNV framerate check between each. `d9bbb54`
(program launch changes) and the six effect-compiler patches are the remaining
candidates.

**Whatever lands, add a framerate check to the per-candidate smoke test.** A
functional pass would not have caught this.
