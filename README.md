# orbis-win

`orbis-win` is a PS4 port of [prospero-win](https://github.com/mpereiraesaa/prospero-win),
the Windows runtime for PlayStation consoles. This repository keeps the PS4
platform layer, upstream compatibility patches, packaging and deployment tools,
game profiles, and hardware findings together so the port can follow upstream
without losing its PS4-specific work.

The current baseline is **GLDS10043 01.49** (2026-11-08, release `v0.0.3`):
ABI-v4 with the Wine runtime built from the prospero-win fork's patch series
alone (reproducible; CI checks it on every build), a launcher notice when a
newer release is on GitHub, and Mesa patches 0001–0044 (0043/0044: the GPU
driver's hang report no longer crashes or stutters games); every title below
passes on it. `v0.0.2` (01.43) added MP3 audio through DirectShow and
`v0.0.1` (01.41) the GPU memory fixes. It is built on
prospero-win's ABI-v4 generation (upstream `main` at `18115ce`, 2026-11-01) with
every functional PS4 patch from the earlier port carried forward. The PS4 side
of prospero-win lives on [plastikman/prospero-win](https://github.com/plastikman/prospero-win)
`main`. Successful runs are hardware and game-version specific, not a blanket
compatibility claim.

## Hardware status

On the project test console, every title below reaches gameplay, and except
for Bloodlines the game's own Quit / Exit returns to the title's launcher
(about 3–7 s after the game ends).

| Game | Profile | CPU mode | Notes |
|---|---|---|---|
| Grand Theft Auto IV | `gtaiv-test` | Native WoW64 | Reaches gameplay. Slower to load than the other titles. |
| The Elder Scrolls IV: Oblivion (GOG) | `oblivion-gog` | Native WoW64 | Keyboard input mode; the left stick maps to movement keys. Music works from 01.43 (`bMusicEnabled=1`). |
| Fallout: New Vegas | `fallout-new-vegas` | Native WoW64 | V.A.T.S. works. The wineserver heap is backed by direct memory. |
| Fallout 3 GOTY (GOG) | `fallout3-gog` | Native WoW64 | V.A.T.S. works. MPEG-1 videos do not play (no Wine MPEG-I splitter). |
| Half-Life | `half-life` | Native WoW64 | OpenGL through Mesa Zink. A 4:3 picture is centred with black bars. |
| MDK | `mdk-windows` | Translator | Runs on the prospero-win translator (`wowprospero.dll`). |
| Vampire: The Masquerade - Bloodlines (GOG) | `bloodlines-gog` | Native WoW64 | Plays (from 01.23). Its Quit hangs; close it from the PS menu. |
| Titan Quest Anniversary Edition | `titan-quest-anniversary` | Native WoW64 | Plays from 01.34: create, play, save, quit. Mouse-driven; the controller layout is basic. |
| Half-Life 2 | `half-life-2` | Native WoW64 | Plays: menu, game, pause menu (Options), quit. Touchpad is the mouse for the settings menus. First start ~67 s, later ~50 s. |
| Space Cadet Pinball | `pinball` | Translator | GDI (no Direct3D), 800x600 desktop. The touchpad is the mouse, so Game > Exit works (from v0.0.3's profile). |

See [hardware status and caveats](docs/HARDWARE-STATUS.md) and the
[latest handoff](docs/HANDOFF-2026-11-08.md).

## Profiles

A profile tells the launcher how to run one game: the executable, the CPU
backend, the input mode and preset, DLL overrides, and any environment the
game needs. The tested profiles are in [`src/profiles`](src/profiles), copied
from the test console as they ran on 01.21; input presets (`goldsrc` for
Half-Life, `mdk` for MDK's original controls) are in
[`src/profiles/input`](src/profiles/input).

The tested profiles keep the `[debug]` sections they were tested with (Wine
debug channels, trace switches); Half-Life's one-off crash diagnostics were
removed. Most of those lines only add logging and can be removed. Keep two
in the Fallout profiles, because they change behaviour and are how Fallout 3
and New Vegas were validated:

- `PW_WINESERVER_HEAP_DIRECT=1` backs the wineserver heap with PS4 direct
  memory.
- `PW_PS4_FORCE_EXEC=0` keeps no-exec on for data pages, although these games
  lack the NX-compatible flag. Without it, every readable page asks for
  execute permission and is moved out of direct memory.

Install them on the console under `/data/prospero-win/`:

| What | Console path |
|---|---|
| Profiles (`*.profile`) | `/data/prospero-win/profiles/` |
| Input presets (`*.input`) | `/data/prospero-win/input/` |
| Game prefixes | `/data/prospero-win/prefixes/<profile>/` (a complete Wine prefix, game in `drive_c/...`) |

A profile that names an input preset (`preset = goldsrc`) needs that preset
installed too; the launcher rejects the preset otherwise.

The pointer can follow a stick (`mouse = left_stick` / `right_stick`) or the
touchpad (`mouse = touchpad`, like a laptop trackpad; `mouse_speed` 1200 is one
pixel per touchpad unit). `touchpad = mouse_left` makes a pad click a left
click; two-finger click opens the on-screen keyboard.

The settings each tested title ran with on 01.41:

| Profile | `cpu` | Input mode | Preset | DLL overrides |
|---|---|---|---|---|
| `gtaiv-test` | native | xinput | – | `d3d8,d3d9,d3d10core,d3d11,dxgi=n;dinput8=n,b` |
| `oblivion-gog` | native | keyboard (mouse 2) | – | – |
| `fallout-new-vegas` | native | xinput | – | `d3d8,d3d9,d3d10core,d3d11,dxgi=n` |
| `fallout3-gog` | native | xinput | – | `d3d9=n;dxgi=b` |
| `half-life` | native | xinput (mouse 2) | `goldsrc` | `opengl32=n` |
| `mdk-windows` | translator | keyboard (mouse 2) | – | `d3d8,d3d9,d3d10core,d3d11,dxgi=n` |
| `bloodlines-gog` | native | keyboard (mouse 2) | – | `d3d8,d3d9,d3d10core,d3d11,dxgi=n` |
| `titan-quest-anniversary` | native | keyboard (mouse 1) | – | `d3d8,d3d9,d3d10core,d3d11,dxgi=n` |
| `half-life-2` | native | xinput (mouse touchpad) | – | `d3d8,d3d9,d3d10core,d3d11,dxgi=n` |
| `pinball` | translator | keyboard | – | – |

Other profiles in `src/profiles` are diagnostic or untested variants.

## Install and use

Releases are on the [releases page](https://github.com/plastikman/orbis-win/releases).
Each one carries a single installer, `IV0000-GLDS10043_00-GLDS100430000000.pkg`
(title ID GLDS10043). Its version increases with every build, so it installs
over an earlier one.

1. Install the package with GoldHEN's package installer.
2. Copy the profiles and input presets above to the console, and each game's
   complete Wine prefix, made on a PC, to `/data/prospero-win/prefixes/`. A
   game folder alone isn't enough: the console can't create a prefix itself.
   [Installing games](docs/INSTALLING-GAMES.md) walks through it and covers
   troubleshooting.
3. Start the title. The launcher lists the installed profiles; pick a game.
   Quitting the game returns to the launcher. Holding Options + Create asks
   the game to close.

## Build and package

Start with [`docs/BUILDING.md`](docs/BUILDING.md) and the
[upstream sync playbook](docs/UPSTREAM-SYNC-PLAYBOOK.md). Release packages are
built by the [`Build PS4 package`](.github/workflows/build-ps4-package.yml)
workflow on a self-hosted runner from a private build cache; see
[`scripts/ci/README.md`](scripts/ci/README.md). The same script,
`scripts/ci/build-abi4-package.sh`, builds locally, and a package is published
only if every parity gate against the baseline passes.

The package build defaults to relocatable mode; do not remove the relocation
step for normal game builds.

Console-specific addresses belong in an ignored `config.env`, never in a
committed profile or build script. `config.env.example` shows the supported
settings.

**App log.** A package sends its app log to a `ps5logd` host if it contains
a `dev.conf` (local builds take `build/devconf/dev.conf`; CI uses the
`PS4_LOG_SERVER` repository variable). Release packages have none, so they are
silent unless one is put on the console: copy a `dev.conf` to
`/data/prospero-win/dev.conf` to turn logging on for every launch, and delete
it to turn it off. A minimal `dev.conf`, received by `scripts/ps5logd.py 9300`
on your PC:

```
DEV_ENABLED=1
DEV_SERVER=<your PC's IP address>
DEV_PORT=9300
```

## What is in this repository

- `src/native/`: PS4 presentation, controller, audio, network and runtime glue.
- `src/wine-patches-ps4/`: the PS4 Wine patch archive. The ABI-v4 series that
  ports them lives in the prospero-win fork under `wine/patches/`.
- `src/mesa-patches-ps4/`: PS4 Mesa (RADV and the `wsi/orbis` scan-out).
- `src/prospero-win-patches-ps4/`: PS4 delta against the pinned upstream tree.
- `src/profiles/`: tested and diagnostic game profiles, and input presets.
- `scripts/`: SDK setup, build, packaging, deployment and log capture.
- `docs/`: build guide, hardware status, design notes and chronological
  handoffs.

## License

Project-authored code is licensed under [LGPL-2.1-or-later](LICENSE), in line
with `prospero-win`. See [LICENSING.md](LICENSING.md) for file-level exceptions
and third-party boundaries.

All game data, console firmware modules, SDK payloads and generated packages
remain external and are not included in this repository.
