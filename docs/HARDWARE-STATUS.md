# PS4 hardware status

Status reflects the project test system on GLDS10043 01.21 (2026-11-05), the
current baseline. A title is marked as working only because it reached
gameplay on hardware; it does not imply every release, add-on, or console model
will behave the same way.

| Title / edition | Profile | CPU backend | Result and known limit |
|---|---|---|---|
| Grand Theft Auto IV Complete Edition | `gtaiv-test` | Native WoW64 | Reaches gameplay; the game's exit returns to the launcher. Loads more slowly than the other titles. |
| The Elder Scrolls IV: Oblivion GOG | `oblivion-gog` | Native WoW64 | Reaches gameplay. DualSense left stick sends keyboard movement; right stick controls the mouse. |
| Fallout: New Vegas | `fallout-new-vegas` | Native WoW64 | Reaches gameplay; V.A.T.S. works. |
| Fallout 3 GOTY GOG | `fallout3-gog` | Native WoW64 | Reaches gameplay; V.A.T.S. works. The GOG launcher is bypassed; `Fallout3.exe` starts directly. MPEG-1 videos do not play. |
| Half-Life | `half-life` | Native WoW64 | Reaches gameplay through Mesa Zink (OpenGL on Vulkan); the 4:3 picture is centred. Frame pacing can be uneven. |
| MDK | `mdk-windows` | Translator | Reaches gameplay on the prospero-win translator. The native backend is not pursued for MDK. |

On every title above, the game's own Quit / Exit to Desktop returns to the
title's launcher about 3–7 s after the game ends.

These results were recorded on one PS4 test console. A PS4 Slim user's setup is
an independent validation target. Record its firmware, GoldHEN version, game
edition, profile, package version, and result before treating it as equivalent.

## Reproduction notes

- Build and install from the same source commit; profiles and runtime packages
  must not be mixed across ABI generations. 01.21 is ABI-v4.
- Keep the relocatable package path enabled. Oblivion's PE32 executable has no
  relocation section and needs its preferred low address available.
- Fallout: New Vegas and Fallout 3 testing use the native WoW64 backend. Do not
  switch to the translator unless a controlled A/B is needed.
- For a translator A/B, confirm the trace loads `wowprospero.dll` and reaches
  `BTCpuSimulate`; a profile that only omits the native override can inherit
  `wow64cpu.dll` from the prefix.
- Controller mappings are per-game profiles; the runtime maps DualSense input
  to XInput or to keyboard and mouse actions as the game requires. A profile
  that names an input preset needs that preset installed under
  `/data/prospero-win/input/`.

Detailed chronology, crash signatures, and previous A/B results are in the
[handoff](HANDOFF-2026-11-05.md) and [findings](FINDINGS.md).
