# Splinter Cell Conviction: Orbis-Win 02.59 to 02.62

This change records the PS4-side source work used to move the Splinter Cell
Conviction investigation from the known-good 02.59 package to diagnostic
builds 02.61 and 02.62.

## Build sequence

- **02.59** is the baseline. Its manifest pins the Orbis-Win root at
  `c1579c0d775ea248168745bf41bd7081cff522c4` and the prospero-win ABI-v4
  source at `5d1cb4f7537a37e1bde29b88e3d0704f239e020f`.
- **02.61** inherited the 02.59 application payload and added filtered
  instrumentation for the `orbit_osi_pipe` named pipe. The exact Wine source
  change is archived as `src/wine-patches-ps4/1082-...patch`. It was built
  with package parity and `pkg_validate` passing.
- **02.62** added resolution from the active prefix's
  `drive_c/windows/system32/drivers/etc/hosts` before calling the SCE
  resolver. The source patch is archived as
  `src/prospero-win-patches-ps4/0138-...patch`. This allows a title-local
  hosts entry to redirect retired Ubisoft services without changing the
  console's DNS configuration.

## Result and limits

The 02.62 run reached the game's cutscene and then crashed in 32-bit Wine's
`RtlWakeAddressAll` path. The prefix hosts mapping was observed resolving the
configured Ubisoft endpoint to `127.0.0.1`; that confirms the resolver change
was active, but does not show that the game can reach gameplay offline. The
crash is a separate synchronization failure under investigation. These
patches preserve the diagnostic steps and tested source deltas; they do not
claim to fix the crash or the game's offline support.

The known-good 02.59 behavior and source changes are also carried forward in
this branch. The 02.60 build had a filter typo and is intentionally not
included.

## Validation record

- 02.61 parity: pass; no baseline payload omissions.
- 02.61 `pkg_validate`: pass.
- 02.62 parity: pass; no baseline payload omissions.
- 02.62 `pkg_validate`: pass.
- The patch archives are intended to make the dependency-tree edits reviewable
  and repeatable from the Orbis-Win repository.
