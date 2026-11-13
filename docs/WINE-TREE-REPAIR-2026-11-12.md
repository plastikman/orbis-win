# Wine source tree repair — complete (2026-11-12)

## What happened

Porting Leo's patches, I ran `git apply --reject` across 26 conflicting patches
**as a batch**, which half-applied many of them, then tried to undo it with a
reverse pass. Partial apply/reverse is not reversible: each pass moved the tree
between "duplicated code" and "stripped code" rather than back.

**Do it one patch at a time, compiling between each**, as the successful `0964`
port did. Snapshot the tree before any batch.

## The tree

`worktrees/playden-ps4-0170/.deps/wine-ps5/source` and
`codex_scratch/abi4-upstream-port-20261104/build/wine-ps5/source` are the SAME
files (same inodes). There is no other copy of this state:

- `prospero-win/.deps/wine-ps5/source` — different (2026-11-04) version
- `kvm04:/srv/nfs4/pvcs/actions-runner-orbis-win-build-cache/deps/abi4/...` and
  `slackian` — both hold an older valid state (`server/thread.c` 2594 lines, no
  `dlls/winebus.sys/bus_ps5.c`)

`git` cannot restore it: `.git/objects/info/alternates` pointed at
`codex_scratch/prospero-win-v0.2.0-port-build/...` which no longer exists, so
HEAD's objects are gone. (I emptied that file; the backup is
`/tmp/claude-1000/alternates.bak`. That breakage predates this session.)

## Repaired — complete

All five damaged files compile, and none is missing a definition the
pre-damage reference has. Every file is now larger than the reference, i.e.
forward progress with no net deletion.

- `server/fd.c` — removed a duplicate plain `realpath_dup`, kept ours with the
  `__PROSPERO__` arm (a directory fd keeps a name when libc cannot canonicalize)
- `dlls/ntdll/unix/virtual.c` — removed duplicate `virtual_host_page_size`, the
  second `get_host_page_unix_prot` (kept OURS, with the PS4 union protection),
  Leo's intruding subpage-stepping block, and a duplicate
  `virtual_subpage_step_done`; **restored `virtual_handle_fault`**, see below
- `dlls/ntdll/unix/signal_x86_64.c` — removed Leo's duplicate `__PROSPERO__`
  block (kept ours, with the `PW_NATIVE_RESOLVE`/`ERR_(seh)` diagnostics),
  reverse-applied `0883`, restored the missing `#endif`, and **re-added the
  `FSBASE_sig` macro** that the reverse of `0883` had taken with it
- `dlls/win32u/vulkan.c` and `dlls/win32u/ps5drv.c` — reverted `0740`/`0950`/
  `0995`; **restored our cursor region**, see below

## What compiling did NOT catch

Two losses survived a clean compile of every object. Both were found only by
diffing against the pre-damage copy in the kvm04 CI cache
(`/srv/nfs4/pvcs/actions-runner-orbis-win-build-cache/deps/abi4/build/wine-ps5/source`).

1. **`virtual_handle_fault` had been deleted outright** from `virtual.c` — 159
   lines, the page-fault handler. It is not `static`, so deleting the
   definition breaks only the *link*, and we had compiled objects without ever
   linking. `virtual.c` was the one file *shorter* than the reference (-11
   lines); that shrink was the tell.
2. **`ps5drv.c` kept Leo's `ps5drv_vulkan_cursor` and deleted ours**, taking
   `visible_box()` and the `cursor_box = box` assignment with it. `cursor_box`
   stayed declared and read in `draw_cursor`, so the edge clamp silently read
   an all-zero rect — patch `0440` (keep the cursor whole at the frame edge),
   which the content audit flagged at 0.25. No warning, no error, wrong
   behaviour. Our side is restored, which also brings back the `PW_VK_CURSOR`
   diagnostics; Leo's duplicate is gone.

And the link would not have caught it either: the PRX links as a shared
object and tolerates undefined symbols — `nm -u ntdll.shared.elf` counts 250.
A missing `virtual_handle_fault` would have become a *runtime* failure in the
page-fault path, not a build error.

**The lesson: "it compiles" is not a repair check.** Compare definitions
against a known-good copy, and link before believing a tree. A file that got
*shorter* deserves immediate suspicion.

## The tree now has working git again

The old `.git` was unusable (`objects/info/alternates` pointed at a deleted
path, so HEAD `490f6d5` had no objects). It is kept as `.git.broken-20261112`.
A fresh repo was initialised on 2026-11-12:

- `39fe076` on `baseline-repaired-20261112` — the hand-repaired state
- `aec1166` on `repair/restore-virtual-handle-fault` — the two restorations

**Standing rule (Zak, 2026-11-12): port patches only on a branch, one at a
time, compiling between each.** Recorded in `AGENTS.md`. Never
`git apply --reject` across a batch.

## Not affected

Every package built and uploaded, including **01.82 on the console**. Both git
repos. `prx/ntdll.shared.elf` was linked at 09:50, before the damage at ~10:05.

## Patches genuinely applied and intact

`0964` (verified: turned the Hollow Knight hang into a clean exit), 25 clean +
5 fuzzy + 9 that applied with zero rejects. `1010` needs companion files
(`pw_title_notify.{h,c}`) and was reverted. 7 were deliberately skipped as
PS4-inapplicable (GStreamer x3, subpage stepping x3, 120 Hz).

Ten PE-side objects (`wow64win`, `msvcp90`, `kernelbase`, `ntoskrnl`, `winebus`,
`setupapi`, `rtworkq`, `ntdll/loader`, `wow64`) still need the host/mingw tree.
