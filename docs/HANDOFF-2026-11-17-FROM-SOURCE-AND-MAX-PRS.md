# Handoff — 2026-11-17: the from-source build, Max's PRs, and what is still open

`main` is at **435d79e**. Nothing is released
or tagged. The console has `-vkbun` installed; the base package `native-1117` was
installed later for a control test, so **check the tile before trusting a run**.

---

## 1. The headline: the build works from source, with no borrowed binaries

Package `-vkbun`, every one of the 14 PRX modules built from source here:

| check | result |
|---|---|
| Fallout: New Vegas | native, 1920x1080, **59.8 fps**, `audible=29411` |
| Half-Life 2 | native, **59.9 fps**, `vk_shown=1224` |
| libvulkan faults | **0** |
| parity gate | exit 0, 18 PASS / 0 FAIL |
| borrowed binaries | **none** (`libvulkan.prx` = `268fdd06`, built here) |

Only `libc.prx` and `libSceFios2.prx` are not built — console modules, never
redistributed, by design.

### 1b. The CI-built binaries were installed and run on hardware

Not just "CI went green". The `prx-modules` artifact from run 44234732286 was
downloaded, packaged here, gated and installed as `-cibuild.pkg`:

    19:29:39  profile=fallout-new-vegas  cpu=native backend=wow64native.dll
              libvulkan faults = 0
              did-not-start    = 0   <- native WoW64 started; no c00000bb
              simulate entry   = 0   <- the translator never loaded
              frames_put=3  last=1920x1080  audible=8624   screenshot: 59.9 fps

Gate on that package: exit 0, 0 FAIL.

**8 of the 14 modules are byte-identical** between the GitHub runner and this
workstation, `libvulkan.prx` (268fdd06) among them. The 6 that differ are exactly
the Wine-side PRXs (ntdll, win32u, ws2_32, wineserver, opengl32, wineps5), because
the local tree carries Max's 1086/1087 and CI builds the pinned tree without them.
That is the expected difference, not drift.

⚠ CI uploads only `*.prx`, not the matching `*.shared.elf`, so the parity gate's
export check is skipped on a CI-built stage ("--elf-dir PRX does not match the
stage"). Worth adding to the artifact.

## 2. Root cause of the libvulkan fault: orbis-compat is PER MODULE

    libvulkan.prx (RADV)  ->  the SDK BUNDLE's orbis-compat (114,252 B)
    every other PRX       ->  the PIN (190,196 B, src/orbis-compat-pin)

and each module must be internally consistent: the headers it compiles against
and the archive it links must be the same orbis-compat.

The pin's `include/signal.h` delta (`SIG_UNBLOCK=2`) is what makes native WoW64
work; without it libkernel reads Linux's 1 as `SIG_BLOCK`, Wine's native-frame
probe blocks the signal it is about to send itself, `wow64native` returns
`STATUS_NOT_SUPPORTED` (`c00000bb`), and Wine drops to the `wowprospero`
translator **with nothing in the log that looks like an error**. RADV does not
care about the signal ABI and faults against the pin.

Measured, one variable changed, Fallout: New Vegas:
  * pin    -> `0xc0000005 at libvulkan.so+0x16a6dba`, `frames_put=0`, spinner
  * bundle -> 0 faults, 1920x1080, 59.8 fps

⚠ The parity gate passes the broken combination 19 PASS / 0 FAIL. The gate is no
defence here. `prospero-clang` now refuses a wrong orbis-compat loudly instead.

⚠ `PW_ORBIS_COMPAT` steers the EXECUTABLE link and the toolchain guard. The PRX
link reads the STAGED archive, `build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a`.
They are different things; this cost several hours.

**Three hypotheses were tested and refuted — do not re-suspect them:**
1. "The thread-stack interposer is missing." It is in both good and bad binaries.
2. "The pin breaks RADV generally." 02.59 links the pin and works — but it was
   built from an OLDER Mesa, so that comparison moves two variables. Hold Mesa
   constant before concluding.
3. "A Mesa patch is missing / the glue differs." Mesa sources are identical
   (`diff -rq` clean); `libwineshim.a` is not even linked into `libvulkan.prx`
   (`radv-prx-ps4.sh` sets `PW_PRX_LINK=1`) — splicing a different glue object
   produced a byte-identical PRX.

## 3. Max's PRs: all merged, all closed with comments

| PR | state | tested |
|---|---|---|
| #15–#20 | on main | carried in via `reconcile/max-prs` |
| #10 ntdll volume size (1086) | on main | **hardware**: `PW_DISK_FREE` in `ntdll.prx`, FNV + Oblivion clean |
| #11 MapVirtualKeyEx (1087) | on main | built; **marker never fired** — no profile asks for scan codes >0xff |
| #12 parity gate baseline | on main | **used** for all three packages today, 18/0 |
| #13 flip rate | on main as `0045`/`0046` | **compile only** |
| #14 radv.log cost | on main as **`0047`/`0048`** | **compile only** |

#13 and #14 both claimed `0045` and `0046`; the series ended at `0044`. #13 kept
the lower pair by PR order. Four comments *inside* the 0048 patch said "Mesa patch
0046" and were corrected — they compile into the shipped Mesa source.

⚠ **`src/wine-patches-ps4/` and `src/mesa-patches-ps4/` are ARCHIVES, not build
inputs.** The trees come from the pins in `src/wine-trees/` and `src/mesa-trees/`.
So main *records* 1086/1087 and 0045–0048, but a build will not include them until
the pinned bundles are regenerated. 1086/1087 are built in the local Wine tree
branch `port/max-1086-1087` (not pushed — that tree's remote is winehq upstream).

## 4. Titan Quest — PARKED, and NOT a from-source regression

Control test: the non-from-source base package crashes it **identically**.

    from-source (vkbun)   eip=78023887 ebx=00000000 edx=5b3d736e
    base (native-1117)    eip=78023887 ebx=00000000 edx=5b3d736e

A virtual call on a NULL `this` (`mov eax,[ebx]; push ecx; call [eax+disp]`),
~10 s in, deterministic. Inherited, not caused.

It IS still a regression against 01.34 / 01.41 / 01.58 (the 11-title run on
2026-11-09 included TQ). **Bisect window: 2026-11-09 → 2026-11-17.** Cheapest
next step: install a 01.58-era package and confirm TQ still reaches gameplay, so
the "worked" end rests on a run rather than on the handoff record.
Full evidence: `/home/zpeirce/junk/tq-regression-20261117/README.md`.

## 5. The suite, on the from-source lineage

12 of 12 launched; 11 pass. 10 native on `wow64native.dll`; MDK correctly on
`wowprospero.dll` with 255 `BTCpuSimulate simulate entry` markers — the same build
selects either backend correctly, which is the negative control the signal fix
needed. Hollow Knight / Binding of Isaac / Risk of Rain 2 are the three 64-bit
titles and are expected to fail on the external-memory gap (PR #21's patch 1080
is half that fix; the DXVK allocator refusal is the other half, still open).

## 6. OPEN — what the next session should pick up

1. ~~`ci/orbis-compat-pin`~~ **MERGED (435d79e), and the clean-machine run is GREEN.**
   It fixed two real defects that only a run on a clean machine could find:
   * CI had **no orbis-compat step at all**, so every PRX linked the bundle's copy,
     `ntdll` included — i.e. CI was building packages in which native WoW64 never
     starts, and the gate passed them.
   * Merging PR #17 put `link-llvm-ps4.sh` inside `prepare-ps4-toolchain.sh`; it
     requires LLVM 19 and the workflow installed Ubuntu's unversioned clang, so the
     first run on main after that merge failed (44234091715, "no LLVM 19 found").
     Now installs 19.1.7 from apt.llvm.org like `build-ps4-package.yml` does.
   **TWO green runs, not one:** 44234732286 (the branch) and **44236959940 (on
   `main`, after the merge)** — both `completed/success` on `ubuntu-latest`, from a
   fresh checkout, fetching the public SDK bundle. All 14 PRX modules built, and the
   toolchain recorded linking the PIN it built on the runner, not the bundle:
   `orbis-compat: /home/runner/work/orbis-win/orbis-win/orbis-compat (e69c24fedfc4432c)`.
   **This is the "someone else can build it" demonstration.** The earlier run on
   main (44234091715) failed at "Toolchain support archives" with "no LLVM 19
   found"; that was caused by merging PR #17 and is fixed.
2. **#13/#14 on hardware.** Both default off; the flip-rate and radv.log claims are
   unmeasured here.
3. **Regenerate the pinned trees** so 1086/1087 and 0045–0048 are build inputs
   rather than archive.
4. **Titan Quest bisect** (§4).
5. **The 64-bit three**: patch 1080 + the `pe64` default for
   `PW_PS4_EXEC_MIGRATE_RANGE_MAX`, then the DXVK allocator refusal.
6. Console profiles are still quieted to `winedebug = -all,err+all,+fps`; originals
   in `/home/zpeirce/junk/runlogs/profiles-backup-20261117/`. A wedge trace wants
   channels chosen deliberately (`+tid,+sync,+server`), not `+seh` wholesale — that
   is what produced the 2.7 MB/s flood.
7. `src/profiles/oblivion-gog.profile` and others on the console were rewritten;
   restore before judging performance.

## 7. Evidence kept

    /home/zpeirce/junk/libvulkan-diagnosis-20261117/README.md   the full fault chase
    /home/zpeirce/junk/tq-regression-20261117/README.md         TQ + control + window
    /home/zpeirce/junk/orbis-fromsource/                        the build tree and logs
    /home/zpeirce/junk/max-prs-20261117/                        Max's PRs worktree
