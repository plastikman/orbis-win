# Orbis-Win v0.0.8

## Runtime and graphics

- Adds the PS4-side pieces needed for 64-bit Windows titles to create Vulkan
  resources and display frames when the driver cannot export shared memory as
  a file descriptor. Hollow Knight and Risk of Rain 2 now render, though both
  still stall during startup.
- Preserves the hosted-driver thread providers in both 32-bit and 64-bit Wine
  payloads.
- Fixes a stale direct-memory glue copy that prevented some 32-bit title
  executable pages from becoming executable. GTA IV reaches its episode menu
  and accepts controller navigation.
- Carries the profile runtime-version and environment, audio, and Steam path
  updates, plus the Risk of Rain 2 profile.

## Validation and known issues

Candidate package **02.98** passed the PS4 package parity hard gates and all
`pkg_validate` checks. The 13-title PE32 startup suite was run on-console.
Bloodlines, Fallout 3, Fallout: New Vegas, GTA IV, Half-Life, Half-Life 2,
Oblivion, Space Cadet Pinball, and Titan Quest reached their menus or rendered
their expected startup screen. MDK reached its menu but showed visual
corruption.

Known startup issues remain:

- Hollow Knight and Risk of Rain 2 render but stall during startup. Risk of
  Rain 2 reached 26% in the earlier diagnostic run; it was not rerun in this
  13-title suite.
- The Binding of Isaac exits normally before its first rendered frame.
- Left 4 Dead 2 and Splinter Cell: Conviction remained on the loading spinner
  in the 02.98 suite.

The candidate installer is
`IV0000-GLDS10043_00-GLDS100430000000.pkg`, SHA-256
`6932b8532766a33afca2a386697a62b8a6c95cc2c46802fc38f185c8edb8d3bf`.
Its console app version is **02.98**. The 02.98 package was installed and
validated on-console; this file is a release draft, not a record of a published
GitHub release.
