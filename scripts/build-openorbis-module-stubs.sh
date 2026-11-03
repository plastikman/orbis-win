#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SDK="${OO_PS4_TOOLCHAIN:-$ROOT/sdk/orbis-sdk-v1/sdk}"
OUT="${PW_MODULE_STUBS_DIR:-$ROOT/build/openorbis-module-stubs}"

[[ -x "$SDK/bin/linux/create-fself" ]] || {
  echo "missing OpenOrbis create-fself: $SDK/bin/linux/create-fself" >&2; exit 1;
}
[[ -f "$SDK/link.x" && -f "$SDK/lib/crtlib.o" ]] || {
  echo "incomplete OpenOrbis SDK at $SDK" >&2; exit 1;
}
command -v clang >/dev/null || { echo "clang is required" >&2; exit 1; }
command -v ld.lld >/dev/null || { echo "ld.lld is required" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/build"
mkdir -p "$OUT/build"

for module in libc libSceFios2; do
  source_dir="$ROOT/src/openorbis-module-stubs/$module"
  build_dir="$OUT/build/$module"
  [[ -f "$source_dir/Makefile" && -f "$source_dir/$module/lib.c" ]] || {
    echo "missing tracked OpenOrbis stub source for $module" >&2; exit 1;
  }
  cp -a "$source_dir" "$build_dir"
  OO_PS4_TOOLCHAIN="$SDK" make -C "$build_dir" clean all
  install -m 0644 "$build_dir/$module.prx" "$OUT/$module.prx"
done

echo "OpenOrbis module stubs built from tracked GPL-3.0 sources:"
sha256sum "$OUT/libc.prx" "$OUT/libSceFios2.prx"
