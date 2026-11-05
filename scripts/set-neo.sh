#!/usr/bin/env bash
# Set param.sfo ATTRIBUTE bit 24 (0x00800000 = 8388608) and rebuild the package.
#
# ⚠ Without this a PS4 Pro runs the title as a BASE PS4: 18 CUs, device id
# 0x9920, Liverpool. Measured on hardware 2026-10-06 (docs/FINDINGS.md).
# make-pkg.sh takes no --attribute, so the staged SFO is edited after the fact
# and the package rebuilt from the gp4 make-pkg.sh already wrote.
set -euo pipefail
OUT=$1
STAGE=$OUT/pkg-stage
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PKGTOOL="$ROOT/sdk/orbis-sdk-v1/sdk/bin/linux/PkgTool.Core"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ossl="${XDG_CACHE_HOME:-$HOME/.cache}/orbis-ports/openssl11/lib"
[[ -d $ossl ]] && export LD_LIBRARY_PATH="$ossl${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

"$PKGTOOL" sfo_setentry "$STAGE/sce_sys/param.sfo" ATTRIBUTE \
    --type Integer --maxsize 4 --value 8388608 > /dev/null
# ⚠ READ IT BACK. PkgTool.Core has exited 0 on failure before ("No usable
# version of libssl was found"), so a silent no-op here would produce a package
# that looks Neo-enabled and is not.
"$PKGTOOL" sfo_listentries "$STAGE/sce_sys/param.sfo" 2>/dev/null | grep -i attribute || true
( cd "$STAGE" && "$PKGTOOL" pkg_build pkg.gp4 . > pkg-build-neo.log 2>&1 ) ||
  { cat "$STAGE/pkg-build-neo.log" >&2; echo "neo repackage failed" >&2; exit 1; }
cp -f "$STAGE"/*.pkg "$OUT"/ 2>/dev/null || true
