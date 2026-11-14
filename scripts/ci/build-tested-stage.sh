#!/usr/bin/env bash
# Repackage the user-tested 02.14 runtime stage for the 0.0.6 release.
# This changes the package metadata and home-screen icon while preserving every
# tested runtime file byte-for-byte. It is intentionally separate from the
# source-rebuild workflow because the 02.14 Wine PRX was recovered from the
# known-good 02.03 source plus patch 1075.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TESTED=${PS4_TESTED_STAGE_ROOT:-/orbis-cache/deps/tested-0214}
BASE="$TESTED/pkg-stage"
ELF_DIR="$TESTED/prx"
UPSTREAM_ROOT="$TESTED/upstream-root"
OUT=${OUT:?set OUT to a fresh output directory}
TITLE_ID=GLDS10043
TITLE=${TITLE:-Orbis-Win 0.0.6}
PKG_VERSION=${PKG_VERSION:-02.15}
RELEASE_VERSION=$(tr -d '\r\n' < "$ROOT/VERSION")
BUNDLE="$ROOT/sdk/orbis-sdk-v1"
ICON="$ROOT/assets/icon0.png"
MAKE_PKG="$BUNDLE/orbis-compat/scripts/ps4/make-pkg.sh"
PKGTOOL="$BUNDLE/sdk/bin/linux/PkgTool.Core"
export OO_PS4_TOOLCHAIN="$BUNDLE/sdk"

[[ $RELEASE_VERSION == 0.0.6 ]] || { echo "expected VERSION 0.0.6, got $RELEASE_VERSION" >&2; exit 1; }
[[ $PKG_VERSION =~ ^[0-9]{2}\.[0-9]{2}$ ]] || { echo "APP_VER must be NN.NN" >&2; exit 2; }
for path in "$BASE/eboot.bin" "$BASE/sce_module/relocated_wine_app.prx" \
            "$ELF_DIR/ntdll.shared.elf" "$ELF_DIR/wineserver.shared.elf" \
            "$UPSTREAM_ROOT/tools/build_wine_ps5.sh" \
            "$UPSTREAM_ROOT/.deps/wine-host/source/dlls/kernelbase/debug.c" \
            "$ICON" "$MAKE_PKG" "$PKGTOOL"; do
  [[ -s $path ]] || { echo "missing tested-stage input: $path" >&2; exit 1; }
done
grep -aFq 'GLDS10043-02.14-pw47f0cef-sampler0' \
  "$BASE/sce_module/relocated_wine_app.prx" || {
  echo "the tested input is not the verified 02.14 runtime stage" >&2; exit 1;
}

mkdir -p "$OUT/app"
EXTRA=()
while IFS= read -r -d '' file; do
  rel=${file#"$BASE/"}
  case "$rel" in
    eboot.bin|pkg.gp4|sce_sys/param.sfo|sce_sys/icon0.png|pkg-build.log|*.pkg) continue ;;
  esac
  EXTRA+=(--extra "$file:$rel")
done < <(find "$BASE" -type f -print0)

"$MAKE_PKG" --eboot "$BASE/eboot.bin" --out-dir "$OUT/app" --icon "$ICON" \
  --title-id "$TITLE_ID" --title "$TITLE" --version "$PKG_VERSION" "${EXTRA[@]}"

STAGE="$OUT/app/pkg-stage"
PKG="$OUT/app/IV0000-GLDS10043_00-GLDS100430000000.pkg"
[[ -s $PKG && -s "$STAGE/sce_sys/param.sfo" ]] || {
  echo "make-pkg did not create the expected installer and stage" >&2; exit 1;
}

# The package may differ from the tested stage only in generated package
# metadata and the requested OW icon. All executable/runtime payload must stay
# byte-identical to the stage that passed the game run.
python3 - "$BASE" "$STAGE" <<'PY'
import hashlib, os, sys

base, candidate = sys.argv[1:]
allowed = {"pkg.gp4", "pkg-build.log", "sce_sys/icon0.png", "sce_sys/param.sfo"}
def files(root):
    out = {}
    for parent, _, names in os.walk(root):
        for name in names:
            path = os.path.join(parent, name)
            rel = os.path.relpath(path, root)
            if rel == "pkg-build.log" or rel.endswith(".pkg"):
                continue
            with open(path, "rb") as f:
                out[rel] = hashlib.sha256(f.read()).hexdigest()
    return out
a, b = files(base), files(candidate)
errors = []
for name in sorted(set(a) | set(b)):
    if name in allowed:
        continue
    if a.get(name) != b.get(name):
        errors.append(name)
if errors:
    raise SystemExit("unexpected payload changes: " + ", ".join(errors))
print(f"preserved {len(set(a) | set(b)) - len(allowed)} tested payload files byte-for-byte")
PY

python3 -I "$ROOT/scripts/check-ps4-package-parity.py" "$BASE" "$STAGE" \
  --elf-dir "$ELF_DIR" --upstream-root "$UPSTREAM_ROOT" | tee "$OUT/parity.txt"

export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export DOTNET_BUNDLE_EXTRACT_BASE_DIR=${DOTNET_BUNDLE_EXTRACT_BASE_DIR:-$OUT/dotnet-extract}
export LD_LIBRARY_PATH="${PS4_PKGTOOL_OPENSSL_LIB:-/orbis-cache/deps/openssl11/lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$PKGTOOL" pkg_validate "$PKG" | tee "$OUT/pkg_validate.txt"
if grep -qvE '^(\[OK\]|$)' "$OUT/pkg_validate.txt"; then
  echo "pkg_validate reported a non-OK line" >&2; exit 1
fi

{
  echo "release_version=$RELEASE_VERSION"
  echo "console_version=$PKG_VERSION"
  echo "package=$(basename "$PKG")"
  echo "package_sha256=$(sha256sum "$PKG" | cut -d' ' -f1)"
  echo "runtime_build_marker=GLDS10043-02.14-pw47f0cef-sampler0"
  echo "source_stage_sha256=$(find "$BASE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  echo "icon_sha256=$(sha256sum "$ICON" | cut -d' ' -f1)"
  cat "$TESTED/manifest.txt"
} > "$OUT/BUILD-MANIFEST.txt"
cat "$OUT/BUILD-MANIFEST.txt"
echo "pkg: $PKG"
