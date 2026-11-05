#!/usr/bin/env python3
"""Stage the installed Fallout: New Vegas copy into the PS4 Wine library.

This uses GoldHEN's unauthenticated FTP server without USER/PASS, directory
listing, SIZE, or other probing commands. Upload progress is recorded locally
so a rerun can continue after a network interruption. The profile is uploaded
last so it only appears in the launcher after the game files have transferred.

    scripts/install-falloutnv.py --host "$PS4_HOST"
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = os.environ.get("FALLOUTNV_SOURCE")
REMOTE_ROOT = "/data/prospero-win/prefixes/falloutnv/drive_c/Games/FalloutNV"
REMOTE_PREFIX = "/data/prospero-win/prefixes/falloutnv"
REMOTE_FONTS = f"{REMOTE_PREFIX}/drive_c/windows/Fonts"
FONT_SOURCE = ROOT / "prospero-win/.deps/wine-host/install/usr/share/wine/fonts"
REMOTE_PROFILE = "/data/prospero-win/profiles/falloutnv.profile"
PROFILE = ROOT / "src/profiles/falloutnv.profile"
CONFIG_DIR = ROOT / "src/falloutnv-config"
REMOTE_DOCS = (
    f"{REMOTE_PREFIX}/drive_c/users/prospero/"
    "Documents/My Games/FalloutNV"
)
REMOTE_LOCALAPPDATA = (
    f"{REMOTE_PREFIX}/drive_c/users/prospero/"
    "AppData/Local/FalloutNV"
)
CONFIG_FILES = (
    (CONFIG_DIR / "Fallout.ini", f"{REMOTE_DOCS}/Fallout.ini"),
    (CONFIG_DIR / "FalloutPrefs.ini", f"{REMOTE_DOCS}/FalloutPrefs.ini"),
    (CONFIG_DIR / "plugins.txt", f"{REMOTE_LOCALAPPDATA}/plugins.txt"),
    (CONFIG_DIR / "NVTF.ini", f"{REMOTE_ROOT}/Data/NVSE/Plugins/NVTF.ini"),
)
DEFAULT_DXVK_D3D9 = os.environ.get("DXVK_D3D9_DLL")
STATE = ROOT / "build-ps4-logs/falloutnv-dedicated-upload.json"


class FTPError(RuntimeError):
    pass


class GoldHENFTP:
    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.control = socket.create_connection((host, port), timeout=30)
        self.control.settimeout(180)
        self.reader = self.control.makefile("rb")
        greeting = self.read_reply()
        if not greeting.startswith("220"):
            raise FTPError(f"unexpected greeting: {greeting}")
        self.command("TYPE I", ("200",))
        print("FTP connected; no login attempted.", flush=True)

    def read_reply(self) -> str:
        line = self.reader.readline()
        if not line:
            raise FTPError("control connection closed")
        reply = line.decode("utf-8", "replace").rstrip()
        if len(reply) > 3 and reply[3] == "-":
            code = reply[:3]
            while True:
                line = self.reader.readline()
                if not line:
                    raise FTPError("connection closed during multiline reply")
                extra = line.decode("utf-8", "replace").rstrip()
                if extra.startswith(code + " "):
                    return extra
        return reply

    def command(self, text: str, expected: tuple[str, ...] | None = None) -> str:
        self.control.sendall(text.encode("utf-8") + b"\r\n")
        reply = self.read_reply()
        if expected and not reply.startswith(expected):
            raise FTPError(f"{text}: {reply}")
        return reply

    def mkdir(self, path: str) -> None:
        reply = self.command(f"MKD {path}")
        # GoldHEN returns 550 when a directory already exists. We never list
        # or inspect it; STOR below will report any missing/unwritable parent.
        if not reply.startswith(("257", "250", "550")):
            raise FTPError(f"MKD {path}: {reply}")

    def upload(self, local: Path, remote: str, size: int) -> None:
        reply = self.command("PASV")
        if not reply.startswith("227"):
            raise FTPError(f"PASV: {reply}")
        fields = reply[reply.index("(") + 1:reply.index(")")].split(",")
        data_host = ".".join(fields[:4])
        data_port = int(fields[4]) * 256 + int(fields[5])
        data = socket.create_connection((data_host, data_port), timeout=30)
        try:
            self.command(f"STOR {remote}", ("125", "150"))
            sent = 0
            with local.open("rb") as stream:
                while True:
                    block = stream.read(1024 * 1024)
                    if not block:
                        break
                    data.sendall(block)
                    sent += len(block)
            if sent != size:
                raise FTPError(f"local file changed during upload: {local}")
        finally:
            data.close()
        reply = self.read_reply()
        if not reply.startswith("226"):
            raise FTPError(f"STOR {remote}: {reply}")

    def close(self) -> None:
        try:
            self.command("QUIT")
        except (OSError, FTPError):
            pass
        self.control.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="PS4 GoldHEN FTP address")
    parser.add_argument("--port", type=int, default=2121)
    parser.add_argument("--source", type=Path, default=Path(DEFAULT_SOURCE) if DEFAULT_SOURCE else None,
                        required=not DEFAULT_SOURCE,
                        help="local game installation (or set FALLOUTNV_SOURCE)")
    parser.add_argument("--dxvk-d3d9", type=Path,
                        default=Path(DEFAULT_DXVK_D3D9) if DEFAULT_DXVK_D3D9 else None,
                        required=not DEFAULT_DXVK_D3D9,
                        help="32-bit DXVK d3d9.dll (or set DXVK_D3D9_DLL)")
    parser.add_argument("--state", type=Path, default=STATE)
    args = parser.parse_args()

    source = args.source.resolve()
    if not source.is_dir():
        parser.error(f"game source directory not found: {source}")
    if not PROFILE.is_file():
        parser.error(f"profile not found: {PROFILE}")
    missing_config = [str(path) for path, _ in CONFIG_FILES if not path.is_file()]
    if missing_config:
        parser.error("missing staged New Vegas config files: " + ", ".join(missing_config))
    if not args.dxvk_d3d9.is_file():
        parser.error(f"32-bit DXVK d3d9.dll not found: {args.dxvk_d3d9}")

    files = sorted(path for path in source.rglob("*") if path.is_file())
    if not files:
        parser.error(f"no files under {source}")
    dirs = {REMOTE_ROOT}
    dirs.add(REMOTE_FONTS)
    for path in source.rglob("*"):
        if path.is_dir():
            rel = path.relative_to(source).as_posix()
            dirs.add(f"{REMOTE_ROOT}/{rel}")
    dirs.add(f"{REMOTE_ROOT}/Data/NVSE")
    dirs.add(f"{REMOTE_ROOT}/Data/NVSE/Plugins")
    dirs.add("/data/prospero-win/prefixes")
    dirs.add(REMOTE_PREFIX)
    dirs.add(f"{REMOTE_PREFIX}/drive_c")
    dirs.add(f"{REMOTE_PREFIX}/drive_c/Games")
    dirs.add("/data/prospero-win/profiles")
    dirs.add(f"{REMOTE_PREFIX}/drive_c/users")
    dirs.add(f"{REMOTE_PREFIX}/drive_c/users/prospero")
    dirs.add(f"{REMOTE_PREFIX}/drive_c/users/prospero/Documents")
    dirs.add(f"{REMOTE_PREFIX}/drive_c/users/prospero/Documents/My Games")
    dirs.add(f"{REMOTE_DOCS}/Saves")
    dirs.add(REMOTE_DOCS)
    dirs.add(f"{REMOTE_PREFIX}/drive_c/users/prospero/AppData")
    dirs.add(f"{REMOTE_PREFIX}/drive_c/users/prospero/AppData/Local")
    dirs.add(REMOTE_LOCALAPPDATA)

    state = {}
    try:
        state = json.loads(args.state.read_text())
    except FileNotFoundError:
        pass
    except (OSError, json.JSONDecodeError) as exc:
        parser.error(f"cannot read transfer state {args.state}: {exc}")
    completed: dict[str, dict[str, int]] = state.get("completed", {})

    client = None
    try:
        client = GoldHENFTP(args.host, args.port)
        for directory in sorted(dirs, key=lambda p: (p.count("/"), p)):
            client.mkdir(directory)

        total_bytes = sum(p.stat().st_size for p in files)
        sent_bytes = 0
        pending = []
        for local in files:
            rel = local.relative_to(source).as_posix()
            size = local.stat().st_size
            record = completed.get(rel)
            if record == {"size": size, "mtime_ns": local.stat().st_mtime_ns}:
                sent_bytes += size
            else:
                pending.append((local, rel, size))
        print(f"Files: {len(files)} ({len(pending)} to send), size: {total_bytes / 2**30:.2f} GiB", flush=True)

        last_state = time.monotonic()
        for index, (local, rel, size) in enumerate(pending, 1):
            client.upload(local, f"{REMOTE_ROOT}/{rel}", size)
            completed[rel] = {"size": size, "mtime_ns": local.stat().st_mtime_ns}
            sent_bytes += size
            if index == len(pending) or index % 10 == 0 or time.monotonic() - last_state >= 10:
                args.state.write_text(json.dumps({"completed": completed}, sort_keys=True))
                last_state = time.monotonic()
            print(f"[{sent_bytes * 100 // max(total_bytes, 1):3d}%] {rel} ({size} bytes)", flush=True)

        dxvk_size = args.dxvk_d3d9.stat().st_size
        client.upload(args.dxvk_d3d9, f"{REMOTE_ROOT}/d3d9.dll", dxvk_size)
        print(f"Installed DXVK d3d9.dll: {dxvk_size} bytes", flush=True)

        fonts = sorted(path for path in FONT_SOURCE.iterdir()
                       if path.is_file() and path.suffix.lower() == ".ttf")
        for font in fonts:
            client.upload(font, f"{REMOTE_FONTS}/{font.name}", font.stat().st_size)
        print(f"Installed Wine fonts: {len(fonts)} files", flush=True)

        for local, remote in CONFIG_FILES:
            client.upload(local, remote, local.stat().st_size)
            print(f"Installed config: {remote}", flush=True)

        profile_size = PROFILE.stat().st_size
        client.upload(PROFILE, REMOTE_PROFILE, profile_size)
        print(f"Installed profile last: {REMOTE_PROFILE}", flush=True)
    except (OSError, FTPError, socket.timeout) as exc:
        print(f"installer stopped: {exc}", file=sys.stderr)
        return 1
    finally:
        if client:
            client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
