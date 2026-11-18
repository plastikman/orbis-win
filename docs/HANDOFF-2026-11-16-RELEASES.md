# Handoff: Orbis-Win 0.0.7 and Playden PS4 0.3.1

Date: 2026-11-16 (America/Anchorage)

## Trees and branches

- Orbis-Win: `/home/zpeirce/git/orbis-win`, remote `plastikman/orbis-win`. Release work is on `codex/orbis-v007` at `9f6619f`, also pushed to `origin/main`. The package was built from the earlier `070990269f98aed139c41cb33ea413f563731bae` checkout recorded in its manifest; the later merge brought in upstream main and release workflow changes. Two untracked Left 4 Dead 2 profile files are present and should be preserved.
- Playden: `/home/zpeirce/git/playden-ps4`, branch `ps4/upstream-ports` at `8abeb7c`, pushed to `origin/main` on `plastikman/playden-ps4`. Its `upstream` remote is `leolobato/playden-ps5`. An existing untracked `build` link should be preserved. The release manifest records submodules `prospero-win` at `df71ecc72a16eaa43b0228bcc1c8096f5378c41f` and `ps5-homebrew-ui` at `0a6fb4b851da86cd4e9512aae3abf1352a96086a`.
- This documentation tree: `/home/zpeirce/ps4-gladius`, branch `launcher-settings`. Wine source and patch porting must follow this tree's `AGENTS.md` and upstream sync playbook.

## How the packages were built

Orbis-Win's manual `audio-candidate` CI job downloaded the published v0.0.6 package, used its tested runtime as the base, replaced the i386 and x64 MMDevAPI DLLs with the patched builds, and repackaged it as console version 02.16. The runtime marker remains `GLDS10043-02.14-pw47f0cef-sampler0`. [Run 43739492366](https://github.com/plastikman/orbis-win/actions/runs/43739492366) passed the package parity hard gates and package validation. The release includes the manifest, parity report, and validation report. The user's game sweep of the candidate was reported as good before publication.

Playden's manual package workflow on `main` used `version=02.90`, `orbis_win_tag=v0.0.7`, and `publish_release=true`. It verified and extracted the published Orbis-Win package, prepared the pinned DXVK 2.6.2 and PS4 network dependencies, built `PLDN10001`, and published the installer and build manifest. Its manifest identifies Playden commit `8abeb7ced1aea4bf4a94847c3e602c54ecc445a2` and the Orbis-Win package hash above. The successful workflow then removed the old release.

## Fixes and behavior

The Orbis-Win MMDevAPI fix stops persisted audio endpoint names accumulating repeated labels on reload. Playden hides local game import unless `import-games` is present in its `features.txt`. Game test reporting is disabled by default and requires an explicit `game-test-reports=https://...` endpoint, avoiding the previous default report destination. The release also carries the earlier PS4 upstream ports and Steam Online work; the release notes retain the experimental status of internet play.

## Completed

- Published [Orbis-Win v0.0.7](https://github.com/plastikman/orbis-win/releases/tag/v0.0.7). It is a package based on the tested v0.0.6 / Orbis-Win 02.14 runtime, with the updated 32-bit and 64-bit MMDevAPI audio endpoint-name fix. The release package is `IV0000-GLDS10043_00-GLDS100430000000.pkg`, SHA-256 `769b5d3d82ddff8c84cfdcdf3095c43e48c848f28fa4f2e3266f09983bfeb1f8`. The package was uploaded to the console at `/data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg`; FTP confirmed 508,493,824 bytes.
- Published [Playden PS4 v0.3.1](https://github.com/plastikman/playden-ps4/releases/tag/ps4-v0.3.1), package version 02.90. Its installer is `IV0000-PLDN10001_00-PLDN100010000000.pkg`, SHA-256 `09721146aeaa834d64d17a2c8dd233152e287d4a4c20655f79e96e2cc7197bde` (1,003,683,840 bytes).
- Removed the Playden PS4 `ps4-v0.3.0` GitHub release and tag after v0.3.1 was published. The v0.3.0 release lookup returned “release not found.”
- Playden release notes describe explicit opt-in reporting (`game-test-reports=<endpoint>` in `/data/PLDN10001/features.txt`), the `import-games` feature flag, the Orbis-Win v0.0.7 runtime, and experimental Steam Online features. Internet peer-to-peer play remains unvalidated on-console.
- The Playden release workflow completed successfully: [run 43762506793](https://github.com/plastikman/playden-ps4/actions/runs/43762506793).

## CI and provenance fixes made during release

The Playden CI first rejected the v0.0.7 candidate manifest because it lacked the provenance fields CI expected. The v0.0.6 manifest established the carried runtime as `runtime_source_commit=47f0cefb4e5c39aad0e60e7a3ba1dfcc50376adf`; this was added to the v0.0.7 release manifest. Playden CI verifies the candidate package hash, checks that the v0.0.6 base-package and both MMDevAPI SHA fields are valid, and permits the runtime-source metadata only for the expected 02.14 marker and exact source commit.

The next build found that `Simulation::SetGameTestReportsEnabled(bool)` was implemented but its header declaration had been displaced by the import-games change. The declaration was restored, and the full release build then succeeded.

Playden `main` contains these release-time commits (pushed):

- `6fb8777` — make game reports require an explicit endpoint
- `2529010` — prepare the Playden PS4 0.3.1 release
- `70a0b3c` — remove 0.3.0 after publishing 0.3.1
- `60d7e71` — accept v0.0.7 audio candidate provenance
- `070c3b7` — accept the verified v0.0.7 candidate runtime provenance
- `8abeb7c` — restore game-report toggle declaration

The Orbis-Win release used the tested-stage repackage path because rebuilding from the current ABI-v4 source/cache failed compilation. The v0.0.7 candidate preserved the v0.0.6 runtime and replaced the two MMDevAPI DLLs. Candidate package provenance includes the baseline package hash, updated DLL hashes, runtime marker, source commit, and CI run. See the Orbis-Win release manifest and validation assets for the complete details.

## Remaining

- Install and test the Playden PS4 0.3.1 package on-console. The Orbis-Win 0.0.7 package was uploaded to the console, but this handoff does not record a post-release install or test of Playden 0.3.1.
- Confirm the audio endpoint-name fix in a game that reproduces the audio issue.
- Keep the Orbis-Win source-build/cache compile failure visible for follow-up; v0.0.7 came from the known-tested v0.0.6 runtime plus the scoped MMDevAPI update, not a fresh full runtime build.
- Preserve the Playden package hash and exact release manifest alongside any console test results.

## Workspace notes

The release work was carried out in `/home/zpeirce/git/orbis-win` and `/home/zpeirce/git/playden-ps4`; this checkout is `/home/zpeirce/ps4-gladius`. On this checkout, branch `launcher-settings` was clean except for the existing untracked `worktrees/` directory when this handoff was written. Do not clean that directory without inspecting it.
