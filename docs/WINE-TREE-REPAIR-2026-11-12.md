# Wine source tree repair — in progress (2026-11-12)

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

## Repaired so far

- `server/fd.c` — removed a duplicate plain `realpath_dup`, kept ours with the
  `__PROSPERO__` arm (a directory fd keeps a name when libc cannot canonicalize)
- `dlls/ntdll/unix/virtual.c` — removed duplicate `virtual_host_page_size`, the
  second `get_host_page_unix_prot` (kept OURS, the larger one with the PS4 union
  protection), Leo's intruding subpage-stepping block, and a duplicate
  `virtual_subpage_step_done`

Both compile.

## Still broken (3 files)

1. `dlls/ntdll/unix/signal_x86_64.c` — **one `#endif` missing somewhere in the
   middle**; the trailing `#endif /* __x86_64__ */` is present but gets consumed
   by an inner block, so line 25 reports "unterminated conditional". Leo's `0883`
   (13 hunks) was applied and then reverse-applied here. Its duplicated
   `__PROSPERO__` block was removed by hand first (ours is the one WITH the
   `PW_NATIVE_RESOLVE` diagnostics; his is the plainer one).
2. `dlls/win32u/ps5drv.c` — `PS5_CURSOR_KEEP` undeclared, from `0950` partially
   applying (its enum never landed).
3. `dlls/win32u/vulkan.c` — `ps5drv_vulkan_cursor` conflicting types, from
   `0740` changing the signature in one place only.

For 2 and 3, fully reverting `0740` and `0950` is likely cleaner than hand-fixing;
both are cursor patches and can be re-ported properly later.

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
