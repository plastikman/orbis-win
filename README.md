<p align="center">
  <img src="assets/orbis-win-mark.svg" width="112" height="112" alt="orbis-win mark: a cyan O and a white W">
</p>

<h1 align="center">orbis-win</h1>

<p align="center">
  Run Windows PC games on a PS4 with GoldHEN.<br>
  <b>prospero-win's Wine, ported to Orbis OS and packaged as one app. No Linux, no dual boot.</b>
</p>

<p align="center">
  <a href="https://github.com/plastikman/orbis-win/releases/latest"><img src="https://img.shields.io/github/v/release/plastikman/orbis-win" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/plastikman/orbis-win" alt="License"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#tested-games">Tested games</a> ·
  <a href="#profiles">Profiles</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#documentation">Docs</a>
</p>

<!-- TODO(asset): demo.gif — 10–20 s, captured from the console: the launcher listing games → pick Half-Life 2 → its menu → a few seconds of play → Quit → back at the launcher. Save to docs/assets/demo.gif -->
<!-- <p align="center"><img src="docs/assets/demo.gif" width="720" alt="Picking Half-Life 2 in the orbis-win launcher, playing, and quitting back to the launcher"></p> -->
<!-- TODO(asset): launcher.png — still of the launcher with several game tiles and the Settings tile, 1920x1080 PNG; use it here if the GIF isn't ready. Save to docs/assets/launcher.png -->
<!-- <p align="center"><img src="docs/assets/launcher.png" width="720" alt="The orbis-win launcher listing installed games"></p> -->

**Played on the test console (a PS4 Pro):** Fallout 3, Fallout: New Vegas,
Oblivion, Half-Life, Half-Life 2, Left 4 Dead 2, Vampire: The Masquerade –
Bloodlines, GTA IV and MDK on v0.0.5; Titan Quest and Space Cadet Pinball on
v0.0.4. [Results and known issues](#tested-games).

## Quick start

You need a PS4 with [GoldHEN](https://github.com/GoldHEN/GoldHEN) and its FTP
server on, a Linux PC or VM on the same network, and your own copy of a game.

1. **Install the app.** Download `IV0000-GLDS10043_00-GLDS100430000000.pkg`
   from the [latest release](https://github.com/plastikman/orbis-win/releases/latest)
   and install it with GoldHEN's package installer. Start it once: it creates
   `/data/prospero-win/`.
2. **Add a game (on a Linux PC).** The PS4 can't set up a game's Wine prefix
   itself, so you prepare each game on a Linux PC or VM and send it over the
   network.
   - *Once:* clone prospero-win and orbis-win and build the same Wine the app
     uses (26 minutes on the test VM).
   - *Per game:* make a Wine prefix (a small Windows install for that game),
     copy the game into it (plus DXVK for Direct3D games), add the game's
     profile, and push both to the PS4 over GoldHEN's FTP.

   [Half-Life 2, step by step](docs/INSTALLING-GAMES.md#quick-start-half-life-2-from-start-to-finish)
   has every command. On the test VM, Half-Life 2's 5.23 GiB push took under
   6 minutes.

3. **Play.** Start the app and pick the game (Half-Life 2's first start takes
   about a minute). Quitting the game returns to the launcher; holding
   Options + Create asks the game to close.

**Check it worked:** the launcher lists the game. If it doesn't, the
launcher's session log in `/data/prospero-win/logs/` says why
(`PW_WINE64 profile refused file=<f> status=<s>`); see
[Troubleshooting](docs/INSTALLING-GAMES.md#troubleshooting).

## Why orbis-win

[prospero-win](https://github.com/mpereiraesaa/prospero-win) is the Windows
runtime for PlayStation consoles. orbis-win is its PS4 port:

- **It runs inside Orbis OS.** One package, installed with GoldHEN's package
  installer, holds Wine, the PS4 GPU driver and a game launcher.
- **It follows upstream.** The PS4 work (a platform layer for display,
  controller, audio and network, plus Wine and Mesa patches) is kept as
  patches against pinned upstream trees, so the port can move to a new
  prospero-win generation without losing it. The current one is ABI-v4
  (upstream `main` at `18115ce`, 2026-11-01), with every functional PS4 patch
  from the earlier port carried forward.
- **Packages are checked before they ship.** A package is published only if
  every parity gate against the last hardware-tested baseline passes, and the
  release notes say which games were played on the test console before
  publishing.

## Tested games

| Game | Profile | CPU | Last played on | Notes |
|---|---|---|---|---|
| Fallout: New Vegas | `fallout-new-vegas` | Native WoW64 | v0.0.5 (01.66) | V.A.T.S. works. The wineserver heap is backed by direct memory. |
| Fallout 3 GOTY (GOG) | `fallout3-gog` | Native WoW64 | v0.0.5 (01.66) | V.A.T.S. works. MPEG-1 videos don't play (no Wine MPEG-I splitter). |
| The Elder Scrolls IV: Oblivion (GOG) | `oblivion-gog` | Native WoW64 | v0.0.5 (01.66) | Keyboard input mode; the left stick maps to movement keys. Music works from 01.43 (`bMusicEnabled=1`). |
| Half-Life | `half-life` | Native WoW64 | v0.0.5 (01.66) | OpenGL through Mesa Zink. A 4:3 picture is centred with black bars. |
| Half-Life 2 | `half-life-2` | Native WoW64 | v0.0.5 (01.66) | Options opens the pause menu; the touchpad is the mouse. First start ~67 s, later ~50 s. |
| Left 4 Dead 2 | `left-4-dead-2` | Native WoW64 | v0.0.5 (01.66) | Turn model decals off (see Known issues). |
| Vampire: The Masquerade – Bloodlines (GOG) | `bloodlines-gog` | Native WoW64 | v0.0.5 (01.66) | Its Quit returns to the launcher from v0.0.4. |
| Grand Theft Auto IV | `gtaiv-test` | Native WoW64 | v0.0.5 (01.66) | About 8–9 fps in gameplay. Slower to load than the other titles. |
| MDK | `mdk-windows` | Translator | v0.0.5 (01.66) | Runs on the prospero-win translator (`wowprospero.dll`). |
| Titan Quest Anniversary Edition | `titan-quest-anniversary` | Native WoW64 | v0.0.4 (01.58) | Create, play, save, quit. Mouse-driven; the controller layout is basic. |
| Space Cadet Pinball | `pinball` | Translator | v0.0.4 (01.58) | GDI (no Direct3D), 800x600 desktop. The touchpad is the mouse, so Game > Exit works. |

<!-- VERIFY: the v0.0.4 and v0.0.5 release notes list Left 4 Dead 2 as played with profile `left-4-dead-2`, but src/profiles has no left-4-dead-2.profile, and docs/INSTALLING-GAMES.md ("Steam and other DRM") says L4D2 stops with a message that it needs Steam. Add the profile and reconcile that section, or drop the row. -->

On v0.0.4's full run (01.58), all eleven titles were played with no crash,
GPU memory failure or other error, and each one's own Quit / Exit returned to
the launcher (about 3–7 s after the game ends). v0.0.5's package (01.66) was
played on the nine titles marked above, again with no crash or error.

These results come from one test console. They are hardware and game-version
specific, not a blanket compatibility claim. See
[hardware status and caveats](docs/HARDWARE-STATUS.md) and the
[latest handoff](docs/HANDOFF-2026-11-08.md).

### Known issues

- **Left 4 Dead 2: turn off decals on models.** With them on, the Dark
  Carnival campaign crashed after a few minutes in the game's model-decal
  code. Put `r_drawmodeldecals 0` in `left4dead2/cfg/autoexec.cfg` inside the
  game folder, or add `+r_drawmodeldecals 0` to the `arguments =` line of the
  game's profile.
- **Titan Quest:** the controller only drives the mouse pointer.
- **Half-Life:** the right stick also moves the pointer in gameplay.
- **Fallout 3:** MPEG-1 videos don't play.
- **GTA IV:** CPU-bound at about 8–9 fps in gameplay (see the [FAQ](#faq)).
- **The translator CPU** is used only for MDK and Pinball. Titan Quest crashes
  on it.

## What's in the package

| Area | What it does | Where it lives |
|---|---|---|
| Graphics | Direct3D 8–11 games draw through DXVK (2.6.2 tested; its DLLs go in the prefix) on PS4 RADV, Mesa's Vulkan driver running on the PS4 GPU. OpenGL games use the package's Mesa Zink provider. GDI games run too. | [`src/mesa-patches-ps4/`](src/mesa-patches-ps4), [`src/native/pw_vulkan_radv_ps4.c`](src/native/pw_vulkan_radv_ps4.c), [`src/native/pw_videoout_ps4.c`](src/native/pw_videoout_ps4.c) |
| CPU | 32-bit games run on the native WoW64 backend by default; prospero-win's x86 translator (`wowprospero.dll`) is the per-profile fallback. | `[runtime] cpu` in each profile |
| Controller | Passed to games as an XInput controller, or mapped to keyboard and mouse. A stick or the touchpad drives the pointer; a two-finger touchpad click opens the on-screen keyboard. | [`src/native/pw_pad_ps4.c`](src/native/pw_pad_ps4.c), [`src/native/pw_osk_ps4.c`](src/native/pw_osk_ps4.c), [`src/profiles/input/`](src/profiles/input) |
| Audio | Game audio through the console, and MP3 through DirectShow without GStreamer (from v0.0.2). | [`src/native/pw_audio_ps4.c`](src/native/pw_audio_ps4.c), fork Wine patch 1069 |
| Launcher | Lists the installed profiles; the app restarts into the chosen game and returns when it quits. Has a Settings tile and, from v0.0.5, settings for each game. | [plastikman/prospero-win](https://github.com/plastikman/prospero-win) |
| Updates | When the launcher starts, it asks GitHub for a newer stable release; **Settings › Download update** fetches it and keeps it only if its size and SHA-256 match. | [plastikman/prospero-win](https://github.com/plastikman/prospero-win) |
| Logs | A log per session on the console, with no setup, and an optional live log to a PC. | `/data/prospero-win/logs/`, [`scripts/ps5logd.py`](scripts/ps5logd.py) |
| Shared runtime | From v0.0.5 the runtime reads the running app's title ID from the console and uses `/data/<title ID>`, so other PS4 apps (such as [Playden for PS4](https://github.com/plastikman/playden-ps4)) can carry it unchanged. | [`src/native/pw_vulkan_radv_ps4.c`](src/native/pw_vulkan_radv_ps4.c), the fork |

## Profiles

A profile tells the launcher how to run one game: the executable, the CPU
backend, the input mode and preset, DLL overrides, and any environment the
game needs. The tested profiles are in [`src/profiles`](src/profiles), as they
ran on the test console; other profiles there are diagnostic or untested
variants. Controller presets (`goldsrc` for Half-Life, `mdk` for MDK's
original controls, and `mouse`, `mouselook`, `arrows` and `gamepad`) are in
[`src/profiles/input`](src/profiles/input). To write one for a new game, start
from the commented template in
[Installing games](docs/INSTALLING-GAMES.md#writing-a-profile-for-a-new-game).

Install them on the console under `/data/prospero-win/`:

| What | Console path |
|---|---|
| Profiles (`*.profile`) | `/data/prospero-win/profiles/` |
| Input presets (`*.input`) | `/data/prospero-win/input/` |
| Game prefixes | `/data/prospero-win/prefixes/<profile>/` (a complete Wine prefix, game in `drive_c/...`) |

A profile that names an input preset (`preset = goldsrc`) needs that preset
installed too; the launcher rejects the preset otherwise. From v0.0.5 the
package carries the presets in `src/profiles/input`, and the launcher copies a
missing one to `/data/prospero-win/input/` when a profile names it.

<!-- VERIFY: build-relocatable-wine-ps4.sh packs every src/profiles/input/*.input (all six), but the v0.0.5 release notes name only mouse, mouselook, arrows and gamepad as copied when missing. Confirm goldsrc and mdk are copied too. -->

The pointer can follow a stick (`mouse = left_stick` / `right_stick`) or the
touchpad (`mouse = touchpad`, like a laptop trackpad; `mouse_speed` 1200 is one
pixel per touchpad unit). `touchpad = mouse_left` makes a pad click a left
click; two-finger click opens the on-screen keyboard.

**Settings for each game (v0.0.5).** Press Triangle on a game in the launcher
to change its program (the game's own executable, or a launcher or setup tool
next to it), controller mode and preset, pointer and movement sticks, pointer
speed, resolution (1024×768 to 2560×1440), Wine log level, library overrides
and button mapping. Changes are saved to the game's profile and apply the
next time it starts; a row you haven't changed says **As shipped**.

<!-- TODO(asset): game-settings.png — the per-game settings card on the console (v0.0.5) for one tested game, 1920x1080 PNG. Save to docs/assets/game-settings.png -->
<!-- <p align="center"><img src="docs/assets/game-settings.png" width="640" alt="The per-game settings card in the orbis-win launcher"></p> -->

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

<details>
<summary>The settings each tested title ran with on 01.41</summary>

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

</details>

## Settings, logs and updates

The launcher's **Settings** tile (after your games) turns the console's
switches on and off: sending the app log to a PC, that PC's address, Wine's
log level, the wait watchdog, the GPU hang report and the update check.
Changes are saved at once and apply to the next game you start. It keeps them
in `/data/prospero-win/settings.conf`, the one switch file on the console:

<!-- VERIFY: the v0.0.4 notes say Triangle anywhere in the launcher opens Settings; the v0.0.5 notes say Triangle on a game opens that game's settings. Confirm what Triangle does now and say so here. -->

```ini
log=1
log_server=<your PC's IP address>
log_port=9300
wine_log=profile          # profile | quiet | detailed
wait_watchdog=0
gpu_hang_report=0
update_check=1
```

Run `scripts/ps5logd.py 9300` on that PC to receive the log. Each session
also writes `session-N.log` to `/data/prospero-win/logs/` with no setup;
[Troubleshooting](docs/INSTALLING-GAMES.md#troubleshooting) explains how to
fetch and read it. A console that still has an older
`/data/prospero-win/dev.conf` has it carried into `settings.conf` once; after
that `dev.conf` is ignored. Developer packages can also carry their own
`/app0/dev.conf` (local builds take `build/devconf/dev.conf`; CI uses the
`PS4_LOG_SERVER` repository variable), which logs from the first line of
start-up.

**Updates.** When a newer stable release is on GitHub, the launcher says so
in its title bar, and **Settings › Download update** saves its package to
`/data/pkg` (about two minutes on the test console). It is kept only if its
size and SHA-256 match what GitHub publishes; install it with GoldHEN's
package installer as usual. The package's version increases with every build,
so it installs over an earlier one and leaves your profiles, prefixes and
saves alone.

## Build from source

Start with [`docs/BUILDING.md`](docs/BUILDING.md) and the
[upstream sync playbook](docs/UPSTREAM-SYNC-PLAYBOOK.md).
`scripts/ci/build-abi4-package.sh` builds the package, on the build
workstation or in the [`Build PS4 package`](.github/workflows/build-ps4-package.yml)
workflow, which runs on a self-hosted runner from a private build cache, on
manual runs and package-version tags only (see
[`scripts/ci/README.md`](scripts/ci/README.md)). Releases are built locally
from clean checkouts of this repository and the prospero-win fork. A package
is published only if every parity gate against the baseline passes.

<details>
<summary>What the gates check</summary>

`scripts/check-ps4-package-parity.py` compares a candidate against the
hardware-validated baseline stage: relocation stub, Vulkan surface, display,
swapchain sizing, quit to launcher, PS4 RADV, PRX exports, kernelbase
diagnostics and signal-mask values. `PkgTool.Core pkg_validate` must also
pass. In CI, `scripts/ci/check-wine-series.sh` first checks that the fork's
Wine patch series applies to clean Wine and gives exactly the Wine source the
cached runtime was built from, and the job refuses a clang other than 19.1.7,
the build workstation's version.

</details>

The package build defaults to relocatable mode; do not remove the relocation
step for normal game builds.

Console-specific addresses belong in an ignored `config.env`, never in a
committed profile or build script. [`config.env.example`](config.env.example)
shows the supported settings.

Working rules for upstream syncs, crash dumps and A/B runs on hardware are in
[`AGENTS.md`](AGENTS.md).

## What this is not

- **Not a compatibility promise.** Every result above comes from one PS4 Pro.
  Other consoles, firmware versions and game editions may behave differently.
- **Not a way around DRM.** There is no Steam client on the console. Some Steam
  games run from their own files (Half-Life 2); others refuse. GOG and other
  DRM-free editions are the safest choice.
- **Not a source of games or console files.** Game data, console firmware
  modules, SDK payloads and generated packages are not in this repository.
- **Not Linux.** The app runs inside the PS4's own operating system.

## FAQ

**Does it run on a base PS4 or a PS4 Slim?** The project's test console is a
PS4 Pro (CUH-7xxx, firmware 9.60, GoldHEN). Other models haven't been
validated by the project. If you try one, record its firmware, GoldHEN
version, game edition, profile, package version and result.

**Why make the prefix on a PC?** On a PC, Wine creates a prefix with
`wineboot`. The PS4 app can't run it, because `wineboot` is a separate program
and the app can't start other programs. So each prefix is made on a PC with
the matching Wine build and copied over complete; a game folder alone isn't
enough.

**Why is GTA IV slow?** Its settings apply, but performance doesn't move:
8–9 fps in gameplay with shadows on or off, at 720p or 1080p. Only 2.1–2.5 of
the six CPU cores are busy; the game's main thread, on one 1.6 GHz Jaguar
core, is the limit. GTA IV isn't a performance target.

## Repository layout

| Path | What it holds |
|---|---|
| [`src/native/`](src/native) | PS4 presentation, controller, audio, network and runtime glue. |
| [`src/wine-patches-ps4/`](src/wine-patches-ps4) | The PS4 Wine patch archive. The ABI-v4 series that ports them lives in the prospero-win fork under `wine/patches/`. |
| [`src/mesa-patches-ps4/`](src/mesa-patches-ps4) | PS4 Mesa (RADV and the `wsi/orbis` scan-out). |
| [`src/prospero-win-patches-ps4/`](src/prospero-win-patches-ps4) | PS4 delta against the pinned upstream tree. |
| [`src/profiles/`](src/profiles) | Tested and diagnostic game profiles, and input presets. |
| [`patches/`](patches) | Mesa (RADV) and DXVK patches, mostly diagnostics. |
| [`scripts/`](scripts) | SDK setup, build, packaging, deployment and log capture. |
| [`docs/`](docs) | Build guide, hardware status, design notes and chronological handoffs. |
| [`assets/`](assets) | The OW mark at the top of this README, the package's home-screen icon, and the prospero-win mark that icon is rendered from. |

## Documentation

| Read | For |
|---|---|
| [Installing games](docs/INSTALLING-GAMES.md) | Making prefixes, pushing them, writing profiles, troubleshooting. |
| [Building](docs/BUILDING.md) | Host tools, SDK bundle and the package build. |
| [Upstream sync playbook](docs/UPSTREAM-SYNC-PLAYBOOK.md) | Moving to a new prospero-win or Wine generation. |
| [CI build](scripts/ci/README.md) | The self-hosted package build and its private cache. |
| [Hardware status](docs/HARDWARE-STATUS.md) | Per-title notes (as of 01.34) and reproduction notes. |
| [Findings](docs/FINDINGS.md) | Dated hardware findings: GPU bring-up, crashes, measurements. |
| [Latest handoff](docs/HANDOFF-2026-11-08.md) | Where the work stood at v0.0.4, and the open items. |
| [Releases](https://github.com/plastikman/orbis-win/releases) | Release notes, packages, parity reports and build manifests. |

## Reporting problems

Open an [issue](https://github.com/plastikman/orbis-win/issues) with the
details listed in
[Reporting a problem](docs/INSTALLING-GAMES.md#reporting-a-problem): the
console model with its firmware and GoldHEN versions, the release you
installed, the game and its edition, the profile, how you made the prefix,
what you saw and when, and the game's `session-N.log`. Without the log, most
reports can only be answered with "send the log".

## Built on

- [prospero-win](https://github.com/mpereiraesaa/prospero-win), the Windows
  runtime for PlayStation consoles that this ports. The PS4 side lives on
  [plastikman/prospero-win](https://github.com/plastikman/prospero-win) `main`.
- [orbis-ports/mesa-ps4](https://github.com/orbis-ports/mesa-ps4), Mesa's RADV
  running natively on the PS4 GPU under Orbis OS.
- [Wine](https://www.winehq.org/), at the revision prospero-win pins, with its
  patch series.
- [DXVK](https://github.com/doitsujin/dxvk), for Direct3D 8–11 games.
- [OpenOrbis PS4 Toolchain](https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain),
  whose source generates the package's empty `libc.prx` and `libSceFios2.prx`
  stubs in CI.
- [GoldHEN](https://github.com/GoldHEN/GoldHEN), whose package installer and
  FTP server put the app and games on the console.

## License

Project-authored code is licensed under [LGPL-2.1-or-later](LICENSE), in line
with `prospero-win`. See [LICENSING.md](LICENSING.md) for file-level exceptions
and third-party boundaries. The package's home-screen icon is `prospero-win`'s
mark and remains under that project's license; the OW mark above was drawn
for orbis-win.

All game data, console firmware modules, SDK payloads and generated packages
remain external and are not included in this repository.
