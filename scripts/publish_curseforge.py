"""Submit the canonical GitHub Release ZIP to the Olympus Mytikas CurseForge project."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile


API = "https://wow.curseforge.com/api"
PENDING = "curseforge-pending.json"
RECEIPT = "curseforge-receipt.json"
FOREVER_INTERFACE = "16001"
FOREVER_VERSION = "1.60.1"


class PublishError(Exception):
    pass


def required_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise PublishError(f"Configure {name} before publishing.")
    return value


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def write_asset(tag, name, data):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp, name)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        # GitHub atomically rejects duplicate names. Never overwrite a pending upload.
        gh("release", "upload", tag, str(path))


def curseforge_request(token, endpoint, *options, cwd=None):
    # Supply the author token on stdin. curl does not follow redirects or retry POSTs.
    return json.loads(subprocess.check_output(
        ["curl", "--disable", "--silent", "--show-error", "--fail", "--connect-timeout",
         "15", "--max-time", "120", "--header", "@-", *options, f"{API}/{endpoint}"],
        input=f"X-Api-Token: {token}\n", text=True, cwd=cwd,
    ))


def forever_game_id(versions):
    matches = [v["id"] for v in versions if v.get("name") == FOREVER_VERSION]
    if len(matches) != 1 or type(matches[0]) is not int or matches[0] <= 0:
        raise PublishError(f"Expected a unique CurseForge game version for Forever {FOREVER_VERSION}.")
    return matches[0]


def verify_package(tag, path):
    version = tag[1:]
    if path.name != f"OlympusMytikas-{version}.zip":
        raise PublishError("The ZIP filename must match the release tag.")
    with zipfile.ZipFile(path) as archive:
        toc = archive.read("OlympusMytikas/OlympusMytikas.toc").decode("utf-8-sig")
    fields = dict(re.findall(r"^## (Version|Interface):[ \t]*([^\r\n]*)", toc, re.M))
    if fields.get("Version", "").strip() != version:
        raise PublishError("The ZIP's TOC version must match the release tag.")
    if FOREVER_INTERFACE not in [v.strip() for v in fields.get("Interface", "").split(",")]:
        raise PublishError(f"The ZIP's TOC must declare the supported Forever interface {FOREVER_INTERFACE}.")


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            print(message, file=summary)


def publish(tag, path):
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag):
        raise PublishError("Expected a stable vX.Y.Z release tag.")
    repo = required_env("GH_REPO")
    project = required_env("CURSEFORGE_PROJECT_ID")
    if not re.fullmatch(r"[1-9][0-9]*", project):
        raise PublishError("CURSEFORGE_PROJECT_ID must be a positive integer.")
    verify_package(tag, path)
    release = json.loads(gh("api", f"repos/{repo}/releases/tags/{tag}"))
    if release["tag_name"] != tag or release["draft"] or release["prerelease"]:
        raise PublishError("Select a published, stable GitHub Release.")
    assets = {asset["name"]: asset for asset in release["assets"]}
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if assets.get(path.name, {}).get("digest") != f"sha256:{sha}":
        raise PublishError("The ZIP must match the SHA-256 digest of the canonical GitHub Release asset.")

    identity = {"projectId": int(project), "releaseTag": tag, "assetName": path.name, "sha256": sha}
    if RECEIPT in assets:
        data = json.loads(gh("release", "download", tag, "--pattern", RECEIPT, "--output", "-"))
        file_id = data.get("fileId")
        if (data != {**identity, "fileId": file_id}
                or type(file_id) is not int or file_id <= 0):
            raise PublishError("The CurseForge receipt does not match this project or release package.")
        report(f"Already submitted {tag} to CurseForge as file {file_id}.")
        return
    if PENDING in assets:
        raise PublishError("A previous upload may have reached CurseForge. Check the author dashboard "
                           "and follow the README recovery steps before retrying.")

    if release.get("immutable"):
        raise PublishError("This release is immutable. The publisher requires writable release assets for upload receipts.")
    notes = (release.get("body") or "").strip()
    if not notes:
        raise PublishError("Add player-facing notes to the GitHub Release before submitting it.")
    token = required_env("CURSEFORGE_API_TOKEN")
    if "\n" in token or "\r" in token:
        raise PublishError("Invalid CurseForge author token.")
    game_id = forever_game_id(curseforge_request(token, "game/versions"))
    metadata = {"changelog": notes, "changelogType": "markdown", "displayName": f"Olympus Mytikas {tag}",
                "gameVersions": [game_id], "releaseType": "release", "isMarkedForManualRelease": False}

    write_asset(tag, PENDING, identity)
    try:
        result = curseforge_request(token, f"projects/{project}/upload-file",
                                    "--form-string", "metadata=" + json.dumps(metadata),
                                    "--form", "file=@" + path.name, cwd=path.parent)
        file_id = result.get("id") if isinstance(result, dict) else None
        if type(file_id) is not int or file_id <= 0:
            raise PublishError("CurseForge returned no valid file ID.")
        report(f"Submitted {tag} to CurseForge as file {file_id}. Public downloads follow approval.")
        write_asset(tag, RECEIPT, {**identity, "fileId": file_id})
    except (PublishError, OSError, ValueError, subprocess.CalledProcessError) as err:
        raise PublishError("Upload outcome needs reconciliation. Check the CurseForge author dashboard "
                           "and follow the README recovery steps.") from err


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("zip_path", type=Path)
    args = parser.parse_args()
    try:
        publish(args.tag, args.zip_path)
    except subprocess.CalledProcessError as err:
        sys.exit(f"{err.cmd[0]} failed with exit code {err.returncode}.")
    except (PublishError, KeyError, OSError, ValueError, zipfile.BadZipFile) as err:
        sys.exit(str(err))


if __name__ == "__main__":
    main()
