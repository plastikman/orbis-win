# Installing games and fixing them when they fail

This guide covers getting a Windows game running on the PS4 with orbis-win,
and what to do when it doesn't start or doesn't play. Everything here was
checked on the project's test console (a PS4 Pro with GoldHEN). Other
consoles, firmware versions and game editions may behave differently.

## How it fits together

orbis-win is one PS4 app (title ID GLDS10043) that contains Wine. When you
start it, a launcher lists your games. You pick one, the app restarts into
that game, and quitting the game returns you to the launcher.

Everything the app reads besides itself lives on the console's internal
storage under `/data/prospero-win/`:

```text
/data/prospero-win/
  profiles/<id>.profile      one per game: what to run and how
  input/<name>.input         controller presets that profiles can name
  prefixes/<id>/             the game's own Wine prefix (its "Windows install")
    system.reg  user.reg  userdef.reg
    dosdevices/.pw-symlinks
    drive_c/windows/...      Wine's Windows folder: system32, syswow64, Fonts
    drive_c/users/prospero/  the Windows user's folders (AppData, Documents)
    drive_c/Games/<game>/    the game itself
  logs/                      the app's own logs (see Troubleshooting)
  dev.conf                   optional: streams the log to a PC
```

**The most important point:** a game needs a complete Wine prefix, not only its
game folder. A prefix is a whole small Windows installation: a registry,
`C:\windows\system32` and `syswow64` with Wine's DLLs, fonts, and user folders.

- On a PC, Wine creates a prefix with `wineboot`. The PS4 can't, because
  `wineboot` is a separate program and the app can't start other programs.
- So each prefix is made on a PC with a matching Wine build and copied to the
  console complete. Copying only the game into an empty or partly built prefix
  doesn't work: the app hangs or crashes before the game starts.

## What you need

- A PS4 with GoldHEN and its FTP server running. On the test console it
  listens on port 2121.
- The package `IV0000-GLDS10043_00-GLDS100430000000.pkg` from the
  [releases page](https://github.com/plastikman/orbis-win/releases).
- A Linux PC or virtual machine on the same network as the PS4, to make
  prefixes and copy them over.
- Your own copy of the game.

## Quick start: Half-Life 2 from start to finish

This walks through one tested game with every command. Copy and paste them in
order on a Debian or Ubuntu PC. The steps after it explain each part in
detail.

Every step was run as written on 2026-11-06, from a fresh Debian 13 VM
(6 cores, 8 GB of RAM) to the test console: the push sent 5.23 GiB in under
6 minutes, and Half-Life 2 reached its menu, loaded a map and quit back to the
launcher. On Windows, the test VM ran under Hyper-V:
[Create a Debian Linux virtual machine using Hyper-V](https://techlabs.blog/categories/debian-linux/create-a-debian-linux-virtual-machine-using-hyper-v).

You need your PS4's IP address (Settings > Network > View Connection Status).
Turn on GoldHEN's FTP server before step 9. Replace `192.168.1.50` with your
PS4's address.

**1. Install the tools (once).**

```sh
sudo apt-get update
sudo apt-get install git python3 python3-yaml curl build-essential \
    bison flex pkg-config gcc-mingw-w64 g++-mingw-w64 \
    libx11-dev libxext-dev libfreetype-dev libfontconfig-dev libvulkan-dev \
    libgnutls28-dev libasound2-dev libpulse-dev zlib1g-dev zip unzip
```

**2. Get the code (once).** prospero-win has the tools; orbis-win has the
tested profiles.

```sh
mkdir -p ~/ps4-wine && cd ~/ps4-wine
git clone https://github.com/mpereiraesaa/prospero-win.git
git clone https://github.com/plastikman/orbis-win.git
```

**3. Build Wine for your PC (once).** This is the same Wine version the PS4
package uses. On the test VM the build took 26 minutes.

```sh
cd ~/ps4-wine/prospero-win
git clone --filter=blob:none --no-checkout https://github.com/wine-mirror/wine.git .deps/wine/source
git -C .deps/wine/source checkout "$(sed -n 's/^WINE_COMMIT=//p' tools/build_wine_ps5.sh)"
tools/build_host_wine.sh
```

It ends by printing `host wine: wine-11.17-54-g490f6d5dcb` and the path of
the new `wine`.

**4. Build the CPU DLL (once).** The push in step 9 needs prospero-win's
`wowprospero.dll`. This builds it into the Wine you just built, in about
10 seconds:

```sh
tools/build_wowprospero.sh --build .deps/wine-host/build --source .deps/wine-host/source
```

**5. Make Half-Life 2's prefix.** This takes about 15 seconds. The settings
skip Wine's Mono and Gecko installers and its desktop menu entries, which the
console doesn't use.

```sh
WINE=~/ps4-wine/prospero-win/.deps/wine-host/install/usr/bin/wine
PREFIX=~/prospero-library/prefixes/half-life-2
mkdir -p "$PREFIX/drive_c/Games/HalfLife2"
USER=prospero LOGNAME=prospero WINEARCH=win64 \
WINEPREFIX="$PREFIX" WINEDEBUG=-all \
WINEDLLOVERRIDES='winemenubuilder.exe=d;mshtml=;mscoree=' \
"$WINE" wineboot --init
```

Check that it worked: `ls "$PREFIX/drive_c/windows/syswow64" | wc -l` should
print several hundred. If it prints 0, the 32-bit half of Wine didn't run, and
32-bit games won't work in this prefix.

**6. Copy the game in.** Use your Steam install of Half-Life 2. Change the
first line to where yours is. These are the usual places:

- Steam on Linux: `~/.steam/steam/steamapps/common/Half-Life 2`
- A Windows drive mounted on Linux: `/media/C/Program Files (x86)/Steam/steamapps/common/Half-Life 2`
  ([mounting a Windows share on Linux](https://www.akamai.com/cloud/guides/linux-mount-smb-share))

```sh
GAME="$HOME/.steam/steam/steamapps/common/Half-Life 2"
cp -a "$GAME/hl2.exe" "$GAME/bin" "$GAME/platform" "$GAME/hl2" \
    "$PREFIX/drive_c/Games/HalfLife2/"
```

**7. Add DXVK.** Half-Life 2 is a 32-bit Direct3D 9 game, so it needs DXVK's
32-bit DLLs in `syswow64`.

```sh
cd ~/ps4-wine
curl -LO https://github.com/doitsujin/dxvk/releases/download/v2.6.2/dxvk-2.6.2.tar.gz
tar xf dxvk-2.6.2.tar.gz
cp dxvk-2.6.2/x32/{d3d8,d3d9,d3d10core,d3d11,dxgi}.dll "$PREFIX/drive_c/windows/syswow64/"
```

**8. Add the profile.** It tells the launcher how to run the game.

```sh
mkdir -p ~/prospero-library/profiles
cp ~/ps4-wine/orbis-win/src/profiles/half-life-2.profile ~/prospero-library/profiles/
```

**9. Send it to the PS4.** Run this from the prospero-win folder. It sends
about 5 GB, so it takes a while. If it stops part way, run the same command
again and it carries on where it stopped.

```sh
cd ~/ps4-wine/prospero-win
python3 tools/pw_prefix.py push half-life-2 \
    --library ~/prospero-library \
    --host 192.168.1.50 --port 2121 \
    --cpu-dll .deps/wine-host/build/dlls/wowprospero/x86_64-windows/wowprospero.dll
```

**10. Play.** Install the package (Step 1 below) if you haven't, start the
app and pick Half-Life 2. The first start takes about a minute. Options opens
the game's menu, and the touchpad moves the mouse pointer.

If it doesn't work, see [Troubleshooting](#troubleshooting). Steps 1 to 4 are
one-time setup. For another game, repeat steps 5 to 9 with that game's files,
profile and name.

## Step 1: Install the package

Install `IV0000-GLDS10043_00-GLDS100430000000.pkg` with GoldHEN's package
installer. A newer build installs over an older one. Your profiles, prefixes
and saves in `/data/prospero-win/` are not touched.

Start the app once. It creates `/data/prospero-win/` and `logs/` if they
don't exist. With no profiles installed, the launcher has nothing to list.

## Step 2: Make the game's prefix on a PC

The prefix must come from the same Wine that the package runs: the pinned
Wine revision with prospero-win's patch series. A prefix from a distribution's
Wine, Proton, Lutris's own builds or CrossOver is a different Wine. It can
differ in DLLs and registry layout, and it hasn't been tested.

### Option A: upstream's installer (recommended for new games)

The tools for this are in upstream
[prospero-win](https://github.com/mpereiraesaa/prospero-win). You don't need
our fork ([plastikman/prospero-win](https://github.com/plastikman/prospero-win)).
Its PS4 patches only change code that is built for the console, so they make
no difference to a prefix built on the PC. What matters is the Wine revision:
`WINE_COMMIT` in upstream's `tools/build_wine_ps5.sh` must match the one in
our fork at the commit the release was built from (the release notes name it).
Today both are `490f6d5`. If upstream moves to a newer Wine before we do, use
our fork at the release's commit instead.

1. Build the PC's Wine once. It needs a Wine checkout that contains the pinned
   revision (`WINE_COMMIT` in `tools/build_wine_ps5.sh`), and it applies the
   same patch series as the console build:

   ```sh
   tools/build_host_wine.sh   # prints the path of its wine when done
   ```

   Quick-start steps 3 and 4 have the exact commands, including getting the
   Wine checkout.

2. Install the game from a [Lutris installer
   script](https://github.com/lutris/lutris/blob/master/docs/installers.rst):

   ```sh
   python3 tools/pw_install.py <recipe>.yml --library ~/prospero-library \
       --wine <the wine printed above> --file installer=/path/to/setup.exe
   ```

   You end up with `~/prospero-library/prefixes/<id>/` and
   `~/prospero-library/profiles/<id>.profile`, which mirror
   `/data/prospero-win/` on the console.

The installer runs Wine as the user `prospero`, the same user the console
uses, and replaces Wine's links into your home folder with real folders inside
the prefix. Recipes, DXVK and ReShade options and the `prospero` block are
described in upstream's
[`docs/INSTALLING_GAMES.md`](https://github.com/mpereiraesaa/prospero-win/blob/main/docs/INSTALLING_GAMES.md).
Its push step works on the PS4 too: see Step 3.

### Option B: by hand (a game you already have installed)

Use this when the game is already installed somewhere (Steam, GOG or disc).
Make a prefix with the matching Wine and copy the game's files into it. The
tested titles' prefixes were made by the project's PC build of that Wine.

```sh
WINE=<path to the pinned Wine's wine>
PREFIX=~/prospero-library/prefixes/<id>

# 1. A fresh prefix, as the console's user. USER and LOGNAME make the
#    Windows user "prospero", whose folders the console uses.
mkdir -p "$PREFIX/drive_c/Games/<Name>"
USER=prospero LOGNAME=prospero WINEARCH=win64 \
WINEPREFIX="$PREFIX" WINEDEBUG=-all \
WINEDLLOVERRIDES='winemenubuilder.exe=d;mshtml=;mscoree=' \
"$WINE" wineboot --init

# 2. The game into C:\Games\<Name>.
cp -a /path/to/installed/game/. "$PREFIX/drive_c/Games/<Name>/"
```

Then:

- **Direct3D 8 to 11 games** draw through DXVK. Put DXVK 2.6.2's DLLs in the
  prefix: the release's `x32` folder in `drive_c/windows/syswow64` for a
  32-bit game, and `x64` in `drive_c/windows/system32` for a 64-bit one. Set
  them native in the profile (`dll_overrides = d3d8,d3d9,d3d10core,d3d11,dxgi=n`).
- **OpenGL games** use the Mesa Zink provider in the package. Set
  `graphics = opengl`, as `half-life.profile` does. The launcher installs the
  provider into the prefix and selects it before the game starts.
- **Game settings stored in the registry**, such as resolution: set them on
  the PC with `regedit` in the same prefix, before copying.
- Leave out launchers and updaters (the GOG Galaxy and Steam clients, EA app).
  The profile starts the game's own executable.

### Steam and other DRM

There is no Steam client on the console. Some Steam games start without it:
Half-Life 2 runs from its own files. Others refuse: Left 4 Dead 2 stops with a
message that it needs Steam, even with `steam_appid.txt` present. GOG and
other DRM-free editions are the safest choice. This project doesn't provide
ways around DRM.

## Step 3: Copy the prefix and profile to the console

Use upstream's `pw_prefix.py`, from the prospero-win folder. Put the profile
in `~/prospero-library/profiles/<id>.profile` first:

```sh
cd ~/ps4-wine/prospero-win
python3 tools/pw_prefix.py push <id> --library ~/prospero-library \
    --host <PS4 IP> --port 2121 \
    --cpu-dll .deps/wine-host/build/dlls/wowprospero/x86_64-windows/wowprospero.dll
```

This is how the tested Half-Life 2 was put on the test console, through
GoldHEN's FTP server on port 2121. What it does:

- **Copies the whole prefix and the profile.** The profile goes last, so the
  game only appears in the launcher once its files are there.
- **Handles the symbolic links.** A Wine prefix contains links, and the PS4
  app can't create or follow real ones. It keeps them in a `.pw-symlinks`
  table in each folder instead, which the push writes. One link points at your
  PC's whole filesystem (`dosdevices/z:` → `/`). That is why a general FTP
  client that follows links is a bad idea here: it would try to upload your
  entire PC.
- **Creates the console user's folders** (`drive_c/users/prospero/...`) if
  the prefix lacks them.
- **Sets the registry's 32-bit CPU setting for the console.** On the PC it is
  Wine's `wow64cpu.dll`; on the console it must be `wowprospero.dll`. The
  push changes it, and a pull changes it back.
- **Resumes.** If the push is interrupted, run it again and it carries on.
  Later pushes send only what changed (but see [Saves and settings](#saves-and-settings)
  for pushing a game that has already run).

`--cpu-dll` is required on the first push. On the PS4 the launcher checks the
prefix's CPU DLL each time it starts a game, and copies the package's own if
the file is missing or different. So any build of `wowprospero.dll` satisfies
the first push.

Input presets are not part of the push. If the profile names one
(`preset = <name>`), copy it to `/data/prospero-win/input/<name>.input` once,
for example with this repository's `scripts/ftp-put.py`:

```sh
python3 scripts/ftp-put.py <PS4 IP> 2121 src/profiles/input/<name>.input /data/prospero-win/input/<name>.input
```

⚠ **About FTP clients.** On the test console, GoldHEN's FTP server (v2.2)
crashed twice when `lftp`, a full-featured FTP client, logged in. It took
GoldHEN down with it, and the console needed a reboot. `pw_prefix.py` and this
repository's scripts have worked without trouble. If another client kills the
server as soon as it connects, the client is the likely cause, not a damaged
console.

### Saves and settings

On the console the prefix is the game's live copy: saves and settings change
there.

⚠ **`pw_prefix.py pull` and `status` don't work on the PS4.** They list
folders with the FTP command `MLSD`, which GoldHEN's server refuses (`501`).
The same goes for `push --trust-size`. A plain `push` doesn't list folders and
works.

That affects pushing the same game again:

- Once the game has run, its registry on the console has changed, so a second
  push refuses to go ahead.
- `--force` makes it push anyway. It overwrites the console's registry files
  and any file you changed on the PC, which can reset the game's settings.
- Save files only on the console are left alone, but copy anything you want to
  keep off the console first (for example with `scripts/ftp-get.py`).

### Profiles for the tested games

Profiles for the tested games are in [`src/profiles`](../src/profiles), and
the input presets they use are in
[`src/profiles/input`](../src/profiles/input). Each profile's comments say
which edition it was tested with and where the game's files go. The paths in
`executable` and `working_directory` must match where you put the game in
`drive_c`.

## Step 4: Start the game

Start the app and pick the game. The app restarts into it, so the screen goes
black or shows the loading dots for a while. That is normal:

| Game | Start on the test console |
|---|---|
| Half-Life 2 | ~67 s to the menu, ~50 s on later starts |
| Grand Theft Auto IV | slower to load than the other tested titles |

The dots may flash a few times while the game loads. Quitting from the game's
own menu returns you to the launcher 3 to 7 seconds later.

## Writing a profile for a new game

Start from the tested profile closest to your game. Half-Life 2's is a good
template for a 32-bit Direct3D 9 game:

```ini
[application]
id = half-life-2                     ; matches the file name and the prefix
name = Half-Life 2                   ; shown in the launcher
executable = C:\Games\HalfLife2\hl2.exe
working_directory = C:\Games\HalfLife2
arguments = -game hl2 -novid -fullscreen -w 1920 -h 1080
dll_overrides = d3d8,d3d9,d3d10core,d3d11,dxgi=n
prefix = half-life-2                 ; the folder under prefixes/
runtime = wine-wow64
architecture = pe32                  ; pe32 for a 32-bit exe
graphics = dxvk                      ; dxvk, opengl, gdi or auto

[display]
desktop = 1920x1080
; scaling = fit                      ; fit, integer or stretch

[input]
mode = xinput                        ; xinput (controller) or keyboard
options = escape                     ; Options opens the game's menu
mouse = touchpad                     ; none, left_stick, right_stick, touchpad
mouse_speed = 400
touchpad = mouse_left

[runtime]
cpu = native                         ; the default; translator only if native fails
```

- **`cpu`**: 32-bit games run on the native WoW64 backend by default.
  `cpu = translator` uses prospero-win's x86 translator instead. Of the tested
  games only MDK needs it, and Titan Quest crashes on it.
- **Input**: `mode = xinput` passes the controller to games that support one.
  `mode = keyboard` maps it to keys and the mouse for games that don't. The
  [README](../README.md#profiles) lists the mouse and touchpad options.
- **`[debug] winedebug`** picks Wine's log channels for this game, for
  example `winedebug = err+all,warn+module`. Heavy tracing slows the game
  down a lot: Titan Quest was choppy until its tracing was turned off.

## Troubleshooting

### Get the log first

Almost every failure shows up in the app's log, and reading it is faster than
guessing.

**On the console (no setup).** The app writes a log for each session to
`/data/prospero-win/logs/` whether or not anything else is set up:

- `session-0.log` to `session-7.log`, used in turn. `next.txt` holds the
  number of the *next* session. The launcher and each game are separate
  sessions, because the app restarts between them.
- The first line names the session, for example
  `PW_REPORT/1 build=GLDS10043-01.38-... profile=half-life-2 ...`. Look for
  the one whose `profile=` is your game.
- When a session's log fills, the older part moves to
  `session-N.previous.log`.

Close the app first: the console refuses to hand over a log the app still has
open. Then fetch it:

```sh
python3 scripts/ftp-get.py <PS4 IP> 2121 /data/prospero-win/logs/next.txt next.txt
python3 scripts/ftp-get.py <PS4 IP> 2121 /data/prospero-win/logs/session-3.log session-3.log
```

The repository's `scripts/pull-ps5log.py` fetches them all at once, but it
logs in to FTP (see the warning in Step 3), so prefer `ftp-get.py`.

**Live, on a PC.** To watch the log as it happens, put a
`/data/prospero-win/dev.conf` on the console:

```text
DEV_ENABLED=1
DEV_SERVER=<your PC's IP>
DEV_PORT=9300
```

Then run `python3 scripts/ps5logd.py 9300` on that PC before starting the app.
It prints each line and saves it under `build-ps4-logs/`. When it works, the
first lines include `--- connected from ... ---` and
`PW_WINE64 log enabled by /data/prospero-win/dev.conf after the /data grant`.

- **A wrong IP fails silently.** The app can't connect, carries on as
  normal and sends nothing. If nothing arrives, check `DEV_SERVER` and the
  PC's firewall first.
- Delete `dev.conf` when you're done. While it exists, every launch logs.
- Neither log can be written until the app has access to `/data`, a fraction
  of a second after it starts. Lines logged before that are held and written
  once it has access. Only a crash in that first moment leaves no log at all.

**The console's kernel log.** This is system-level, and needed only for deep
problems: GoldHEN serves it on port 3232. `scripts/watch-klog.sh` records it.

### Read the log: how far did it get?

The launcher and game start write these lines in order. The last one you find
shows roughly where things stopped:

| Line | Meaning |
|---|---|
| `PW_WINE64 data_mount ... root=/data/prospero-win` | The app can read `/data`. `root=unavailable` means it can't, and nothing else will work. |
| `PW_WINE64 profile refused file=<f> status=<s>` | That profile has an error and isn't listed. See below. |
| `PW_WINE64 library status=ok ... games=<n>` | How many profiles the launcher accepted. |
| `PW_WINE64 launcher chose=<id>` | You picked a game. The app restarts into it. |
| `PW_WINE64 cpu=native backend=wow64native.dll prefix_cpu=<n>` | The CPU backend. `prefix_cpu` is 1 when it was copied into the prefix, 0 when it was already there, and -1 when the copy failed. |
| `PW_WINE64 profile id=<id> prefix=... input=ok preset=...` | The profile as loaded. `input=` other than `ok` means the input section or preset was rejected. |
| `PW_WINE64 prefix temp folders=<n>` | The temp folders the prefix names were created. |
| `PW_WINE64 ntdll=... prefix=... exe=C:\...` | Wine is starting this executable. |
| `WINE wow64: CPU L"wow64native.dll" from WINE_PS5_WOW64_CPU` | Wine is running and the 32-bit backend loaded. |
| `WINE ...:err:...` | Wine's own errors. Many are harmless; the ones just before a stop are the interesting ones. |
| `PW_EXCEPTION32 tid=... eip=...` | The 32-bit game itself crashed at that address. |
| `PW_WINE64 game setup failed reason=<r>` | The launcher couldn't set the game up and went back to the launcher. |
| `PW_WINE64 exit ...` / `session_end` | The game ended and the app returned to the launcher. |

### Symptoms

**The game isn't in the launcher.**

- Check the profile is in `/data/prospero-win/profiles/` and ends in
  `.profile`.
- Look for `profile refused file=<your file>` in the launcher's session log:
  - `malformed`: a syntax error, a key given twice, or a value in the wrong
    form.
  - `unsupported`: a key or value this build doesn't know. Profiles written
    for a newer or older prospero-win can use settings this package lacks.

**The launcher shows the game, but picking it goes straight back to the
launcher.** Look in the game's session log for `game setup failed reason=`,
`input=` other than `ok` (the profile names a preset that isn't in
`/data/prospero-win/input/`), or `DLL overrides refused`.

**Loading dots forever.**

- Wait at least two minutes the first time. Some games take over a minute.
- If the game's session log stops after `ntdll=...` with no `WINE` lines, or
  shows Wine repeating the same request over and over, the prefix is most
  likely incomplete. Check that `system.reg` is a few MB, not a few hundred
  bytes, and that `drive_c/windows/system32` and `syswow64` are full of DLLs.
  Remake the prefix (Step 2) and copy all of it.
- A registry copied straight from a PC prefix can name PC paths, such as
  fonts under `Z:\home\...`. Those don't exist on the console.

**Error CE-34878-0.** This is the PS4's generic "the app crashed" code. It
doesn't say why on its own. Get the game's session log after closing the error
and read the last lines:

- `PW_EXCEPTION32` lines show where the game crashed.
- A log that ends in the middle of Wine starting points at the prefix.
- No session for the game at all means the app crashed before it could log.
  That is a setup or console difference, so report it with the details below.

**The game shows its own error dialog** (for example "Failed to load the
launcher DLL", "No access to memory location"). Wine and the game are running,
and the game hit something it couldn't handle. Check:

- that the game's files are all there and are the edition the profile was
  tested with;
- that the DLLs it needs (DXVK, Visual C++ runtimes) are in the prefix.

Some of these turned out to be bugs in the runtime: Bloodlines' messages were
fixed in 01.23. Report it if the files check out.

**"Needs Steam" or similar.** The game wants its store client running, which
the console doesn't have. See [Steam and other DRM](#steam-and-other-drm).

**Black screen, but the mouse pointer still moves.** The game is running but
has stopped presenting frames. Titan Quest did this before 01.34. The log
around the moment it went black usually names the cause. Report it with the
log.

**Text is missing or shows as boxes.** The prefix has no usable fonts. Wine's
fonts must be in `drive_c/windows/Fonts`, and the registry must point there,
not at a PC path. `scripts/stage-falloutnv-prefix.py` holds the font
registrations used for the tested Fallout prefix.

**Settings or saves are lost at exit.** The prefix lacks the
`drive_c/users/prospero` folders. Create them as in Step 3. A prefix made as
another user keeps its data under that user's name, which the console doesn't
use.

**The game runs badly or stutters.** Remove `[debug]` tracing from the
profile. Wine trace channels (`trace+...`) slow everything down. Also check
the game's own settings: the tested titles run at 1920x1080.

**Quit hangs.** Bloodlines' Quit is known to hang. Close it from the PS button
menu. For other games, report it with the log.

**Starting a game with many saves fails.** Titan Quest once ran out of file
handles when it found a large set of old saves. Deleting old saves cleared it.
The limit is under investigation.

**The controls are wrong.** Controls are set per profile (`[input]`). See the
[README](../README.md#profiles). Some games keep their own controller
settings: Half-Life 2's inverted look is `joy_inverty 1` in
`hl2/cfg/autoexec.cfg`, not a profile setting.

### Reporting a problem

Include:

1. Console model, firmware version and GoldHEN version.
2. The release you installed (alpha.N, or the build marker from the log's
   first line).
3. The game, its edition (GOG, Steam, retail) and the profile you used.
4. How you made the prefix (Option A or B), and with which Wine.
5. What you saw and when: before the launcher, after picking the game, or in
   the game.
6. The game's `session-N.log` (and `session-N.previous.log` if there is one).

Without the log, most reports can only be answered with "send the log".
