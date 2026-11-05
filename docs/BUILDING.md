# Building orbis-win for PS4

This guide describes the source baseline and packaging flow used for the
pre-MDK four-title status. It targets Debian/Ubuntu x86-64 hosts and an
OpenOrbis-compatible PS4 environment. Game files, Sony firmware modules and
console activation are intentionally outside the build.

## 1. Host tools and SDK bundle

Install the checked host dependencies, then fetch and verify the paired SDK,
orbis-compat and Mesa bundle:

```sh
./scripts/prereqs.sh
./scripts/fetch-sdk.sh
```

`fetch-sdk.sh` verifies the release checksum and runs the bundle's own pairing
check. Do not mix headers, libraries, or Mesa archives from different bundles.
Install the required host packages with the command printed by
`scripts/prereqs.sh` if anything is missing.

## 2. Check out and patch prospero-win

The pre-MDK PS4 source snapshot is based on upstream commit
`404cac6ebbb236d2486d2796fd28b9bd39f2caa6` and reproduces the committed
`prospero-win` tree at `75f25351354b866e8cae8c17e828e386651ddb7e`:

```sh
git clone https://github.com/mpereiraesaa/prospero-win.git prospero-win
git -C prospero-win checkout --detach 404cac6ebbb236d2486d2796fd28b9bd39f2caa6
git -C prospero-win apply ../src/prospero-win-patches-ps4/0300-pre-mdk-source-snapshot.patch
```

The 8,058-line `0300` snapshot was checked by applying it to a clean upstream
worktree and comparing the resulting tracked tree with the pinned pre-MDK
source commit. The older `0200`–`0203` files preserve the incremental history;
do not apply them on top of `0300`.

## 3. Supply console-only modules

Copy the Sony modules listed in [`../sce_module/README.md`](../sce_module/README.md)
from a console you own into `sce_module/`. They are not redistributed here.
Keep `config.env` local and ignored; copy `config.env.example` and set the
console IP only if you plan to deploy or collect logs.

## 4. Build Wine and the PS4 modules

From the repository root, first generate the local shim archives from the
pinned upstream tree and paired SDK. This also syncs the tracked
`prospero-clang` toolchain shim into the ignored build directory. Then build
Wine's patched host and PE runtime, followed by the PS4 PRXs. Set the bundled
Mesa paths explicitly so a clean checkout does not accidentally use a local
Mesa build:

```sh
ROOT="$PWD"
PW_ROOT="$ROOT/prospero-win"
MESA_SRC="$ROOT/sdk/orbis-sdk-v1/mesa"
MESA_BUILD="$MESA_SRC/build-orbis"

./scripts/prepare-ps4-toolchain.sh
./prospero-win/tools/build_wine_ps5.sh \
  --patches "$ROOT/src/wine-patches-ps4" \
  --sdk "$ROOT/build/ps4-wine-sdk"
sh ./scripts/prx-ps4.sh
sh ./scripts/freetype-prx-ps4.sh
PW_RADV_MESA_SRC="$MESA_SRC" PW_RADV_MESA_BUILD="$MESA_BUILD" \
  sh ./scripts/radv-prx-ps4.sh
sh ./scripts/wineps5-prx-ps4.sh
```

`prepare-ps4-toolchain.sh` creates `libwineshim.a`, `libps4stubs.a`, the
16-bit-WCHAR compatibility archive, and the module-parameter object under the
ignored `build/ps4-wine-sdk/` directory. `prx-ps4.sh` clears and rebuilds its
PRX directory. Always run the FreeType, RADV and audio PRX steps afterward so
the package contains all required modules. If building against a locally
modified Mesa/orbis-compat pair, build and use both halves together; see the
notes in `scripts/build.sh` and `docs/FINDINGS.md`.

## 5. Build a relocatable package

Normal game builds must use the relocatable entry point:

```sh
./scripts/build-relocatable-wine-ps4.sh
```

The default output is under `pkgout/wine-app-relocatable/`. To give a build a
distinct test identity and output directory:

```sh
TITLE_ID=GLDS10085 \
TITLE="orbis-win test" \
PKG_OUT="$PWD/pkgout/test" \
./scripts/build-relocatable-wine-ps4.sh
```

The relocatable wrapper creates an ordinary runtime stage, adds the high
address Wine PRX, and builds the final package. Do not build a low-base package
for normal use. `PS4_KERNELBASE32_DLL` can be supplied when guest exception
diagnostics are required; see `AGENTS.md` and the crash workflow in the handoff.

## 6. Deploy and install

Set `ORBIS_CONSOLE` and the GoldHEN FTP port in the ignored `config.env`, then
upload the package to the PS4 package directory:

```sh
cp config.env.example config.env
# Edit config.env with your own console address.
./scripts/deploy.sh wine-app
```

Install the exact `.pkg` shown by the build output from the PS4 package
installer. Package deployment requires the GoldHEN FTP service to be enabled.
Start `scripts/logs.sh` and the appropriate runtime log receiver before a
diagnostic launch; use `scripts/watch-coredump.py` for dump retention. Do not
publish console IPs, firmware dumps, game files, prefixes, or generated
packages.

## Build inputs and limits

- The upstream checkout is pinned because the PS4 patch context and ABI must
  match it. A newer upstream source needs a deliberate rebase and hardware
  validation.
- The SDK bundle is fetched separately and verified by checksum.
- Game installations, save files, fonts installed from a game/prefix, and
  console-owned modules are not in this Git repository.
- The first clean build on another workstation and PS4 model should be treated
  as a validation run, not assumed to be bit-for-bit identical to the original
  workstation's package.
