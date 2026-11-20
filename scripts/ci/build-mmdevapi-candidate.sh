#!/usr/bin/env bash
# Make a console candidate from the published, hardware-tested v0.0.6 package,
# changing only the matched 32-bit and 64-bit MMDevAPI modules.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUT=${OUT:?set OUT to a scratch output directory}
OPENSSL_LIB=${PS4_PKGTOOL_OPENSSL_LIB:-/orbis-cache/deps/openssl11/lib}
TITLE_ID=${TITLE_ID:-GLDS10043}
TITLE=${TITLE:-Orbis-Win v0.0.7}
PKG_VERSION=${PKG_VERSION:-02.16}
PKGTOOL=$ROOT/sdk/orbis-sdk-v1/sdk/bin/linux/PkgTool.Core
BASE_URL=https://github.com/plastikman/orbis-win/releases/download/v0.0.6/IV0000-GLDS10043_00-GLDS100430000000.pkg
BASE_MANIFEST_URL=https://github.com/plastikman/orbis-win/releases/download/v0.0.6/BUILD-MANIFEST.txt
BASE_SHA256=2a3507e34e945ebd0c57d4454118da8fbe70a8bfa9aaf6d38390101b28d6fd5b
MMDEVAPI32=$ROOT/src/runtime-pe/mmdevapi-490f6d5/mmdevapi-i386.dll
MMDEVAPI64=$ROOT/src/runtime-pe/mmdevapi-490f6d5/mmdevapi-x86_64.dll

[[ -x $PKGTOOL ]] || { echo "missing PkgTool.Core: $PKGTOOL" >&2; exit 1; }
[[ -f $OPENSSL_LIB/libssl.so.1.1 ]] || { echo "missing OpenSSL 1.1 under $OPENSSL_LIB" >&2; exit 1; }
[[ $(sha256sum "$MMDEVAPI32" | cut -d' ' -f1) == \
   ba4fa55c0b70c803492368b63cd4248c329d4ca1789701e5c00e4fad0f86c88d ]] || {
  echo "unexpected 32-bit MMDevAPI payload" >&2; exit 1;
}
[[ $(sha256sum "$MMDEVAPI64" | cut -d' ' -f1) == \
   765bda2ffbe01dc191b72aac3a8b61137ef6a6d7018df84e6d296d1aa5709b80 ]] || {
  echo "unexpected 64-bit MMDevAPI payload" >&2; exit 1;
}

mkdir -p "$OUT"
BASE_PKG=$OUT/v0.0.6.pkg
BASE_MANIFEST=$OUT/v0.0.6-BUILD-MANIFEST.txt
curl -fL --retry 3 "$BASE_URL" -o "$BASE_PKG"
[[ $(sha256sum "$BASE_PKG" | cut -d' ' -f1) == "$BASE_SHA256" ]] || {
  echo "downloaded v0.0.6 package hash does not match the released baseline" >&2; exit 1;
}
curl -fL --retry 3 "$BASE_MANIFEST_URL" -o "$BASE_MANIFEST"
BASE_RUNTIME_MARKER=$(sed -n 's/^runtime_build_marker=//p' "$BASE_MANIFEST" | head -1)
[[ -n $BASE_RUNTIME_MARKER ]] || { echo "v0.0.6 manifest lacks a runtime marker" >&2; exit 1; }

export LD_LIBRARY_PATH="$OPENSSL_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export DOTNET_BUNDLE_EXTRACT_BASE_DIR=${DOTNET_BUNDLE_EXTRACT_BASE_DIR:-$OUT/dotnet-extract}
mkdir -p "$DOTNET_BUNDLE_EXTRACT_BASE_DIR"
EXTRACT=$OUT/extracted
"$PKGTOOL" pkg_extract --passcode 00000000000000000000000000000000 "$BASE_PKG" "$EXTRACT"
BASE_STAGE=$(find "$EXTRACT" -type f -name eboot.bin -print -quit | xargs -r dirname)
[[ -n $BASE_STAGE && -f $BASE_STAGE/win/wine/lib/wine/i386-windows/mmdevapi.dll && \
   -f $BASE_STAGE/win/wine/lib/wine/x86_64-windows/mmdevapi.dll ]] || {
  echo "could not locate the complete extracted v0.0.6 application payload" >&2; exit 1;
}

python3 "$ROOT/scripts/repackage-orbis-ab.py" \
  --base-stage "$BASE_STAGE" --out-dir "$OUT/package" \
  --title-id "$TITLE_ID" --title "$TITLE" --version "$PKG_VERSION" \
  --icon "$ROOT/assets/icon0.png" \
  --replace "win/wine/lib/wine/i386-windows/mmdevapi.dll=$MMDEVAPI32" \
  --replace "win/wine/lib/wine/x86_64-windows/mmdevapi.dll=$MMDEVAPI64"
STAGE=$OUT/package/pkg-stage
PKG=$OUT/package/IV0000-GLDS10043_00-GLDS100430000000.pkg
[[ -f $PKG ]] || { echo "repackaging did not produce the expected installer" >&2; exit 1; }

python3 -I "$ROOT/scripts/check-ps4-package-parity.py" "$BASE_STAGE" "$STAGE" \
  | tee "$OUT/parity.txt"
"$PKGTOOL" pkg_validate "$PKG" | tee "$OUT/pkg_validate.txt"
if grep -qvE '^(\[OK\]|$)' "$OUT/pkg_validate.txt"; then
  echo "pkg_validate reported a non-OK line" >&2; exit 1
fi
{
  echo "release_version=0.0.7-candidate"
  echo "base_package=v0.0.6"
  echo "base_package_sha256=$BASE_SHA256"
  echo "console_version=$PKG_VERSION"
  echo "package=$(basename "$PKG")"
  echo "package_sha256=$(sha256sum "$PKG" | cut -d' ' -f1)"
  echo "runtime_build_marker=$BASE_RUNTIME_MARKER"
  echo "runtime_source_commit=$(sed -n 's/^runtime_source_commit=//p' "$BASE_MANIFEST" | head -1)"
  echo "icon_sha256=$(sha256sum "$ROOT/assets/icon0.png" | cut -d' ' -f1)"
  echo "mmdevapi32_sha256=$(sha256sum "$MMDEVAPI32" | cut -d' ' -f1)"
  echo "mmdevapi64_sha256=$(sha256sum "$MMDEVAPI64" | cut -d' ' -f1)"
  echo "wine_patch=src/wine-patches-ps4/1036-mmdevapi-keep-persisted-audio-names.patch"
  echo "wine_patch_source_commit=490f6d5dcbb2a5047345b8af88d114bbcaad69a8"
  echo "root_commit=$(git -C "$ROOT" rev-parse HEAD)"
} > "$OUT/BUILD-MANIFEST.txt"
cat "$OUT/BUILD-MANIFEST.txt"
