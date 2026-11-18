#!/bin/bash
# Rebuild the mesa-ps4 tree orbis-win ships, from public upstream + the pin.
#
#   scripts/restore-mesa-tree.sh <destination-dir>
#
# The src/mesa-patches-ps4 series does NOT reproduce this tree: 35 of 45 apply,
# and the failures include 0041, which defines wsi_orbis_cursor_update -- the
# symbol the RADV PRX link needs. Use this instead.
set -euo pipefail

DEST=${1:?usage: restore-mesa-tree.sh <destination-dir>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
PIN=$REPO/src/mesa-trees
UPSTREAM=https://github.com/orbis-ports/mesa-ps4.git
BASE=1a59cc147b54e3970814b37313e2f27357672e9d

mkdir -p "$DEST"; DEST=$(cd "$DEST" && pwd)
head=$(cat "$PIN/mesa-ps4-HEAD.txt")

if [ ! -d "$DEST/mesa-ps4/.git" ]; then
    echo "cloning orbis-ports/mesa-ps4 ..."
    # Blobless, then check the BASE out so its blobs are fetched in a request
    # upstream can serve; the bundle supplies the delta. A plain blobless clone
    # fails on the pinned checkout ("not our ref"), a full clone is far slower.
    git clone --filter=blob:none --no-checkout -q "$UPSTREAM" "$DEST/mesa-ps4"
fi
cd "$DEST/mesa-ps4"
git cat-file -e "$BASE" || { echo "base $BASE not found upstream" >&2; exit 1; }
git checkout -q --detach "$BASE"
# The bundle's only ref is HEAD; a 'refs/*' refspec matches nothing and fetches
# silently, leaving a repo that cannot check out the pin.
git fetch "$PIN/mesa-ps4-delta.bundle" "HEAD:refs/pins/mesa-ps4"
git cat-file -e "$head" || { echo "bundle did not deliver $head" >&2; exit 1; }
git checkout -q --detach "$head"
git remote set-url origin "$UPSTREAM"
echo "mesa-ps4: restored at $(git rev-parse --short HEAD)"
