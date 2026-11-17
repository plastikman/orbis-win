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

# ⚠ WHY NOT A FULL CLONE, AND WHY NOT A PLAIN BLOBLESS ONE.
# A full clone of Wine is ~2 GB and minutes; it was the slowest step in this
# script and in CI. A --filter=blob:none clone alone does NOT work either: the
# base commit's blobs stay lazy, so checking out a pinned HEAD sends git back to
# WineHQ asking for OUR commit and it fails with "not our ref".
#
# Checking out the BASE first materialises exactly the blobs the base needs --
# a request upstream can serve -- and the bundle then supplies the delta. The
# pinned checkout needs nothing further from the network.
#
# Measured 2026-11-17: 32 s and 201 MB per tree, against ~2 GB for a full clone,
# and the restored tree is byte-identical (0 differing paths).

for t in "${TREES[@]}"; do
    bundle=$PINS/$t-ps4-delta.bundle
    head=$(cat "$PINS/$t-HEAD.txt")
    [ -f "$bundle" ] || { echo "no pin for $t" >&2; exit 1; }

    rm -rf "$DEST/$t"
    git clone --filter=blob:none --no-checkout -q "$UPSTREAM" "$DEST/$t"
    cd "$DEST/$t"
    git checkout -q --detach "$BASE"      # materialise the base's blobs
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
