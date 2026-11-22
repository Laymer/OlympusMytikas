"""Prepare the single installable GitHub release asset used by both channels."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

FIRST_PUBLIC_DIGEST = "bfdcf506002e4d63da4b2bffb7d8b9603e07a7f8ab95d33dd83b9b7f7b23893b"


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def release_info(tag):
    return json.loads(gh("api", f"repos/{os.environ['GH_REPO']}/releases/tags/{tag}"))


def prepare(tag, directory, *, existing_only):
    if not re.fullmatch(r"v(0|[1-9][0-9]{0,7})(\.(0|[1-9][0-9]{0,7})){2}", tag):
        raise ValueError("Choose a stable release tag such as v1.0.1.")
    release = release_info(tag)
    if release["draft"] or release["prerelease"] or release["tag_name"] != tag:
        raise ValueError("Choose a published, stable GitHub release.")

    name = f"OlympusMytikas-{tag[1:]}.zip"
    path = directory / name
    packager = [sys.executable, str(Path(__file__).with_name("package_addon.py"))]
    assets = {asset["name"]: asset for asset in release["assets"]}
    if name not in assets:
        if existing_only:
            raise ValueError(f"Existing release {tag} must already contain {name}.")
        subprocess.run([*packager, "build", tag, str(path)], check=True)
        gh("release", "upload", tag, str(path))
        assets = {asset["name"]: asset for asset in release_info(tag)["assets"]}
        path.unlink()

    # Fetch from GitHub even on a fresh build. All channels get the stored bytes.
    gh("release", "download", tag, "--pattern", name, "--dir", str(directory))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if assets[name]["digest"] != f"sha256:{digest}":
        raise ValueError("GitHub's asset digest differs from the downloaded ZIP.")
    if tag == "v1.0.1" and digest != FIRST_PUBLIC_DIGEST:
        raise ValueError("The first public release differs from the original v1.0.1 ZIP.")
    subprocess.run([*packager, "validate", tag, str(path)], check=True)
    if output := os.getenv("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as handle:
            print(f"archive={path}", file=handle)
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("directory", type=Path)
    parser.add_argument("--existing-only", action="store_true")
    args = parser.parse_args()
    try:
        prepare(args.tag, args.directory, existing_only=args.existing_only)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
