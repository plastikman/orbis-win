# orbis-win

`orbis-win` is a PS4 port of [prospero-win](https://github.com/mpereiraesaa/prospero-win),
the Windows runtime for PlayStation consoles. This repository keeps the PS4
platform layer, upstream compatibility patches, packaging and deployment tools,
game profiles, and hardware findings together so the port can follow upstream
without losing its PS4-specific work.

The current baseline is the last committed state before the recent MDK
investigation. MDK is outside the scope of the reported four-title results.
Successful runs are hardware and game-version specific, not a blanket
compatibility claim.

## Hardware status

The PS4 test system has reached gameplay with these four titles:

| Game | Profile | CPU mode | Notes |
|---|---|---|---|
| Grand Theft Auto IV | `gtaiv` | Native WoW64 | Reaches gameplay. |
| The Elder Scrolls IV: Oblivion (GOG) | `oblivion-gog` | Native WoW64 | Reaches gameplay; DualSense left stick maps movement to keyboard input. |
| Fallout: New Vegas | `fallout-new-vegas` | Native WoW64 | Reaches gameplay; V.A.T.S. has a known DXVK/D3D9 fault guarded in the current profile. |
| Fallout 3 GOTY (GOG) | `fallout3-gog` | Translator | Reaches gameplay; V.A.T.S. was exercised successfully. |

The profiles are under [`src/profiles`](src/profiles). The status records
hardware runs on the project test console; another PS4 model still needs its
own validation. See [hardware status and caveats](docs/HARDWARE-STATUS.md) and
the [latest handoff](docs/HANDOFF-2026-10-26.md).

## Build and package

Start with [`docs/BUILDING.md`](docs/BUILDING.md). The short version:

```sh
./scripts/prereqs.sh
./scripts/fetch-sdk.sh
git clone https://github.com/mpereiraesaa/prospero-win.git prospero-win
```

Check out the upstream commit and apply the PS4 delta as documented in the
build guide, then build Wine, the PS4 PRXs, and the relocatable package. The
package build defaults to relocatable mode; do not remove the relocation step
for normal game builds.

Console-specific addresses belong in an ignored `config.env`, never in a
committed profile or build script. `config.env.example` shows the supported
settings.

## What is in this repository

- `src/native/`: PS4 presentation, controller, audio, network and runtime glue.
- `src/wine-patches-ps4/`: PS4 Wine patch series.
- `src/prospero-win-patches-ps4/`: PS4 delta against the pinned upstream tree.
- `src/profiles/`: tested and diagnostic game profiles.
- `scripts/`: SDK setup, build, packaging, deployment and log capture.
- `docs/`: build guide, hardware status, design notes and chronological
  handoffs.

## Porting work captured

This snapshot includes the PS4 native WoW64 path, relocatable Wine package
layout, Vulkan/RADV integration, filesystem and network bindings, controller
mapping, audio setup, and runtime diagnostics. It also preserves title-specific
profiles and the fixes learned while bringing the four games above to
gameplay. The build guide pins the matching upstream source and SDK bundle so
another PS4 developer can reproduce the same starting point before rebasing.

## License

Project-authored code is licensed under [LGPL-2.1-or-later](LICENSE), in line
with `prospero-win`. See [LICENSING.md](LICENSING.md) for file-level exceptions
and third-party boundaries.

All game data, console firmware modules, SDK payloads and generated packages
remain external and are not included in this repository.
