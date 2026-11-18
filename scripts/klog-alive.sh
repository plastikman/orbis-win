#!/bin/sh
# Is the klog capture actually capturing?
#
# ⚠ An established socket to :3232 proves nothing. The receiver stalled three times on
# 2026-11-12 with the socket still ESTAB, capturing nothing, and cost two hardware runs
# (the first Hollow Knight crash and a whole startup trace). The only honest test is
# whether the FILE GREW. Run this immediately before any launch worth capturing.
#
#   scripts/klog-alive.sh <klog file> [seconds, default 12]
set -eu
log=${1:?usage: klog-alive.sh <klog file> [seconds]}
secs=${2:-12}
[ -f "$log" ] || { echo "klog-alive: no such file: $log"; exit 2; }
before=$(wc -c < "$log")
sleep "$secs"
after=$(wc -c < "$log")
grew=$((after - before))
sock=$(ss -tn 2>/dev/null | grep -c ':3232' || true)
printf 'klog %s\n  grew %d bytes in %ss, socket(s) to :3232 = %s\n' "$log" "$grew" "$secs" "$sock"
if [ "$grew" -gt 0 ]; then
    echo "  LIVE"
    exit 0
fi
echo "  NO DATA. The console may simply be idle, so confirm by making it talk:"
echo "    press PS on the console, or launch anything, then run this again."
echo "  If it is still 0 with the console active, the receiver is stalled: restart it."
exit 1
