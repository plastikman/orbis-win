#!/usr/bin/env python3
"""Build a PS4 A/B package from an existing, complete package stage.

Only payload files are copied from the base stage. Replacements use
RELATIVE-PACKAGE-PATH=SOURCE-FILE and are checked against the staged output.
"""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
MAKE_PKG = ROOT / "sdk/orbis-sdk-v1/orbis-compat/scripts/ps4/make-pkg.sh"
SDK = ROOT / "sdk/orbis-sdk-v1/sdk"
REQUIRED = ("sce_module/libc.prx", "sce_module/libSceFios2.prx")
SKIP = {"eboot.bin", "pkg.gp4", "sce_sys/param.sfo", "pkg-build.log",
        "pkg-build-neo.log", "build.log"}


def digest(path: Path) -> bytes:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.digest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-stage", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--title-id", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--version",
                        help="APP_VER/VERSION for param.sfo (make-pkg.sh default: 01.00)")
    parser.add_argument("--eboot-source", type=Path,
                        help="replace the base stage EBOOT with this file")
    parser.add_argument("--replace", action="append", default=[], metavar="REL=SOURCE")
    args = parser.parse_args()
    base = args.base_stage.resolve()
    out = args.out_dir.resolve()
    if not (base / "eboot.bin").is_file():
        parser.error("base stage has no eboot.bin")
    eboot = args.eboot_source.resolve() if args.eboot_source else base / "eboot.bin"
    if not eboot.is_file():
        parser.error(f"EBOOT source missing: {eboot}")
    replacements: dict[str, Path] = {}
    for item in args.replace:
        rel, sep, source = item.partition("=")
        if not sep or not rel or not source or rel.startswith("/") or ".." in Path(rel).parts:
            parser.error(f"invalid --replace {item!r}")
        if rel in replacements:
            parser.error(f"duplicate replacement {rel}")
        replacements[rel] = Path(source).resolve()
        if not replacements[rel].is_file():
            parser.error(f"replacement source missing: {source}")
    payload: dict[str, Path] = {}
    for path in base.rglob("*"):
        if not path.is_file() or path.suffix == ".pkg":
            continue
        rel = path.relative_to(base).as_posix()
        if rel not in SKIP:
            payload[rel] = path
    for rel, source in replacements.items():
        if rel not in payload:
            parser.error(f"replacement path absent from base stage: {rel}")
        payload[rel] = source
    for rel in REQUIRED:
        if rel not in payload:
            parser.error(f"base stage lacks required platform module: {rel}")
    command = [str(MAKE_PKG), "--eboot", str(eboot),
               "--out-dir", str(out), "--title-id", args.title_id,
               "--title", args.title]
    if args.version:
        command.extend(("--version", args.version))
    for rel, source in sorted(payload.items()):
        command.extend(("--extra", f"{source}:{rel}"))
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["OO_PS4_TOOLCHAIN"] = str(SDK)
    with (out / "build.log").open("w") as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    stage = out / "pkg-stage"
    for rel, source in payload.items():
        target = stage / rel
        if not target.is_file() or digest(source) != digest(target):
            raise RuntimeError(f"package stage mismatch: {rel}")
    if digest(eboot) != digest(stage / "eboot.bin"):
        raise RuntimeError("package stage EBOOT does not match its selected source")
    print(f"Verified {len(payload)} payload files in {stage}")
    print((out / "build.log").read_text().splitlines()[-1])


if __name__ == "__main__":
    main()
