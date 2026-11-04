#!/usr/bin/env python3
"""Build an independent console-ready New Vegas prefix from the generic base.

The existing Oblivion prefix is used only as a local source for Wine's base
Windows files. Game folders and user data are excluded. Registry hives come
from the console copy and are staged with the GTA-tested font registrations.
"""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = None
OUTPUT = ROOT / "build/falloutnv-prefix"
REGISTRY = ROOT / "build/falloutnv-registry"
FONTS = ROOT / "build/falloutnv-gta-fonts"
CONFIG = ROOT / "src/falloutnv-config"
USER_DIRS = (
    "AppData/Local/Temp", "AppData/LocalLow", "AppData/Roaming",
    "Contacts", "Desktop", "Documents", "Downloads", "Favorites",
    "Links", "Music", "Pictures", "Saved Games", "Searches", "Videos",
)

FONT_REGISTRY_VALUES = (
    '"Marlett (TrueType)"="C:\\\\windows\\\\Fonts\\\\marlett.ttf"',
    '"Symbol (TrueType)"="C:\\\\windows\\\\Fonts\\\\symbol.ttf"',
    '"Tahoma (TrueType)"="C:\\\\windows\\\\Fonts\\\\tahoma.ttf"',
    '"Tahoma Bold (TrueType)"="C:\\\\windows\\\\Fonts\\\\tahomabd.ttf"',
    '"Webdings (TrueType)"="C:\\\\windows\\\\Fonts\\\\webdings.ttf"',
    '"Wingdings (TrueType)"="C:\\\\windows\\\\Fonts\\\\wingding.ttf"',
)


def add_nt_font_registry_values(payload: bytes) -> bytes:
    """Expose installed TTFs to Wine's NT font registry view as GTA does."""
    text = payload.decode("utf-8")
    section = r"[Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]"
    match = re.search(rf"(?m)^{re.escape(section)}[^\n]*\n", text)
    if not match:
        raise RuntimeError("Windows NT font registry section is missing")
    end = re.search(r"(?m)^\[", text[match.end():])
    section_end = match.end() + end.start() if end else len(text)
    existing = text[match.end():section_end]
    additions = [value for value in FONT_REGISTRY_VALUES if value.split("=", 1)[0] not in existing]
    if additions:
        text = text[:section_end] + "".join(value + "\n" for value in additions) + text[section_end:]
    return text.encode("utf-8")


def load_prefix_module():
    path = ROOT / "prospero-win/tools/pw_prefix.py"
    spec = importlib.util.spec_from_file_location("pw_prefix_stage", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True,
                        help="local Wine prefix containing the generic base files")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    for path in (source, REGISTRY, FONTS, CONFIG):
        if not path.exists():
            parser.error(f"required staging input is missing: {path}")
    if output.exists():
        parser.error(f"refusing to overwrite staged prefix: {output}")

    prefix = load_prefix_module()
    files, directories, links = prefix.local_tree(source)
    output.mkdir(parents=True)

    copied = 0
    total = 0
    for relative, original in sorted(files.items()):
        if relative.startswith(("drive_c/Games/", "drive_c/users/")):
            continue
        if relative in prefix.REGISTRY:
            payload = (REGISTRY / relative).read_bytes()
            if relative == "system.reg" and b'@="wowprospero.dll"' not in payload:
                raise RuntimeError("console wowprospero.dll registry entry is missing")
            if relative == "system.reg":
                payload = add_nt_font_registry_values(payload)
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            copied += 1
            total += len(payload)
        else:
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
            copied += 1
            total += original.stat().st_size

    for relative in sorted(directories):
        if relative.startswith("drive_c/Games/") or relative.startswith("drive_c/users/"):
            continue
        (output / relative).mkdir(parents=True, exist_ok=True)

    for directory, table in links.items():
        path = output / directory / prefix.LINK_TABLE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{name}\t{target}\n" for name, target in sorted(table.items())))

    # Give New Vegas a clean Windows user tree and its own game settings.
    user_root = output / "drive_c/users/prospero"
    for relative in USER_DIRS:
        (user_root / relative).mkdir(parents=True, exist_ok=True)
    docs = user_root / "Documents/My Games/FalloutNV"
    (docs / "Saves").mkdir(parents=True, exist_ok=True)
    local = user_root / "AppData/Local/FalloutNV"
    local.mkdir(parents=True, exist_ok=True)
    for name in ("Fallout.ini", "FalloutPrefs.ini"):
        shutil.copy2(CONFIG / name, docs / name)
    shutil.copy2(CONFIG / "plugins.txt", local / "plugins.txt")

    font_dir = output / "drive_c/windows/Fonts"
    font_dir.mkdir(parents=True, exist_ok=True)
    for font in sorted(FONTS.iterdir()):
        if font.is_file() and font.suffix.lower() == ".ttf":
            shutil.copy2(font, font_dir / font.name)

    # The move destination must be absent so the known game folder can be
    # relocated there without re-uploading its 9 GiB payload.
    (output / "drive_c/Games").mkdir(parents=True, exist_ok=True)

    print(f"Staged {copied} base files ({total / 2**30:.3f} GiB)")
    print(f"Directories: {len(directories)} source dirs; skipped Oblivion game and user files")
    print(f"Wine DOS-device links: {sum(len(table) for table in links.values())} in {len(links)} tables")
    print(f"Fonts: {len(list(font_dir.glob('*.ttf')))} TTFs")
    print(f"New Vegas config staged under {docs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
