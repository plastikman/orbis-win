#!/usr/bin/env bash
# Link the private, prebuilt PS4 toolchain cache into a fresh Actions checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CACHE=/orbis-cache/deps

[[ -d "$CACHE/prospero-win/.deps/wine-ps5/build" ]] || {
  echo "missing cached Wine build tree at $CACHE/prospero-win" >&2; exit 1;
}
[[ -f "$CACHE/mesa-build/mesa-ps4/build-orbis/src/amd/vulkan/libvulkan_radeon.a" ]] || {
  echo "missing cached RADV archive under $CACHE/mesa-build" >&2; exit 1;
}
[[ -f "$CACHE/sdk/orbis-sdk-v1/sdk/bin/linux/create-fself" ]] || {
  echo "missing OpenOrbis SDK under $CACHE/sdk/orbis-sdk-v1" >&2; exit 1;
}
[[ -f "$CACHE/build/orbw00053-iret-selectors-wow64native/x86_64-windows/wow64native.dll" ]] || {
  echo "missing ABI-v3 wow64native.dll build output under $CACHE/build" >&2; exit 1;
}
[[ -f "$CACHE/build/orbw00053-iret-selectors-wow64native/x86_64-unix/wow64native.prx" ]] || {
  echo "missing pinned ABI-v3 wow64native.prx under $CACHE/build" >&2; exit 1;
}
[[ "$(sha256sum "$CACHE/build/orbw00053-iret-selectors-wow64native/x86_64-unix/wow64native.prx" | cut -d' ' -f1)" == \
   e486fc5d126baa4d87fb3921dadf70b437952279ca66d3c1e7d8449ebaf5a506 ]] || {
  echo "cached ABI-v3 wow64native.prx does not match the validated hash" >&2; exit 1;
}
[[ -f "$CACHE/openssl11/lib/libssl.so.1.1" ]] || {
  echo "missing cached OpenSSL 1.1 libraries under $CACHE/openssl11/lib" >&2; exit 1;
}
# ABI-v4 build inputs (scripts/ci/build-abi4-package.sh): the synced prospero-win
# source with its wine-host build/install trees, the Unix wine-ps5 build, and
# the native WoW64 PE outputs. Their generated makefiles and the .deps/wine-ps5
# symlink embed ABI4_PATH, so that exact path is linked to the cache below.
ABI4_PATH=/home/zpeirce/codex_scratch/abi4-upstream-port-20261104
for p in source/.deps/wine-host/build source/.deps/wine-host/install/usr/lib/wine \
         build/wine-ps5/build native/x86_64-windows/wow64native.dll; do
  [[ -e "$CACHE/abi4/$p" ]] || { echo "missing cached ABI-v4 input: $CACHE/abi4/$p" >&2; exit 1; }
done
[[ -f "$CACHE/baseline-1090/pkg-stage/eboot.bin" ]] || {
  echo "missing known-good 1090 baseline stage under $CACHE/baseline-1090" >&2; exit 1;
}

link_cache() {
  local source=$1 destination=$2
  mkdir -p "$(dirname "$destination")"
  if [[ -e "$destination" && ! -L "$destination" ]]; then
    echo "refusing to replace non-symlink cache target: $destination" >&2
    exit 1
  fi
  ln -sfn "$source" "$destination"
}

# Several existing Wine makefiles and the compiler shim contain this historical
# absolute root. Keep those generated build files usable in ephemeral runners.
sudo mkdir -p /home/zpeirce
if [[ -e /home/zpeirce/ps4-gladius && ! -L /home/zpeirce/ps4-gladius ]]; then
  echo "unexpected /home/zpeirce/ps4-gladius in runner image" >&2; exit 1
fi
sudo ln -sfn "$ROOT" /home/zpeirce/ps4-gladius

sudo mkdir -p "$(dirname "$ABI4_PATH")"
if [[ -e $ABI4_PATH && ! -L $ABI4_PATH ]]; then
  echo "unexpected $ABI4_PATH in runner image" >&2; exit 1
fi
sudo ln -sfn "$CACHE/abi4" "$ABI4_PATH"

link_cache "$CACHE/prospero-win" "$ROOT/prospero-win"
mkdir -p "$ROOT/pkgout"
link_cache "$CACHE/baseline-1090" "$ROOT/pkgout/falloutnv-no-relro-kept-data-1090"
link_cache "$CACHE/mesa-build" "$ROOT/mesa-build"
link_cache "$CACHE/build" "$ROOT/build"
mkdir -p "$ROOT/sdk"
link_cache "$CACHE/sdk/orbis-sdk-v1" "$ROOT/sdk/orbis-sdk-v1"

# The validated ABI-v3 hash pair was built with LLVM/Clang 19. Route the SDK's
# cached absolute tool links to the same major version as the runner packages.
for tool in llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-readelf llvm-strip; do
  [[ -x "/usr/bin/${tool}-19" ]] || { echo "missing pinned LLVM 19 tool: $tool" >&2; exit 1; }
  ln -sfn "/usr/bin/${tool}-19" "$CACHE/build/ps4-wine-sdk/bin/$tool"
done
ln -sfn /usr/bin/ld.lld-19 "$CACHE/build/ps4-wine-sdk/bin/orbis-ld"

# Cache was seeded by a separate Kubernetes pod and may have another UID.
git config --global --add safe.directory "$CACHE/prospero-win"
git config --global --add safe.directory "$CACHE/mesa-build/mesa-ps4"
git config --global --add safe.directory "$CACHE/abi4/source"

echo "cache manifest:"
cat "$CACHE/manifest.txt"
echo "linked cached PS4 SDK, Wine, Mesa/RADV, and firmware inputs"
