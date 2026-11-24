"""Exercise the release CLI against an independent, tagged addon repository."""

from contextlib import chdir
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from scripts import prepare_release
from pathlib import Path


CLI = Path(__file__).resolve().parents[1] / "scripts/package_addon.py"
TAG = "v2.3.4"
SCRIPTS = ["Bootstrap.lua", "libs/Map.lua", "OlympusMytikas.lua", "OlympusRecruit.lua", "KillOnSight.lua"]


class PackageTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.addon = self.root / "OlympusMytikas"
        (self.addon / "libs").mkdir(parents=True)
        self.toc = self.addon / "OlympusMytikas.toc"
        self.toc.write_bytes(("## Version: 2.3.4\r\n" + "\r\n".join(SCRIPTS).replace("/", "\\")).encode())
        for name in SCRIPTS:
            (self.addon / name).write_text("-- " + name)
        (self.root / "README.md").write_text("Release operator instructions")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        self.git("tag", TAG)
        self.out = self.root / "OlympusMytikas-2.3.4.zip"

    def git(self, *args):
        subprocess.run(["git", "-c", "user.name=Packager Test", "-c", "user.email=test@example.invalid",
                        "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                       cwd=self.root, check=True, capture_output=True)

    def package(self, action="build", tag=TAG, path=None, error=None):
        result = subprocess.run([sys.executable, CLI, action, tag, path or self.out],
                                cwd=self.root, capture_output=True, text=True)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout

    def test_builds_exact_tag_and_validates_repackaged_files(self):
        (self.addon / SCRIPTS[0]).write_text("-- new changes")
        (self.addon / "untracked.lua").write_text("ignore")
        result = self.package()
        original = self.out.read_bytes()
        self.assertIn(hashlib.sha256(original).hexdigest(), result)
        self.package()
        self.assertEqual(original, self.out.read_bytes())
        with zipfile.ZipFile(self.out) as archive:
            files = {info.filename: archive.read(info) for info in archive.infolist() if not info.is_dir()}
        self.assertEqual(set(files), {"OlympusMytikas/" + name for name in [*SCRIPTS, self.toc.name]})
        self.assertEqual(files["OlympusMytikas/Bootstrap.lua"], b"-- Bootstrap.lua")
        with zipfile.ZipFile(self.out, "w") as archive:
            for name, contents in files.items():
                archive.writestr(name, contents)
        self.package("validate")
        with zipfile.ZipFile(self.out, "a") as archive:
            archive.writestr("OlympusMytikas/surprise.lua", "")
        self.package("validate", error="contents differ")

    def test_published_event_preserves_website_zip_bytes(self):
        self.package()
        built = self.out.read_bytes()
        # The moderator used a different ZIP writer for the same tagged tree.
        with zipfile.ZipFile(self.out) as source:
            files = [(entry.filename, source.read(entry)) for entry in source.infolist() if not entry.is_dir()]
        with zipfile.ZipFile(self.out, "w", compression=zipfile.ZIP_STORED) as uploaded:
            for name, contents in reversed(files):
                uploaded.writestr(name, contents)
            uploaded.comment = b"Moderator upload"
        original = self.out.read_bytes()
        self.assertNotEqual(built, original)
        self.out.unlink()
        release = dict(draft=False, prerelease=False, tag_name=TAG, assets=[
            dict(name=self.out.name, digest="sha256:" + hashlib.sha256(original).hexdigest())
        ])

        def download(*args):
            self.assertEqual(args, ("release", "download", TAG, "--pattern", self.out.name, "--dir", str(self.root)))
            self.out.write_bytes(original)

        with chdir(self.root), patch.object(prepare_release, "release_info", return_value=release), \
                patch.object(prepare_release, "gh", side_effect=download) as gh, \
                patch.dict(os.environ, GITHUB_OUTPUT=""):
            result = prepare_release.prepare(TAG, self.root, existing_only=False)
        gh.assert_called_once()
        self.assertEqual(result.read_bytes(), original)

    def test_rejects_mismatched_version_and_invalid_tag_or_name(self):
        self.git("tag", "v1.1.0")
        path = self.root / "OlympusMytikas-1.1.0.zip"
        self.package(tag="v1.1.0", path=path, error="single TOC version matching")
        self.assertFalse(path.exists())
        for tag in ["2.3.4", "v2.03.4", "v2.3.4-beta", "v123456789.3.4", "main"]:
            with self.subTest(tag=tag):
                self.package(tag=tag, error="stable vX.Y.Z")
        self.package(path=self.root / "addon.zip", error="filename")

    def test_refuses_incomplete_tag_before_writing_zip(self):
        (self.addon / SCRIPTS[1]).unlink()
        self.git("commit", "-qam", "Missing library")
        self.git("tag", "-f", TAG)
        self.package(error="Missing TOC file")
        self.assertFalse(self.out.exists())

    def test_rejects_changed_contents_and_unsafe_entries(self):
        self.package()
        with zipfile.ZipFile(self.out) as archive:
            files = {info.filename: archive.read(info) for info in archive.infolist() if not info.is_dir()}
        files["OlympusMytikas/Bootstrap.lua"] += b"\n-- changed"
        with zipfile.ZipFile(self.out, "w") as archive:
            for name, contents in files.items():
                archive.writestr(name, contents)
        self.package("validate", error="contents differ")
        with zipfile.ZipFile(self.out, "a") as archive:
            archive.writestr("OlympusMytikas/../unexpected", "")
        self.package("validate", error="Invalid Windows addon path")
        with self.out.open("wb") as stream:
            stream.truncate(8_000_001)
        self.package("validate", error="8,000,000 bytes")

    def test_refuses_links_in_tagged_source(self):
        os.symlink("Bootstrap.lua", self.addon / "Alias.lua")
        self.git("add", "OlympusMytikas")
        self.git("commit", "-qm", "Link")
        self.git("tag", "-f", TAG)
        self.package(error="Unsupported ZIP entry")


if __name__ == "__main__":
    unittest.main()
