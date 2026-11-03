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
[[ -f "$CACHE/sce_module/libc.prx" && -f "$CACHE/sce_module/libSceFios2.prx" ]] || {
  echo "missing private Sony firmware modules under $CACHE/sce_module" >&2; exit 1;
}
[[ -f "$CACHE/openssl11/lib/libssl.so.1.1" ]] || {
  echo "missing cached OpenSSL 1.1 libraries under $CACHE/openssl11/lib" >&2; exit 1;
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

link_cache "$CACHE/prospero-win" "$ROOT/prospero-win"
link_cache "$CACHE/mesa-build" "$ROOT/mesa-build"
link_cache "$CACHE/build" "$ROOT/build"
link_cache "$CACHE/sce_module" "$ROOT/sce_module"
mkdir -p "$ROOT/sdk"
link_cache "$CACHE/sdk/orbis-sdk-v1" "$ROOT/sdk/orbis-sdk-v1"

# Cache was seeded by a separate Kubernetes pod and may have another UID.
git config --global --add safe.directory "$CACHE/prospero-win"
git config --global --add safe.directory "$CACHE/mesa-build/mesa-ps4"

echo "cache manifest:"
cat "$CACHE/manifest.txt"
echo "linked cached PS4 SDK, Wine, Mesa/RADV, and firmware inputs"
