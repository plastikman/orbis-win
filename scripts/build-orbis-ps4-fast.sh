#!/bin/sh
# Rebuild Orbis-Win's Wine PRXs and package, then upload to the console's test slot.
#
# The fast loop for an Orbis-Win-only change: Playden's own build adds ~10 minutes
# and nothing in it changes when only src/native/* moved. prx-ps4.sh is the step that
# compiles this port's native glue INTO the Wine PRXs -- skipping it links the prebuilt
# ones and silently ships a package without the change (2026-11-12: a whole build-and-
# install cycle was lost that way; `strings ntdll.prx` is the check that caught it).
#
#   scripts/build-orbis-ps4-fast.sh <build id> [marker to verify in ntdll.prx]
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
id=${1:?usage: build-orbis-ps4-fast.sh <build id> [marker]}
marker=${2:-}
release=$root/build/playden-orbis-0173/app/pkg-stage
stage=$root/pkgout/wine-app-relocatable/pkg-stage

cd "$root"
echo "== 1/4 Wine PRXs (compiles src/native into them)"
PW_ROOT=$root/worktrees/playden-ps4-0170 bash scripts/prx-ps4.sh

echo "== 2/4 link and package"
WOW64NATIVE_ABI=4 \
WOW64NATIVE_DLL=$release/win/wine/lib/wine/x86_64-windows/wow64native.dll \
WOW64NATIVE_ABI4_SHA256=e531a51bb19ae4f92e65556f0f6d4f89e930b9c7490d8a02988feb1d5ee9c044 \
WOW64NATIVE_ABI4_PRX_SHA256=20eee436ae5856f06d39b9f9fa57720806612f15e1ebea4ab15b4638da5b729d \
PW_ROOT=$root/worktrees/playden-ps4-0170 TITLE_ID=GLDS10043 PW_BUILD_ID=$id \
bash scripts/build-relocatable-wine-ps4.sh

# mesa-zink is added by the CI packaging step, not this one: without it a Playden build
# on this stage silently drops the opengl-zink capability.
cp -a "$release/win/mesa-zink" "$stage/win/" 2>/dev/null || true

if [ -n "$marker" ]; then
    n=$(strings "$stage/win/wine/lib/wine/x86_64-unix/ntdll.prx" | grep -c "$marker" || true)
    echo "== 3/4 marker '$marker' in ntdll.prx: $n"
    [ "$n" -gt 0 ] || { echo "   MARKER ABSENT -- the change is not in this package"; exit 1; }
else
    echo "== 3/4 no marker given, not verified"
fi

echo "== 4/4 upload to the GLDS10043 test slot"
python3 scripts/ftp-put.py 10.168.2.52 2121 \
    "$root/pkgout/wine-app-relocatable/IV0000-GLDS10043_00-GLDS100430000000.pkg" \
    /data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg | tail -1
sha256sum "$root/pkgout/wine-app-relocatable/IV0000-GLDS10043_00-GLDS100430000000.pkg"
