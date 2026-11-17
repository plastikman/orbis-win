#!/bin/bash
# Rebuild both Wine trees from public upstream + the pinned deltas.
#
#   scripts/restore-wine-trees.sh <destination-dir> [tree ...]
#
# Produces <destination-dir>/wine-ps5 and <destination-dir>/wine-host at the
# exact commits Orbis-Win builds from. Needs network access to WineHQ.
set -euo pipefail

DEST=${1:?usage: restore-wine-trees.sh <destination-dir> [wine-ps5|wine-host ...]}
shift || true
TREES=("$@"); [ ${#TREES[@]} -eq 0 ] && TREES=(wine-ps5 wine-host)

REPO=$(cd "$(dirname "$0")/.." && pwd)
PINS=$REPO/src/wine-trees
UPSTREAM=https://gitlab.winehq.org/wine/wine.git
BASE=490f6d5dcbb2a5047345b8af88d114bbcaad69a8

mkdir -p "$DEST"; DEST=$(cd "$DEST" && pwd)

# One shared FULL clone of upstream, reused by both trees.
#
# It must be full. A --filter=blob:none clone leaves the base commit's blobs
# lazy, so checking out a pinned HEAD sends git back to WineHQ asking for OUR
# commit -- which upstream has never heard of:
#   fatal: git upload-pack: not our ref <our sha>
# The local clones below are hardlinked off this one, so the disk cost is paid
# once (~2 GB) and no tree needs the network again.
if [ ! -d "$DEST/.upstream-wine/.git" ]; then
    echo "cloning upstream wine (full, ~2 GB, once) ..."
    git clone --no-checkout -q "$UPSTREAM" "$DEST/.upstream-wine"
fi
git -C "$DEST/.upstream-wine" cat-file -e "$BASE" \
    || { echo "base $BASE not found upstream" >&2; exit 1; }

for t in "${TREES[@]}"; do
    bundle=$PINS/$t-ps4-delta.bundle
    head=$(cat "$PINS/$t-HEAD.txt")
    [ -f "$bundle" ] || { echo "no pin for $t" >&2; exit 1; }

    rm -rf "$DEST/$t"
    git clone --no-checkout -q "$DEST/.upstream-wine" "$DEST/$t"
    cd "$DEST/$t"
    # The bundle's only ref is HEAD -- a 'refs/*' refspec matches nothing and
    # fetches silently, leaving a repo that cannot check out the pinned commit.
    git fetch "$bundle" "HEAD:refs/pins/$t"
    git cat-file -e "$head" \
        || { echo "$t: bundle did not deliver $head" >&2; exit 1; }
    git checkout -q --detach "$head"
    # Reattach to real upstream so later fetches do not depend on the scratch clone.
    git remote set-url origin "$UPSTREAM"
    echo "$t: restored at $(git rev-parse --short HEAD)"
done
