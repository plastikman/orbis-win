# Project handoff — work from Nov. 4–5, 2026

This is the cross-project handoff for the last 24 hours. It is an index and
status summary, not a replacement for the detailed run records linked below.
It covers the ABI-v4 upstream-sync effort, package/runtime parity, native
WoW64 startup, relocation, memory work, and the latest multi-title checks. GTA
IV is only the final focused experiment in that larger effort.

## Current state in one page

- **Known-good control:** GLDS10044 package 1090 remains the reference. Its
  earlier PS4 validation reached gameplay in Oblivion, Fallout: New Vegas, and
  Fallout 3; the project history also has a working GTA IV setup. Do not
  overwrite or use it as the ABI-v4 candidate.
- **ABI-v4 candidate:** GLDS10043 is installed as APP_VER 01.02,
  `Orbis Wine ABI-v4 Vulkan Boundary`:
  `IV0000-GLDS10043_00-GLDS100430000000.pkg`, SHA-256
  `3f06c55e2034471383a4c22bb8bcdf64cf56f6f334f964201c5842eda3335eb9`.
  This candidate was made from the preserved ABI-v4 stage, changing the x86
  WineVulkan PE DLL and package metadata for its boundary trace.
- **Latest captured launch:** The 11:53 GTA IV run requested native CPU mode;
  the log confirms `wow64native.dll` initialized. It then exited back to the
  launcher at DXVK/WineVulkan `vkCreateInstance`, with no frame, device-create,
  present, or `PW_EXCEPTION32` fault record. This is a clean Wine exit at the
  same startup boundary, not a guest crash and not a gameplay pass.
- **GTA IV profile:** `gtaiv-test` was corrected in place to `cpu = native`;
  it retains focused D3D/Vulkan logging and `DXVK_LOG_LEVEL=debug`. FTP
  readback SHA-256 is
  `674b65646b7407561abfe2c350c52f7dd143e0e626805a8e29cc4ff97e41e6a8`.
- **Prefix WineVulkan files:** The two ABI-v4 WineVulkan DLLs temporarily
  copied into the shared GTA IV prefix were restored to their saved ABI3
  versions and verified by readback. The mixed-prefix experiment did not
  establish a cause or a fix.
- **Do not certify the upstream sync yet.** The package manifest and the
  startup-chain audit establish payload integrity for the tested stage, but
  the disposition of every historical PS4 patch—especially the prospero-win
  app/relocation layer—has not been mapped to the exact ABI-v4 source and
  packaged PRXs. The source-side audit is still required.

## Work completed and established findings

### ABI-v4 startup and package parity

The Nov. 4 sync initially missed already-known PS4 changes. The source audit
found missing behaviors for descriptor reopening/mapping (`0734`/`0735`),
thread nonblocking setup (`0742`), null environment handling (`0743`),
host-page shared-data mapping (`0744`), fd ownership (`0745`), copied-prefix
boot handling (`0746`), auxv handling (`0747`), and bounded wake-pipe draining
(`0771`). The prefix-owner fix (`0112`) was also missing. These were restored
in a consolidated candidate rather than treated as new bugs. The detailed
history explains early failed candidates and corrections; its older “next
test” instructions are superseded by this handoff and the current stop gate.

One early packaged stage omitted ABI-v4 runtime files even though packaging
completed: duplicate `libvulkan.prx`, `libfreetype.prx`, `wineps5.prx` copies,
and x86_64 Windows `cpu.o`. They were restored. The package builder can also
default to ABI-v3 and can rebuild unrelated PRXs or omit `cpu.o`; a successful
build command is not evidence of a complete package. The current playbook now
requires ABI lockstep and a complete manifest comparison.

The `PW_NATIVE_FRAME` self-test had a concrete ABI mismatch. PS4 kernel signal
mask operations use FreeBSD values (`SIG_BLOCK=1`, `SIG_UNBLOCK=2`,
`SIG_SETMASK=3`), while the SDK header exposed Linux values. The probe passed
`1` intending to unblock SIGWINCH, but it blocked it: `old_blocked=0`,
`now_blocked=1`, `pending=1`, `hits=0`. The compatibility shim and tracked
patch 0002 were corrected; the rebuilt signal object uses `2` for unblock and
`3` for set-mask. The latest 11:53 native GTA IV launch confirms the native
provider can initialize on this candidate (`wow64native.dll` loaded and
initialized), though the rest of that game launch still exits during Vulkan
startup.

Relocation is another independent gate. The no-RELRO EBOOT layout from package
1090 remains the required default, and patch 0204 makes the eboot-release call
mandatory. Some ABI-v4 runs lacked the runtime release marker and reported
mapping conflicts at `0x400000`; other captures did show release success.
Because the relevant app build marker/release marker were absent in some runs,
those particular logs cannot establish which app PRX was active. Do not infer
relocation success from the EBOOT being present in a package.

### Memory and RELRO work retained from the baseline

Package 1090 removed the kernel re-protection hazard by using a no-RELRO stub
EBOOT: the PS4 loader had been reapplying module 0's `PT_SCE_RELRO` protection
to released ranges after later module loads. Its RW stub data is at
`0x7fff0000`, code is released, and no `PT_SCE_RELRO` remains. Hardware testing
recorded successful gameplay checks in Oblivion, FNV, and FO3. The no-RELRO
layout and relocation fix must be preserved in every candidate.

Memory work in the current repository includes the Wine PS5 memory-budget
accounting and a direct-memory-backed wineserver heap (commit `22daad7`,
preceded by `bcb8fda`). These changes are additive baseline work; this Nov. 4–5
ABI-v4 startup sequence has not isolated them as the cause of the launcher
returns. Do not revert them based on the present evidence. The detailed FNV
history and package 1090 validation are in
[`HANDOFF-2026-11-02.md`](HANDOFF-2026-11-02.md).

### Per-title observations from the ABI-v4 follow-up

- **Oblivion:** Some launches returned before the game because the native
  provider fell back to `wowprospero.dll`; some also had low-address mapping
  conflicts. Later captures showed the signal-mask correction can initialize
  native WoW64. The app identity/relocation markers were absent in certain
  captures, so those cannot attribute the relocation outcome to the latest
  app PRX.
- **Fallout: New Vegas:** Earlier ABI-v4 runs requested native but fell back to
  the translator because the SIGWINCH self-test failed. Other early runs also
  exposed the incomplete package stage. These are startup/package failures,
  not evidence that the previously working game regression is caused by its
  gameplay/DXVK path. Do not repeat translator tests; the logs already prove
  translator execution when it happened.
- **Fallout 3:** The recent ABI-v4 startup runs did not establish a new FO3
  gameplay result. The 1090 baseline remains the last documented successful
  control.
- **MDK:** Its repeated candidate runs fell back to the translator and then
  failed DXVK Vulkan 1.1 instance creation. Keep this separate from native
  signal startup and the general ABI-v4 sync question.
- **GTA IV:** See the focused trace below. The ABI3 control package and
  GLDS10043 candidate were not initially compared in the same CPU mode; the
  profile was translator until corrected. The final run is native but still
  exits before device creation.

### Latest GTA IV trace, including the final run

The chronological, per-run account and package provenance are in
[`HANDOFF-2026-11-05.md`](HANDOFF-2026-11-05.md), with the raw analysis in
`/home/zpeirce/codex_scratch/gta4-ps4/GTAIV-run-20261105/run-summary.md`.

Key findings:

1. GLDS10043 launched GTA IV under the translator several times and returned
   cleanly around WineVulkan's instance setup. Those runs cannot answer the
   native comparison. The profile was then set to native without changing its
   other settings.
2. The user also tried the older ABI3 baseline with ABI-v4 WineVulkan DLLs
   copied into the prefix. That native run loaded the game and reached
   repeated Vulkan acquire/submit/present calls, but the capture stopped while
   the process was still active (`frames_put=7`, `shown=0`); it is neither a
   confirmed success nor a confirmed launcher return. The test mixed ABI
   components and is not a valid controlled comparison.
3. The shared GTA prefix was restored to the saved ABI3 WineVulkan DLLs and
   readback hashes matched. No causal claim follows from the mixed-prefix
   test.
4. The final 11:53 launch requested native; the log confirms
   `wow64native.dll` loaded and initialized, then shows host Vulkan instance
   setup and the DXVK client `vkCreateInstance` request. Wine returned to the
   launcher (`session_end reason=wine-exit`) before the instrumented
   post-call marker, physical-device result, device creation, or first frame.
   There is no `PW_EXCEPTION32` record. This bounds the current GTA failure to
   the Vulkan instance boundary but does not tell whether the PE-to-Unix
   call, transport, or subsequent init exit is responsible.

The active console log is
`/home/zpeirce/codex_scratch/fallout3-flex-map-trace-1102/build-ps4-logs/ps5log-20261104-065340.log`.
Its filename predates these runs; the 11:53 timestamps and profile lines
identify the latest session. The corresponding profile snapshots, prefix DLL
backups/readbacks, and watcher output are under
`/home/zpeirce/codex_scratch/gta4-ps4/GTAIV-run-20261105/`.

## Build and source state at handoff

- Current branch/HEAD: `ps4/no-relro-eboot-1090`, commit
  `22daad7 back wineserver heap with PS4 direct memory`.
- Known-good package 1090 is the safe control. GLDS10043 is the ABI-v4
  investigation candidate; do not promote it or replace GLDS10044 from these
  results.
- Latest installed candidate filename:
  `IV0000-GLDS10043_00-GLDS100430000000.pkg`.
- The upstream sync audit is not closed. `docs/UPSTREAM-SYNC-AUDIT-2026-11-05.md`
  lists exactly what is and is not proven; `docs/UPSTREAM-SYNC-PLAYBOOK.md`
  captures the local gates and known packaging pitfalls.
- The working tree has pre-existing modifications plus untracked work. At
  handoff, modified tracked files are:
  `docs/HANDOFF-2026-10-26.md`, `docs/HANDOFF-2026-11-02.md`,
  `src/falloutnv-config/dxvk.conf`, `src/profiles/mdk-windows.profile`, and
  `src/wine-platform-patches-ps4/0002-orbis-compat-use-freebsd-signal-numbers.patch`.
  Untracked files include the Nov. 3–5 handoffs, sync audit/playbook, patches
  0204/0205, and Wine patches 1029/1030/1031/1034/1035. Review ownership and
  provenance before committing; do not assume the untracked patch files were
  all included in any package.
- Existing app logging was active through TCP 9300. Do not stop the listeners
  unless Zak asks.

## Next owner: review before any more console cycle

1. Read this overview, the full
   [`HANDOFF-2026-11-04.md`](HANDOFF-2026-11-04.md),
   [`HANDOFF-2026-11-05.md`](HANDOFF-2026-11-05.md), the upstream audit, and
   the playbook. Historical per-section “next test” text is superseded by the
   latest sections and by this handoff.
2. Do source-side provenance work first: map every archived Wine and
   prospero-win PS4 patch and non-patch customization to the exact ABI-v4
   source/build inputs and packaged PRXs. The current audit explicitly says
   this is unfinished.
3. Preserve 1090 and all known fixes. Do not issue a new package or ask for a
   launch until a local comparison identifies one specific unresolved
   question and the candidate passes the full payload/ABI/relocation gates.
4. For any later GTA IV diagnosis, use the final 11:53 native trace as the
   latest evidence; don't repeat the translator run or the mixed ABI prefix
   experiment. A further run should only follow from a specific source-side
   finding and have package identity, app marker, relocation result, and
   native initialization captured before evaluating the Vulkan boundary.

## Detailed records

- ABI-v4 sync/startup chain and hardware captures:
  [`HANDOFF-2026-11-04.md`](HANDOFF-2026-11-04.md)
- Nov. 5 package identities and GTA IV trace:
  [`HANDOFF-2026-11-05.md`](HANDOFF-2026-11-05.md)
- Historical FNV memory and 1090/1091 work:
  [`HANDOFF-2026-11-02.md`](HANDOFF-2026-11-02.md)
- Sync completeness verdict:
  [`UPSTREAM-SYNC-AUDIT-2026-11-05.md`](UPSTREAM-SYNC-AUDIT-2026-11-05.md)
- Repeatable sync/package/test gates:
  [`UPSTREAM-SYNC-PLAYBOOK.md`](UPSTREAM-SYNC-PLAYBOOK.md)
