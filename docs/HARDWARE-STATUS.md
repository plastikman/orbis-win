# PS4 hardware status

Status reflects the project test system as of the pre-MDK baseline published
from this branch. A title is marked as working only because it reached
gameplay on hardware; it does not imply every release, add-on, or console model
will behave the same way.

| Title / edition | Profile | CPU backend | Result and known limit |
|---|---|---|---|
| Grand Theft Auto IV Complete Edition | `gtaiv` | Native WoW64 | Reached gameplay. Performance and graphics settings remain game-specific. |
| The Elder Scrolls IV: Oblivion GOG | `oblivion-gog` | Native WoW64 | Reached gameplay. DualSense left stick sends keyboard movement; right stick controls the mouse. |
| Fallout: New Vegas | `fallout-new-vegas` | Native WoW64 | Reached gameplay. A reproducible V.A.T.S. render fault is guarded by the tested profile's DXVK override. |
| Fallout 3 GOTY GOG | `fallout3-gog` | Translator | Reached gameplay and V.A.T.S. The GOG launcher is bypassed; `Fallout3.exe` starts directly. |

These results were recorded on one PS4 test console. A PS4 Slim user's setup is
an independent validation target. Record its firmware, GoldHEN version, game
edition, profile, package commit, and result before treating it as equivalent.

## Reproduction notes

- Build and install from the same source commit; profiles and runtime packages
  must not be mixed across ABI generations.
- Keep the relocatable package path enabled. Oblivion's PE32 executable has no
  relocation section and needs its preferred low address available.
- Fallout: New Vegas testing uses the native WoW64 backend by default. Do not
  switch to the translator unless a controlled A/B is needed.
- Fallout 3's profile deliberately selects the translator in this baseline.
- Controller mappings are per-game profiles; the runtime maps DualSense input
  to XInput or to keyboard and mouse actions as the game requires.

Detailed chronology, crash signatures, and previous A/B results are in the
[handoff](HANDOFF-2026-10-26.md) and [findings](FINDINGS.md).
