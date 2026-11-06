# Handoff — 2026-11-06: alpha.6 candidate waiting for its hardware run

**State:** GLDS10043 **01.38** is built and uploaded to the console's `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg` (readback hash matched). Zak will install it and run the titles later.

- Package `codex_scratch/release-0138/app/IV0000-GLDS10043_00-GLDS100430000000.pkg`, sha256 `cdd5723bb7b58471b6c051def4c09dc132a77fae1f9dab3480c81b4d25702464`.
- Built release-style: no `dev.conf` inside (`app_log=none`). This exact file is the alpha.6 package if it passes.
- Provenance:
  - `root_commit=9749fcd` (orbis-win `main`);
  - `prospero_win_abi4_commit=108194e` (fork `main`), empty diff.
- Gates: parity 0 FAIL (WARN: no `dev.conf`, expected); `pkg_validate` all OK.

**What 01.38 adds over alpha.5 (01.35):**
- `[input] mouse = touchpad`: the touchpad as a trackpad-style pointer. Smoothed; the default speed is 400 when the profile sets no `mouse_speed`.
- The log switch: a package without `/app0/dev.conf` logs when `/data/prospero-win/dev.conf` exists. ⚠ It exists on the console now, so every launch logs until it is deleted.
- Half-Life 2 (`src/profiles/half-life-2.profile`): Options opens the pause menu, the touchpad is the mouse, `mouse_speed = 400`.

**Test plan:** nine titles. Load each and quit to the launcher; Bloodlines' quit hang is known.
- GTA IV, FNV, FO3, Oblivion (native);
- MDK (translator);
- Half-Life (Zink), Bloodlines, Titan Quest, Half-Life 2.
- In Half-Life 2 also check that the touchpad no longer darts.

**If all pass:**
1. Publish `v0.0.1-alpha.6` from `codex_scratch/release-0138/`, the same way as alpha.5: `gh release create … --prerelease --target 9749fcd`, attaching the `.pkg`, `BUILD-MANIFEST.txt` and `parity.txt` (alpha.5 uploaded them renamed with the version, e.g. `BUILD-MANIFEST-01.35.txt`). Use alpha.5's notes plus a section for these three additions.
2. Cancel the tag's workflow run; it fails at the version step.
3. Promote the 01.38 stage as the baseline (`pkgout/abi4-0138-baseline`, repoint `pkgout/baseline`).

**Still open:**
- CI cache re-sync: `scripts/ci/sync-cache.sh --abi4-only`, before the next CI build.
- Titan Quest: the descriptor ceiling (~512 by number vs RLIMIT 1443) and the controller layout.
- Bloodlines' quit hang.
- The translator crash in Titan Quest.
- A controller pass for Half-Life (`goldsrc`).

## Update: published without the full run (Zak: "publish to GH")

- **`v0.0.1-alpha.6` is published**: https://github.com/plastikman/orbis-win/releases/tag/v0.0.1-alpha.6 (pre-release, tag at `9749fcd`).
  - Assets: the 01.38 `.pkg` (501,219,328 B, sha256 `cdd5723b…`), `BUILD-MANIFEST-01.38.txt`, `parity-01.38.txt`.
  - The tag's workflow run 42265536858 was cancelled.
- The release notes say plainly that this package has **not** had the nine-title run. Each title's last result and build are listed: Half-Life 2 on 01.37, the rest on 01.34.
- **The baseline stays 01.34** until 01.38 passes the nine titles. Then promote `pkgout/abi4-0138-baseline` as planned above.
