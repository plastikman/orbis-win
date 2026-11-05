#!/usr/bin/env bash
# Push a prefix, retrying across GoldHEN's FTP drop-outs.
#
# GoldHEN's FTP server does not survive a sustained transfer: the first attempt
# at Oblivion's 5.5 GB died with a broken pipe after 15 of 1920 files, with the
# server still answering afterwards. pw_prefix.py keeps a per-file manifest and
# resumes where it stopped, so the fix is simply to call it again -- each round
# makes progress, and an unchanged file is skipped by size and hash.
#
#   scripts/push-retry.sh <slug> [max-attempts]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PW=${PW_ROOT:-$ROOT/prospero-win}
SLUG=${1:-oblivion}
MAX=${2:-60}
HOST=${PS4_HOST:?export PS4_HOST with the console address}
CPU=$PW/.deps/wine/build/dlls/wowprospero/x86_64-windows/wowprospero.dll
LOG=${PUSH_LOG:-$ROOT/build-ps4-logs/prefix-push.log}
mkdir -p "$(dirname "$LOG")"

for attempt in $(seq 1 "$MAX"); do
    echo "=== attempt $attempt/$MAX  $(date +%H:%M:%S) ==="
    if python3 "$PW/tools/pw_prefix.py" push "$SLUG" --library "${PW_LIBRARY:-$HOME/prospero-library}" \
         --host "$HOST" --port "${ORBIS_FTP_PORT:-2121}" --cpu-dll "$CPU" >> "$LOG" 2>&1; then
        echo "=== push COMPLETE on attempt $attempt ==="
        exit 0
    fi
    tail -1 "$LOG" | sed 's/^/    last: /'
    # Give the server a moment to settle before reconnecting.
    sleep 10
done
echo "=== gave up after $MAX attempts ==="
exit 1
