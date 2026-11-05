# ABI-v4 upstream sync audit — 2026-11-05

## Verdict

The current GLDS10044 package is internally consistent with the complete
startup-chain stage for the known fixes checked below. We **cannot yet certify
that every historical PS4 Wine and prospero-win patch has been accounted for**
in the upstream sync. The current package manifest proves payload integrity and
the narrow NTDLL overlay; it is not a patch-by-patch source provenance record.

Do not spend a console install/launch on this audit. The remaining work is a
source-side inventory and disposition map.

## What the artifact proves

The final package recorded in the handoff is
`/home/zpeirce/codex_scratch/abi4-upstream-port-20261104/native-sigmask-fix/final/IV0000-GLDS10044_00-GLDS100440000000.pkg`, SHA-256
`5b7bc712d78185608bd235101fc46e0c190606f9056f92feb400d9195df2b757`.
Its manifest records 1,797 preserved stage files; only the two NTDLL PRX
copies changed in the signal-mask overlay. The exact ABI-v4 CPU PE/PRX pair,
relocated app, fonts, and other runtime payloads were retained from the
`native-frame-state` stage. This is a payload integrity check, not proof that
all historical source patches were ported.

## Wine patch series

The fresh Wine build report at
`/home/zpeirce/codex_scratch/abi4-upstream-port-20261104/build/wine-ps5/report.json`
records Wine commit `490f6d5dcbb2a5047345b8af88d114bbcaad69a8` and 146 applied
patches. The matching `source/wine/patches` directory has 151 patches, so the
report omits five:

- `0112-server-skip-the-prefix-ownership-check.patch`
- `0739-ntdll-pass-environment-to-inprocess-server.patch`
- `0740-server-pass-prefix-explicitly.patch`
- `0741-server-log-and-tolerate-ps4-dir-identity.patch`
- `1033-server-log-fatal-protocol-error-to-klog.patch`

The report is dated Nov. 4 and predates later stage work. Inspection of the
Wine source and packaged wineserver confirms those five behaviors are present
in the final startup-chain stage: the PS4 owner check is guarded, environment
and prefix reach the in-process server, PS4 directory identity handling is
present, and the protocol-error klog string is in the packaged wineserver.
`0739` and `0740` are represented by the combined environment/prefix handoff
in the later source. Therefore the five report omissions do **not** establish
that these behaviors are absent from the final package; they establish that
the saved report is not a complete manifest for it.

The original report also contains failed duplicate-symbol links and an
unbuilt `secur32.so` target. It must not be presented as a clean, authoritative
record of the final PS4 runtime build.

## Historical patch archives and prospero-win

The repo currently has 263 files in `src/wine-patches-ps4/` and 146 in
`src/prospero-win-patches-ps4/`. These are accumulated patch records from
multiple ABI generations, including diagnostics, patch-series extensions,
superseded implementations, and fixes later merged into upstream. They are
not all blindly applied to the new ABI-v4 source tree. The runtime Wine build
uses the separate 151-file `source/wine/patches` series; prospero-win is built
from its synced source tree plus the active port layer, not by replaying all
146 archive files as one series.

The current build evidence does not map every archived change to one of:
preserved unchanged, ported to the ABI-v4 source, superseded by a named
replacement/upstream commit, or intentionally excluded. In particular, the
`prospero-win-patches-ps4` archive has no complete reverse-application/source
audit tied to the exact app PRX in this package. So we cannot say “all PS4
patches are included” merely from the successful package build or the 1,797
file stage manifest.

## Required close-out before certifying the sync

1. Freeze the exact Wine source commit, prospero-win source commit, patch
   directory hashes, generated-source inputs, SDK/toolchain versions, and
   package hash for the candidate.
2. Generate a machine-readable list of the exact Wine patch files applied to
   the source tree used for each packaged PRX, including later rebuilds and
   overlays. Confirm each source patch is either applied or behaviorally
   superseded, and explicitly record any intentional omission.
3. For every historical file in both `src/*-patches-ps4/` archives, record a
   disposition and evidence (reverse-applies to current source, matching
   source behavior, upstream commit, replacement patch, or reason excluded).
4. Generate the same provenance for the prospero-win app PRX and its
   no-RELRO relocation stub. Keep payload-hash verification separate from
   patch disposition.
5. Make the build emit this provenance next time, so future syncs do not need
   to reconstruct it from handoff notes and stale reports.

Only after that source audit can we answer “yes” to whether the full port was
carried forward. Hardware testing is not required to close this particular
question.
