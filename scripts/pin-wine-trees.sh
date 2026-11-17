#!/bin/bash
# Re-export the Wine tree pins into src/wine-trees/.
#
#   scripts/pin-wine-trees.sh <source-root>
#
# <source-root> is the directory holding .deps/wine-ps5/source and
# .deps/wine-host/source (on the build host, the abi4-upstream-port checkout).
#
# Refuses to pin a dirty tree: a pin must capture everything, and an
# uncommitted file is exactly how the port sources went missing before.
set -euo pipefail

SRC_ROOT=${1:?usage: pin-wine-trees.sh <source-root>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/src/wine-trees
BASE=490f6d5dcbb2a5047345b8af88d114bbcaad69a8

mkdir -p "$OUT"
for t in wine-ps5 wine-host; do
    d=$SRC_ROOT/.deps/$t/source
    [ -d "$d/.git" ] || { echo "$t: no git tree at $d" >&2; exit 1; }
    cd "$d"

    dirty=$(git status --porcelain | wc -l)
    if [ "$dirty" -ne 0 ]; then
        echo "$t: $dirty uncommitted path(s) -- commit them first, a pin must be complete" >&2
        git status --porcelain | head -20 >&2
        exit 1
    fi

    git merge-base --is-ancestor "$BASE" HEAD \
        || { echo "$t: HEAD is not descended from the pinned base $BASE" >&2; exit 1; }

    git bundle create -q "$OUT/$t-ps4-delta.bundle" "$BASE..HEAD"
    # The bundle names its tip 'HEAD'; restore-wine-trees.sh fetches HEAD
    # explicitly because a 'refs/*' refspec would match nothing here.
    git bundle verify "$OUT/$t-ps4-delta.bundle" >/dev/null \
        || { echo "$t: bundle failed verify" >&2; exit 1; }
    git rev-parse HEAD > "$OUT/$t-HEAD.txt"
    echo "$t: pinned $(git rev-parse --short HEAD)  ($(du -h "$OUT/$t-ps4-delta.bundle" | cut -f1))"
done
echo "pins written to $OUT -- commit them"
