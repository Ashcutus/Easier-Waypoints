#!/usr/bin/env python3
"""Build the runtime-only manual-install ZIP; never upload or publish it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

REPOSITORY = Path(__file__).resolve().parents[1]
MOD = REPOSITORY / "mod" / "easier_waypoints_1"
RUNTIME_FILES = (
    "mod.json",
    "license.txt",
    "_metadata/modinfo.json",
    "content/plugins/easier_waypoints/main.script.lua",
    "content/plugins/easier_waypoints/direction.lua",
    "content/plugins/easier_waypoints/preview.res.lua",
)


def build(output: Path) -> Path:
    version = (REPOSITORY / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("VERSION must contain the public MAJOR.MINOR.PATCH version")
    manifest = json.loads((MOD / "mod.json").read_text(encoding="utf-8"))
    info = json.loads((MOD / "_metadata/modinfo.json").read_text(encoding="utf-8"))
    if manifest["modId"] != "easier_waypoints" or type(manifest["revision"]) is not int or manifest["revision"] <= 0:
        raise ValueError("Unexpected mod identity or revision type")
    if not 0 < len(info["name"]) <= 32 or "\n" in info["name"]:
        raise ValueError("Display name must fit TF3's metadata limit")
    if not 0 < len(info["summary"]) <= 100 or "\n" in info["summary"]:
        raise ValueError("Summary must fit TF3's metadata limit")
    if not isinstance(info["description"], str) or not info["description"].strip():
        raise ValueError("Public metadata description must be nonempty")
    files = list(RUNTIME_FILES)
    for path in sorted((MOD / "_metadata").glob("*.png")):
        if not re.fullmatch(r"\d+\.png", path.name):
            raise ValueError("Preview PNG names must be numbered")
        files.append(path.relative_to(MOD).as_posix())
    payload = []
    for relative in files:
        path = MOD / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing/nonregular runtime file: {relative}")
        data = path.read_bytes()
        if path.suffix in (".json", ".lua", ".tl"):
            text = data.decode("utf-8")
            if text.startswith("\ufeff") or re.search(r"/home/|/tmp/|\b(?:copilot|codex|openai|gpt)\b", text, re.I):
                raise ValueError(f"Development-only content in runtime file: {relative}")
        if path.suffix == ".json":
            json.loads(data)
        if path.suffix == ".png":
            # Official preview dimensions; reject fake/misnamed image placeholders.
            import struct
            if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR" or len(data) < 24:
                raise ValueError(f"Invalid preview image: {relative}")
            if struct.unpack(">II", data[16:24]) != (1920, 1080):
                raise ValueError(f"Preview must be 1920x1080: {relative}")
        payload.append((relative, data))
    if (MOD / "license.txt").read_bytes() != (REPOSITORY / "LICENSE").read_bytes():
        raise ValueError("Runtime MIT notice must match repository LICENSE")
    output = output.resolve()
    if output == MOD or MOD in output.parents:
        raise ValueError("Do not build archives inside the runtime mod directory")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"easier-waypoints-v{version}.zip"
    # Fixed ordering/timestamps/permissions make builds reproducible.
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for relative, data in payload:
            entry = zipfile.ZipInfo(f"{MOD.name}/{relative}", date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, data)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{checksum}  {archive.name}\n", encoding="utf-8")
    print(f"Built {archive} ({len(payload)} files, TF3 revision {manifest['revision']})")
    if not (MOD / "_metadata/0.png").is_file():
        print("No cover included: this is a local prototype package, not a publication-ready listing.")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPOSITORY / "dist")
    build(parser.parse_args().output)
