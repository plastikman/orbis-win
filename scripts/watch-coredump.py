#!/usr/bin/env python3
"""Continuously capture named PS4 coredumps from an already-running klog file.

Usage: scripts/watch-coredump.py HOST PORT KLOG LOCAL_DIR TITLE_ID

The watcher tails only the local klog and performs RETR on each exact coredump
path GoldHEN announces. It never lists or probes FTP paths. GoldHEN reports the
path before coredump.elf finishes writing it, so retrieval retries for up to
20 seconds to span the dump-write interval and cleanup window. It stays alive
after a capture so a rapid second crash is not missed.
"""

import re
import subprocess
import sys
import time
from pathlib import Path


PATTERN = re.compile(r"coredump\.path,name,mode=\{([^,}]+),([^,}]+),")


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2

    host, port, klog_name, out_dir, title_id = sys.argv[1:]
    klog = Path(klog_name)
    destination = Path(out_dir)
    destination.mkdir(parents=True, exist_ok=True)
    log_path = destination / f"coredump-watch-{title_id}-{time.strftime('%Y%m%d-%H%M%S')}.log"
    # This watcher is normally launched in the background while a console run
    # is in progress. Keep its own durable log so it survives a closed terminal
    # or app-server pipe; otherwise the first status print can raise
    # BrokenPipeError exactly when the crash notification arrives.
    log_stream = log_path.open("a", encoding="utf-8", buffering=1)
    sys.stdout = log_stream
    sys.stderr = log_stream
    print(f"watch log: {log_path}", flush=True)
    offset = klog.stat().st_size
    print(f"watching {klog} from byte {offset} for {title_id}", flush=True)

    while True:
        try:
            with klog.open("rb") as stream:
                stream.seek(offset)
                chunk = stream.read()
                offset = stream.tell()
        except FileNotFoundError:
            chunk = b""

        for raw in chunk.splitlines():
            line = raw.decode("utf-8", "replace")
            if title_id not in line:
                continue
            match = PATTERN.search(line)
            if not match:
                continue

            remote_dir, filename = match.groups()
            remote = f"{remote_dir.rstrip('/')}/{filename}"
            local = destination / filename
            print(f"coredump announced: {remote}; retrieving", flush=True)
            deadline = time.monotonic() + 20.0
            attempt = 0
            result = None
            while time.monotonic() < deadline:
                attempt += 1
                result = subprocess.run(
                    [sys.executable, "scripts/ftp-get.py", host, port, remote, str(local)],
                    check=False, capture_output=True, text=True,
                )
                if result.returncode == 0:
                    print(result.stdout, end="", flush=True)
                    print(f"RETR succeeded on attempt {attempt}: {local}", flush=True)
                    break
                time.sleep(0.2)

            else:
                if result:
                    print(result.stdout, end="", flush=True)
                    print(result.stderr, end="", file=sys.stderr, flush=True)
                print(f"RETR failed after {attempt} attempts: {local}; continuing to watch", flush=True)

            if result and result.returncode != 0:
                # The path was announced but GoldHEN cleaned it up before RETR
                # succeeded. Keep monitoring for the next crash rather than
                # exiting after a missed dump.
                continue

        time.sleep(0.05)


if __name__ == "__main__":
    raise SystemExit(main())
