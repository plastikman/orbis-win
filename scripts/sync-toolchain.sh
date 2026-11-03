#!/usr/bin/env bash
# Copy the tracked toolchain shim into the ignored build tree, or report drift.
#   scripts/sync-toolchain.sh [--check]
set -euo pipefail
ROOT=/home/zpeirce/ps4-gladius
SRC=$ROOT/src/toolchain/prospero-clang
DST=$ROOT/build/ps4-wine-sdk/bin/prospero-clang
if [[ ${1:-} == --check ]]; then
    if cmp -s "$SRC" "$DST"; then echo "toolchain: in step"; else
        echo "toolchain: DRIFT between src/toolchain and build/" >&2
        diff -u "$SRC" "$DST" | head -40 >&2 || true
        exit 1
    fi
else
    mkdir -p "$(dirname "$DST")"
    # Cache files may be owned by the workstation UID on the NFS PVC. Unlink
    # before copying so this runner creates a file it owns and can chmod.
    cp --remove-destination "$SRC" "$DST" && chmod +x "$DST"
    echo "toolchain: src/toolchain -> build/ps4-wine-sdk/bin"
fi
