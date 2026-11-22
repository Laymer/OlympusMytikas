import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts import publish_curseforge as cf


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.zip = Path(self.tmp.name, "OlympusMytikas-1.2.3.zip")
        self.write_toc("11509, 16001, 20506", "1.2.3")
        self.digest = "sha256:" + hashlib.sha256(self.zip.read_bytes()).hexdigest()
        self.release = {"tag_name": "v1.2.3", "body": "Fix guild window.\n* Keep settings.",
                        "draft": False, "prerelease": False}
        self.markers = {}
        self.gets = []
        self.posts = []
        for mock in [
            patch.dict(os.environ, {"GH_REPO": "org/repo", "CURSEFORGE_PROJECT_ID": "456",
                                    "CURSEFORGE_API_TOKEN": "test", "GITHUB_STEP_SUMMARY": ""}),
            patch.object(cf, "gh", side_effect=self.github),
            patch.object(cf, "curseforge_request", side_effect=self.curseforge),
        ]:
            mock.start()
            self.addCleanup(mock.stop)

    def write_toc(self, interfaces, version):
        with zipfile.ZipFile(self.zip, "w") as archive:
            archive.writestr("OlympusMytikas/OlympusMytikas.toc",
                             f"## Interface: {interfaces}\r\n## Version: {version}\r\n")

    def github(self, *args):
        if args == ("api", "repos/org/repo/releases/tags/v1.2.3"):
            assets = [{"name": self.zip.name, "digest": self.digest}]
            assets.extend({"name": name} for name in self.markers)
            return json.dumps({**self.release, "assets": assets})
        if args[:3] == ("release", "upload", "v1.2.3"):
            file = Path(args[3])
            self.assertNotIn(file.name, self.markers)
            self.markers[file.name] = json.loads(file.read_text())
            return ""
        if args == ("release", "download", "v1.2.3", "--pattern", cf.RECEIPT, "--output", "-"):
            return json.dumps(self.markers[cf.RECEIPT])
        self.fail(f"Unexpected gh command {args}")

    def curseforge(self, token, endpoint, *args, cwd=None):
        self.assertEqual(token, "test")
        if endpoint == "game/versions":
            self.gets.append(endpoint)
            return [{"id": 111, "name": "1.60.1"}, {"id": 112, "name": "1.15.9"}]
        self.assertIn(cf.PENDING, self.markers)
        self.assertEqual(endpoint, "projects/456/upload-file")
        self.assertEqual(args[0], "--form-string")
        self.assertEqual(args[2:], ("--form", "file=@OlympusMytikas-1.2.3.zip"))
        self.assertEqual(cwd, self.zip.parent)
        self.posts.append(json.loads(args[1].removeprefix("metadata=")))
        return {"id": 789}

    def run_publish(self):
        cf.publish("v1.2.3", self.zip)

    def test_accept_then_rerun(self):
        self.run_publish()
        self.assertEqual(self.posts, [{"changelog": self.release["body"], "changelogType": "markdown",
                                      "displayName": "Olympus Mytikas v1.2.3", "gameVersions": [111],
                                      "releaseType": "release", "isMarkedForManualRelease": False}])
        self.assertEqual(self.markers[cf.RECEIPT], {**self.markers[cf.PENDING], "fileId": 789})
        self.run_publish()
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(len(self.gets), 1)
        self.markers[cf.RECEIPT]["projectId"] += 1
        with self.assertRaisesRegex(cf.PublishError, "receipt"):
            self.run_publish()

    def test_lost_response_leaves_recoverable_marker(self):
        def lost_response(token, endpoint, *args, **kwargs):
            result = self.curseforge(token, endpoint, *args, **kwargs)
            if endpoint.endswith("upload-file"):
                raise subprocess.CalledProcessError(28, ["curl"])
            return result

        with patch.object(cf, "curseforge_request", side_effect=lost_response):
            with self.assertRaisesRegex(cf.PublishError, "reconciliation"):
                self.run_publish()
        self.assertNotIn(cf.RECEIPT, self.markers)
        with self.assertRaisesRegex(cf.PublishError, "previous upload"):
            self.run_publish()
        self.assertEqual(len(self.posts), 1)

    def test_missing_secret_fails_before_upload(self):
        with patch.dict(os.environ, {"CURSEFORGE_API_TOKEN": ""}):
            with self.assertRaisesRegex(cf.PublishError, "CURSEFORGE_API_TOKEN"):
                self.run_publish()
        self.assertFalse(self.markers)

    def test_unpublished_and_prerelease_and_mismatched_assets(self):
        for setting in ("draft", "prerelease"):
            with self.subTest(setting=setting), patch.dict(self.release, {setting: True}):
                with self.assertRaisesRegex(cf.PublishError, "published, stable"):
                    self.run_publish()
        self.digest = "sha256:wrong"
        with self.assertRaisesRegex(cf.PublishError, "digest"):
            self.run_publish()
        self.assertFalse(self.gets)
        self.assertFalse(self.markers)

    def test_unknown_or_ambiguous_game_version(self):
        for catalog in ([], [{"name": "1.60.1", "id": 11}, {"name": "1.60.1", "id": 12}]):
            with self.subTest(catalog=catalog), patch.object(cf, "curseforge_request", return_value=catalog):
                with self.assertRaisesRegex(cf.PublishError, "unique"):
                    self.run_publish()
        self.assertFalse(self.markers)

    def test_packaged_toc_is_authoritative(self):
        for interfaces, version in (("11509, 20506", "1.2.3"), ("16001", "1.2.4")):
            with self.subTest(interfaces=interfaces, version=version):
                self.write_toc(interfaces, version)
                with self.assertRaisesRegex(cf.PublishError, "TOC"):
                    self.run_publish()
        self.assertFalse(self.gets)
        self.assertFalse(self.markers)


if __name__ == "__main__":
    unittest.main()
