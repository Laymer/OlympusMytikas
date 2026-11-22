"""Build and verify the installable OlympusMytikas ZIP from a stable Git tag."""

import argparse
import hashlib
import io
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path


ADDON = "OlympusMytikas"
COMPONENT = r"(?:0|[1-9][0-9]{0,7})"
TAG = re.compile(rf"v{COMPONENT}\.{COMPONENT}\.{COMPONENT}")
MAX_ZIP_BYTES = 8_000_000
MAX_EXPANDED_BYTES = 16_000_000
ORIGINAL_DIGEST = "05466fd4f0c90eb54ee732fa8018df7a1928df9ad07b49709806fe8d0032ffd5"
REQUIRED_SCRIPTS = {"Bootstrap.lua", "OlympusMytikas.lua", "OlympusRecruit.lua", "KillOnSight.lua"}


def archive_files(data):
    if not 0 < len(data) <= MAX_ZIP_BYTES:
        raise ValueError("ZIP must be between 1 and 8,000,000 bytes")

    files = {}
    entries = set()
    paths = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        if len(members) > 2048 or sum(m.file_size for m in members) > MAX_EXPANDED_BYTES:
            raise ValueError("ZIP exceeds the member portal's entry or expanded size limit")
        for member in members:
            name = member.orig_filename
            if name in entries or not name.startswith(ADDON + "/") or len(name) > 512:
                raise ValueError(f"Duplicate or invalid archive entry: {name!r}")
            entries.add(name)
            directory = member.is_dir()
            parts = name.removesuffix("/").split("/")
            for index, part in enumerate(parts):
                if (not re.fullmatch(r"[A-Za-z0-9_.-]+", part) or part.endswith(".")
                        or re.match(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)", part, re.I)):
                    raise ValueError(f"Invalid Windows addon path: {name!r}")
                path = "/".join(parts[:index + 1])
                spelling = path + ("/" if directory or index < len(parts) - 1 else "")
                if paths.setdefault(path.lower(), spelling) != spelling:
                    raise ValueError(f"Conflicting archive paths at {path!r}")
            expected_type = stat.S_IFDIR if directory else stat.S_IFREG
            if (stat.S_IFMT(member.external_attr >> 16) not in (0, expected_type)
                    or member.external_attr & 0x408
                    or (not directory and member.external_attr & 0x10)
                    or member.flag_bits & ~0x080e
                    or member.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                raise ValueError(f"Unsupported ZIP entry: {name!r}")
            contents = archive.read(member)
            if directory:
                if contents:
                    raise ValueError(f"Directory contains file data: {name!r}")
            else:
                files[name] = contents
        if len(paths) > 4096:
            raise ValueError("ZIP has too many file and folder paths")
    return files, set(paths.values())


def check_manifest(files, version):
    manifest = files.get(f"{ADDON}/{ADDON}.toc", b"")
    if not manifest or len(manifest) > 1_000_000:
        raise ValueError("ZIP must contain the addon TOC at OlympusMytikas/OlympusMytikas.toc")
    lines = [line.strip() for line in manifest.decode("utf-8-sig").splitlines()]
    versions = [line.split(":", 1)[1].strip() for line in lines if re.match(r"^##\s*Version\s*:", line, re.I)]
    if versions != [version]:
        raise ValueError(f"Expected a single TOC version matching {version}")
    scripts = {line.replace("\\", "/") for line in lines if line and not line.startswith("#")}
    if missing := REQUIRED_SCRIPTS - scripts:
        raise ValueError(f"Required scripts absent from TOC: {', '.join(sorted(missing))}")
    for script in sorted(scripts):
        if f"{ADDON}/{script}" not in files:
            raise ValueError(f"Missing TOC file: {script}")


def package(command, tag, path):
    if not TAG.fullmatch(tag):
        raise ValueError(f"Expected a stable vX.Y.Z tag: {tag!r}")
    version = tag[1:]
    if path.name != f"{ADDON}-{version}.zip":
        raise ValueError(f"Expected filename {ADDON}-{version}.zip")

    tagged = subprocess.check_output(
        ["git", "archive", "--format=zip", f"refs/tags/{tag}^{{commit}}", "--", ADDON + "/"]
    )
    tagged_files, tagged_paths = archive_files(tagged)
    check_manifest(tagged_files, version)
    data = tagged
    if command == "validate":
        with path.open("rb") as source:
            data = source.read(MAX_ZIP_BYTES + 1)
        files, paths = archive_files(data)
        if files != tagged_files or paths != tagged_paths:
            raise ValueError(f"Release ZIP contents differ from {tag}")
    digest = hashlib.sha256(data).hexdigest()
    if version == "1.0.0" and digest != ORIGINAL_DIGEST:
        raise ValueError("Member Home requires the original v1.0.0 release ZIP")
    if command == "build":
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temp:
            pending = Path(temp.name)
            try:
                temp.write(data)
                temp.close()
                pending.replace(path)
            finally:
                pending.unlink(missing_ok=True)
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "validate"))
    parser.add_argument("tag")
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        digest = package(args.command, args.tag, args.path)
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile, zlib.error) as error:
        sys.exit(str(error))
    print(f"{digest}  {args.path.name}")


if __name__ == "__main__":
    main()
