# Building orbis-win from source, on any machine

Verified 2026-11-17 on a Debian 13 laptop that is **not** the build host: a
fresh public clone, no cache, produced
`IV0000-GLDS10043_00-GLDS100430000000.pkg` (507 MB) and
`scripts/check-ps4-package-parity.py` exited **0** (19 PASS, 0 FAIL).

`docs/BUILDING.md` describes the older pre-MDK route and no longer works: it
pins `mpereiraesaa/prospero-win` 404cac6 + patch 0300, while shipped packages
are built the ABI-4 way. Use this file.

## 0. Host packages

    sudo apt-get install -y clang lld llvm cmake ninja-build glslang-tools lftp \
        gcc-mingw-w64-x86-64 gcc-mingw-w64-i686 nix-setup-systemd
    sudo usermod -aG nix-users "$USER"      # log out and back in
    echo "experimental-features = nix-command flakes" | sudo tee -a /etc/nix/nix.conf
    sudo systemctl restart nix-daemon

`scripts/prereqs.sh` checks only the first line. mingw and nix are needed too:
Mesa's build deps come from `nix develop nixpkgs#mesa` and the check is fatal.
Clang 19 is the validated version (19.1.7 here).

## 1. SDK bundle (public, checksummed)

    ./scripts/fetch-sdk.sh

~92 MB from `orbis-ports/orbis-porting-kit`, tag `orbis-sdk-v1`. It verifies its
own checksum and runs `verify.sh`, which checks that its Mesa and orbis-compat
were built as a pair. Do not assemble those three yourself.

## 2. prospero-win, and the Wine trees

    git clone https://github.com/plastikman/prospero-win.git prospero-win

**Do not use the patch series to build the Wine trees** — it cannot reproduce
them (157/112/40 of 310 present/absent/partial, and `--check-patches` fails
outright). Restore the pinned trees instead:

    scripts/restore-wine-trees.sh <dir>          # pins in src/wine-trees/
    cp -a <dir>/wine-ps5  prospero-win/.deps/wine-ps5/source
    cp -a <dir>/wine-host prospero-win/.deps/wine-host/source

Seed the pristine checkout the host tools build from:

    git clone --no-checkout https://gitlab.winehq.org/wine/wine.git \
        prospero-win/.deps/wine/source
    git -C prospero-win/.deps/wine/source checkout --detach \
        490f6d5dcbb2a5047345b8af88d114bbcaad69a8

## 3. Toolchain support archives

    ./scripts/prepare-ps4-toolchain.sh

Produces `libwineshim.a`, `libps4stubs.a`, the 16-bit-wchar archive and the
module-parameter object under `build/ps4-wine-sdk/`.

Then link the LLVM tools the Wine build calls through the SDK (only
`scripts/ci/prepare-runner.sh` did this, by hand):

    cd build/ps4-wine-sdk/bin
    for t in llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-readelf llvm-strip; do
        ln -sfn "$(command -v $t || command -v $t-19)" $t
    done
    ln -sfn "$(command -v ld.lld || command -v ld.lld-19)" orbis-ld

## 4. Wine

    sh prospero-win/tools/build_wine_runtime.sh --jobs "$(nproc)"

    PW_ORBIS_COMPAT=<pin> PROSPERO_WINE_PREPATCHED=1 PW_PRX_LINK=1 \
      sh prospero-win/tools/build_wine_ps5.sh --sdk "$PWD/build/ps4-wine-sdk"

`PW_ORBIS_COMPAT` is **required** here, even though §8b presents it as optional:
`prospero-clang` refuses to build without a correct orbis-compat, so the command
without it stops at "no orbis-compat at .../mesa-build/orbis-compat".

`PW_PRX_LINK=1` is **required**: without it the shim appends its stand-in
`libwineshim.a` while the script already puts prospero-win's real wine/ps5 units
on the line, and every shim entry is defined twice.

    PROSPERO_WINE_PREPATCHED=1 sh prospero-win/tools/build_host_wine.sh \
      --work "$PWD/prospero-win/.deps/wine-host" --jobs 4

`PROSPERO_WINE_PREPATCHED=1` is **not optional** here: without it the script runs
`git clean -fdx` on the tree and destroys the pinned delta.

`secur32.so` is absent by design unless you build the static GnuTLS first
(`tools/build_tls_ps5.sh`).

## 5. wow64native and wowprospero

    make -C prospero-win/.deps/wine/build -j"$(nproc)" dlls/ntdll/ntdll.so \
      dlls/wow64/x86_64-windows/libwow64.a dlls/ntdll/x86_64-windows/libntdll.a \
      libs/winecrt0/x86_64-windows/libwinecrt0.a libs/compiler-rt/x86_64-windows/libcompiler-rt.a

    sh prospero-win/tools/build_wow64native.sh \
      --source prospero-win/.deps/wine/source --build prospero-win/.deps/wine/build \
      --output "$PWD/wow64native-out"

    sh prospero-win/tools/build_wowprospero.sh \
      --build prospero-win/.deps/wine-host/build --source prospero-win/.deps/wine-host/source
    x86_64-w64-mingw32-strip \
      -o prospero-win/.deps/wine-host/install/usr/lib/wine/x86_64-windows/wowprospero.dll \
      prospero-win/.deps/wine-host/build/dlls/wowprospero/x86_64-windows/wowprospero.dll

## 6. Mesa / RADV

The `src/mesa-patches-ps4` series does **not** reproduce the shipped tree either
(35 of 45 apply; the failures include `0041`, which defines
`wsi_orbis_cursor_update` — the symbol the RADV PRX link needs). Use the pin:

    scripts/restore-mesa-tree.sh "$PWD/mesa-build"   # pins in src/mesa-trees/

    ORBIS_COMPAT_DIR="$PWD/sdk/orbis-sdk-v1/orbis-compat"   # ⚠ the BUNDLE, on purpose — see §8c \
    OO_PS4_TOOLCHAIN="$PWD/sdk/orbis-sdk-v1/sdk" \
      bash mesa-build/mesa-ps4/ps4/build.sh

## 7. PRX modules

    sh scripts/prx-ps4.sh
    sh scripts/freetype-prx-ps4.sh
    PW_RADV_MESA_SRC="$PWD/mesa-build/mesa-ps4" \
    PW_RADV_MESA_BUILD="$PWD/mesa-build/mesa-ps4/build-orbis" sh scripts/radv-prx-ps4.sh
    sh scripts/wineps5-prx-ps4.sh

Fourteen modules: ntdll, win32u, wineserver, winevulkan, opengl32, ws2_32,
crypt32, dwrite, xinput1_3, libfreetype, libvulkan, wineps5, wowprospero,
wow64native.

## 8. Mesa Zink (OpenGL titles)

`tools/build_mesa_zink.md` has the pins. Without it the parity gate FAILS with
"Mesa Zink OpenGL provider missing" and every `graphics = opengl` title is
refused at startup.

## 8b. orbis-compat (REQUIRED)

Every PRX links `liborbis-compat-16bit-wchar.a`, which
`prepare-ps4-toolchain.sh` takes from the fetched SDK bundle by default. A
different copy changes the bytes of every module, so the script now prints its
hash. To link the one older packages used, see `src/orbis-compat-pin/` and pass:

    PW_ORBIS_COMPAT=/path/to/orbis-compat ./scripts/prepare-ps4-toolchain.sh

⚠ **The bundle's copy is NOT fine, even though it passes the gate.** It predates
the `include/signal.h` delta, so `SIG_UNBLOCK` compiles to Linux's `1` —
`SIG_BLOCK` to libkernel — and Wine's native-frame probe blocks the signal it
sends itself. `wow64native` then reports `STATUS_NOT_SUPPORTED` (`c00000bb`) and
Wine drops to the `wowprospero` translator silently. Measured on hardware
2026-11-17; the gate reported 19 PASS / 0 FAIL on exactly such a package.
`prospero-clang` now fails loudly instead of falling back.

## 9. Console modules

Copy `libc.prx` and `libSceFios2.prx` from a console you own into `sce_module/`.
They are not redistributed.

## 10. Package

**Pass the ABI and the hash pair explicitly.** `build-app-ps4.sh` still defaults
to `WOW64NATIVE_ABI=3` with a stale pair; this project is ABI-4 only, and its
ABI-4 defaults are stale too. From-source builds have their own hashes, which is
expected — compute them and pass them.

    TITLE_ID=GLDS10043 \
    PKG_OUT=<out> PW_BUILD_ID=<id> \
    PW_MESA_ZINK_DIR=<zink artifacts> \
    WOW64NATIVE_ABI=4 \
    WOW64NATIVE_DLL=<out>/wow64native-out/x86_64-windows/wow64native.dll \
    WOW64NATIVE_ABI4_SHA256=$(sha256sum .../wow64native.dll | cut -d' ' -f1) \
    WOW64NATIVE_ABI4_PRX_SHA256=$(sha256sum .../wow64native.prx | cut -d' ' -f1) \
      ./scripts/build-relocatable-wine-ps4.sh

⚠ `TITLE_ID` defaults to **GLDS10044**, the promoted baseline slot. Always set it.

## 11. The gate — this is what decides it

    scripts/check-ps4-package-parity.py <known-good stage> <your pkg-stage> \
      --elf-dir prospero-win/.deps/wine-ps5/prx --upstream-root prospero-win

Exit 0 or do not install.

## Known warnings

The gate reports WARNs for PS4-specific `orbis_*` strings present in a baseline
built against a locally-built orbis-compat but absent from one built against the
bundle's. They need a written disposition, not a fix.

## Iterating without rebuilding everything

A cold build is hours. You almost never need one. **Wine is not rebuilt when you
change this repository's code** — the PRX link is, and that is minutes.

Measured on a 6-core laptop, 2026-11-17:

| you changed | run | cost |
|---|---|---|
| `src/native/`, `src/reloc-wine-app/`, a PRX script | `prepare-ps4-toolchain.sh` + `prx-ps4.sh` + the package | **~13 min** |
| nothing (repackage, e.g. to add `PS4_DEV_CONF`) | the package step | ~8 min |
| a Mesa pin | `restore-mesa-tree.sh` + its build + `radv-prx-ps4.sh` | ~25 min |
| a Wine pin | `build_wine_ps5.sh` (+ `build_host_wine.sh` for PE) | ~20 / ~40 min |
| the SDK bundle | all of it | hours |

So the normal loop is:

    ./scripts/prepare-ps4-toolchain.sh && sh scripts/prx-ps4.sh && <package>

`scripts/ci/prepare-from-source.sh` does this for you: each step is stamped on
the pins and sources it depends on, so a warm runner skips what has not moved.
The PRX link is never stamped — it is cheap, and a stale PRX is the failure this
project has shipped most. Delete `.ci-from-source` to force a cold build.

⚠ Do not widen that skipping casually. The stamp for the toolchain archives must
cover `src/native/*.c` and prospero-win's `wine/ps5/*.c`, not just the shim; keyed
too narrowly, a source change is silently skipped and the build ships the
previous objects.

## Reproducible output

The build embeds its own absolute path: Wine's `__FILE__` strings put the source
directory into every module (10 of them in `ntdll.prx`). Two checkouts at
different paths therefore produce different bytes from identical sources. Map
the checkout to a fixed stand-in so output does not depend on where you built:

    PW_FILE_PREFIX_MAP="$PWD/prospero-win/.deps/wine-ps5/source=/orbis-win"

Measured: the toolchain is otherwise **deterministic** — two builds of identical
input are byte-identical.

## If you are picking this up to contribute

The build does not need the original build host, and these are the places it
will fight you, all of them already fixed on this branch:

* Four inputs that no patch series reproduces — `wine-ps5`, `wine-host`,
  `mesa-ps4` and `orbis-compat`. Pins and restore scripts are in `src/`.
  **Re-pin after you change any of them**; a stale pin lies.
* A green build proves nothing. `prx-ps4.sh` and friends assemble from whatever
  objects exist. Verify content (`strings`, `sha256sum`) in `pkg-stage`.
* The parity gate is the decision. Exit 0 or do not install. Its WARNs are not
  cosmetic — one of them was an unpinned orbis-compat for weeks.

## What you must supply yourself

Everything else in this file is public and fetched by the steps above. Three
things are not in this repository and cannot be:

1. **`sce_module/libc.prx` and `libSceFios2.prx`** — Sony modules, from a
   console you own (step 9). Not redistributable.
2. **A known-good package stage** for the parity gate's baseline (step 11).
   Unpack a published release, or use a stage you have already validated.
3. **Host packages and nix** (step 0), which need root.

Everything else — the SDK bundle, prospero-win, upstream Wine, mesa-ps4,
PS5_Mesa, llvm-mingw — comes from a public URL pinned by commit or SHA-256.

## What was verified, and what was not

Verified 2026-11-17 on a Debian 13 laptop that is not the build host:
every step above ran, and `check-ps4-package-parity.py` exited 0 (19 PASS,
0 FAIL) on the resulting package, which was then uploaded to the GLDS10043
test slot.

**Not** verified: nobody has launched that package on a console, and nobody
other than its author has followed this file end to end. The gate is evidence
that the build is correct, not that the instructions are complete. The first
person to follow this file should treat it as a validation run and fix what
they trip over here.


## 8c. RADV is the one module that must NOT use the pin

Measured on hardware 2026-11-17, Fallout: New Vegas, one variable changed:

| `libvulkan.prx` built against | result |
|---|---|
| the **pin** orbis-compat | `0xc0000005 at libvulkan.so+0x16a6dba`, `frames_put=0`, spinner |
| the **bundle** orbis-compat | 0 faults, 1920x1080, 59.8 fps |

So:

* `libvulkan.prx` (RADV) -> **bundle** orbis-compat (114,252 B)
* every other PRX -> **pin** orbis-compat (190,196 B)

and each module must be **consistent**: the headers it compiles against and the
archive it links must come from the same orbis-compat. The pin's `include/signal.h`
fix is what lets Wine's native-frame probe pass, so `ntdll` needs it; RADV does not
care about the signal ABI and faults against the pin. The working packages always
shipped this split — by accident of a five-week-old staged archive, not on purpose.

⚠ **The PRX link reads the STAGED archive**, `build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a`,
not `PW_ORBIS_COMPAT`. That variable steers only the executable link and the
toolchain guard. `scripts/ci/prepare-from-source.sh` now stages the bundle for the
RADV link and puts the pin back immediately after; override the choice with
`PW_RADV_ORBIS_COMPAT`.

### orbis-porting-kit comes with the SDK bundle

`mesa-build/mesa-ps4/ps4/build.sh` needs the kit, and `scripts/fetch-sdk.sh`
already supplies it: the bundle is a release asset of **the kit's own repo**
(`orbis-ports/orbis-porting-kit`, tag `orbis-sdk-v1`) and ships
`orbis-compat/scripts/ps4/orbis-env.sh` next to the headers and the archive.
build.sh's fourth candidate is `$ORBIS_COMPAT_DIR`, so with `ORBIS_COMPAT_DIR`
pointed at the bundle the kit resolves with **nothing outside this tree** —
verified 2026-11-17 by a clean Mesa build with `ORBIS_KIT_DIR` unset, which
reproduced the shipped `libvulkan.prx` byte for byte.

⚠ The one way to break it is to point `ORBIS_COMPAT_DIR` at a pin that has no
`scripts/` (as an intermediate experiment here did): the build then stops with
"orbis-porting-kit not found". That is why `build_mesa()` uses the bundle and
sets `ORBIS_KIT_DIR` from it explicitly rather than relying on the search order.

And the reason the bundle ships them together is the bug this document is about —
`fetch-sdk.sh` says it outright: *"The bundle pins the OpenOrbis SDK, the
orbis-compat overlay and Mesa/RADV together on purpose: a Mesa built against one
header tree and linked against another is a struct-layout bug that compiles
cleanly and fails at run time."*
