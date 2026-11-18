# Handoff: orbis-win builds from source, off the build host

Date: 2026-11-17. Goal: *"make the orbis-win build outside of slacker and to be
done by anyone else from the sources."*

## Result

A package built entirely from source on a Debian 13 laptop — no cache, nothing
from slackian — **passes the parity gate (19 PASS, 0 FAIL)** against GLDS10043
02.59 and **boots on hardware**: it loaded the launcher and ran a game.

    IV0000-GLDS10043_00-GLDS100430000000.pkg
    531,890,176 B   sha256 ef598a8376e190e28ad860d970623c3190d321bad4d6545c6ee6340dd83f89ce
    marker GLDS10043-fromsource-1117

Merged to `main` in both repos (`478b9bc` orbis-win, `2450db7` prospero-win), so
a clone of the default branch can now be built. Recipe:
`docs/BUILDING-FROMSOURCE.md`, written from the run that actually happened.

## Why it never worked elsewhere

**CI never proved it.** `scripts/ci/prepare-runner.sh` assembles from a private
26 GB cache and then runs `sudo ln -sfn "$ROOT" /home/zpeirce/ps4-gladius`. A
green CI run says nothing about building from source anywhere else.

Two defects did most of the damage:

1. **`src/toolchain/prospero-clang` defaulted its root to one absolute path.**
   The shim already had correct walk-up-from-`$0` logic, but only as a fallback
   for when that path lacked the SDK marker — and on that workstation it has
   one. So the walk-up never ran and the build silently linked **another
   checkout's `libwineshim.a`** (measured: 20 duplicate-symbol errors naming it).
   Elsewhere the path simply does not exist.

2. **The `.bss` tail-pad check matched segments by exact `va`.** create-fself
   MOVES the writable segment (measured: 0xf0000 → 0xec000), so nothing matched,
   `end` fell back to 0, the shortfall looked like the whole 6.1 MB segment, and
   ntdll was rejected. Its stub library then never existed and **eleven** later
   modules failed with unrelated "missing library for symbol" errors. Real
   shortfall: 1760 bytes against 11688 of page rounding — no pad needed at all.
   The same bug existed twice, in `prx-ps4.sh` and `bss-tail-pad.py`.

Also fixed: `sync-toolchain.sh`'s hardcoded root; three copies of a "pristine
Wine revision" assertion that rejects a pinned tree; no portable step linking the
SDK's LLVM tools; `MESA_BUILD` requiring a CI-cache-only directory;
`prereqs.sh` missing mingw and nix; and `--wrap=dup` leaving `__real_dup`
unresolved against a shared libc, without which **no relocatable package links**.

## Four inputs lived in one person's scratch directories

None reproducible from any patch series. All now pinned, each a public base plus
a small delta:

| input | base | why the series fails |
|---|---|---|
| wine-ps5 / wine-host | upstream Wine `490f6d5dcb` | 157 present / 112 absent / 40 partial of 310 |
| mesa-ps4 | `orbis-ports/mesa-ps4` `1a59cc147b54` | 35 of 45 apply; the failures include `0041`, which defines `wsi_orbis_cursor_update` |
| orbis-compat | `orbis-ports/orbis-compat` `6922a7b6f` | never pinned at all |

Restore with `scripts/restore-wine-trees.sh` / `restore-mesa-tree.sh`.
**Re-pin after changing any of them. A stale pin lies.**

## 02.59 cannot be reproduced exactly

Established by matching every field of its own manifest, then eliminating causes:

* **Determinism: ruled out.** Two builds of identical input are byte-identical.
* **Embedded build paths: found and fixed.** Wine's `__FILE__` strings put the
  build directory into every module (10 in `ntdll.prx`). `PW_FILE_PREFIX_MAP`
  neutralises it; 0 unmapped paths after.
* **orbis-compat: the blocker.** The public SDK bundle ships 114,252 B defining
  no `orbis_jit_alloc`/`orbis_report`; 02.59 linked 190,196 B that defines them.
  The local copy has since been rebuilt (same symbols, 52 KB larger), so the
  exact archive no longer exists.
* **wow64native:** 02.59 never built it — its manifest hash `20eee436` is the
  carried 01.71 pin.

The parity gate had been reporting this for weeks as *"PS4-specific baseline
strings missing; review each"*. Not cosmetic.

## Traps worth keeping

* **`ftp-put.py` can report a full transfer while writing short.** Measured:
  `sent 531890176 B` + `226 successful`, file on console 506,527,744 B — 25 MB
  short. Re-upload fixed it. **Verify with `ftp-size.py` after every put**; a
  truncated package installs as a corrupt runtime and gets debugged as a code
  defect.
* **`stage_vk_batch.py` is destructive and not atomic.** Run against an
  already-staged tree it edits files and *then* asserts out — it deleted a
  119-line function, which surfaced much later as an unrelated link error.
* **A green build proves nothing.** These scripts assemble from whatever objects
  exist. Verify content (`strings`, `sha256sum`) in `pkg-stage`.

## Open

* **Nobody else has run the recipe.** That is Max's s4 milestone, still a draft.
  The first person to follow `BUILDING-FROMSOURCE.md` should treat it as a
  validation run and fix what they trip over.
* **Game sweep incomplete.** Only the launcher and one title are confirmed. If a
  title misbehaves, the `__real_dup` stub (`-1/EPERM`) is the only change that
  reaches a shipped binary — look at file handles, saves and the wineserver.
* This package carries no `PS4_DEV_CONF`, so it logs nowhere. Repackaging with
  logging is a repackage, not a rebuild.
* `scripts/ci/` still builds from the cache, so CI does not exercise this path.
