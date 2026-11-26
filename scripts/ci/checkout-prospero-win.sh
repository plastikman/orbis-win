#!/usr/bin/env bash
# Check out the Prosperowin build scripts required by the PS4 native module set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REMOTE="${PW_PROSPERO_REMOTE:-https://github.com/plastikman/prospero-win.git}"
REF="${PW_PROSPERO_REF:-codex/issue8-native-parity}"
PW="${PW_PROSPERO_ROOT:-$ROOT/prospero-win}"
PIN="$(tr -d '\r\n' < "$ROOT/src/prospero-win-HEAD.txt")"

if [[ ! -e "$PW" ]]; then
    mkdir -p "$(dirname "$PW")"
    git clone -q --branch "$REF" --single-branch "$REMOTE" "$PW"
fi

if ! git -C "$PW" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "not a Prosperowin git worktree: $PW" >&2
    exit 1
fi

current="$(git -C "$PW" rev-parse HEAD)"
if [[ "$current" != "$PIN" ]]; then
    if [[ -n "$(git -C "$PW" status --porcelain --untracked-files=normal)" ]]; then
        echo "refusing to change dirty Prosperowin checkout: $PW" >&2
        echo "expected $PIN; found $current" >&2
        exit 1
    fi
    git -C "$PW" fetch -q origin "refs/heads/$REF"
    git -C "$PW" cat-file -e "$PIN^{commit}" || {
        echo "pinned Prosperowin commit $PIN is not reachable from $REF" >&2
        exit 1
    }
    git -C "$PW" checkout -q --detach "$PIN"
fi

if [[ "$(git -C "$PW" rev-parse HEAD)" != "$PIN" ]]; then
    echo "Prosperowin pin mismatch in $PW" >&2
    exit 1
fi

if [[ -n "$(git -C "$PW" status --porcelain --untracked-files=normal)" ]]; then
    echo "Prosperowin checkout must be clean for a pinned build: $PW" >&2
    exit 1
fi

echo "Prosperowin: $PIN ($PW)"
