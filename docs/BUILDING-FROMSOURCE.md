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

    scripts/restore-wine-trees.sh <dir>          # from ps4-gladius/src/wine-trees
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

    PROSPERO_WINE_PREPATCHED=1 PW_PRX_LINK=1 \
      sh prospero-win/tools/build_wine_ps5.sh --sdk "$PWD/build/ps4-wine-sdk"

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

    git clone https://github.com/orbis-ports/mesa-ps4.git mesa-build/mesa-ps4
    git -C mesa-build/mesa-ps4 checkout --detach 1a59cc1

The `src/mesa-patches-ps4` series does **not** reproduce the shipped tree either
(35 of 45 apply; the failures include `0041`, which defines
`wsi_orbis_cursor_update` — the symbol the RADV PRX link needs). Apply the
pinned delta instead, as for Wine.

    ORBIS_COMPAT_DIR="$PWD/sdk/orbis-sdk-v1/orbis-compat" \
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
