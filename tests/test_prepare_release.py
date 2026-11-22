import hashlib
import tempfile
import unittest
from pathlib import Path
from contextlib import ExitStack
from unittest.mock import patch

from scripts import prepare_release as publisher


class PrepareReleaseTests(unittest.TestCase):
    tag = "v1.2.3"
    name = "OlympusMytikas-1.2.3.zip"
    archive = b"example ZIP"
    digest = "sha256:" + hashlib.sha256(archive).hexdigest()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name)
        self.path = self.directory / self.name
        self.release = dict(tag_name=self.tag, draft=False, prerelease=False, assets=[])
        mocks = ExitStack()
        self.addCleanup(mocks.close)
        self.gh = mocks.enter_context(patch.object(publisher, "gh"))
        self.release_info = mocks.enter_context(patch.object(publisher, "release_info"))
        self.run = mocks.enter_context(patch.object(publisher.subprocess, "run"))
        mocks.enter_context(patch.dict(publisher.os.environ, {"GITHUB_OUTPUT": ""}))
        self.release_info.return_value = self.release
        self.gh.side_effect = self.github

    def github(self, *args):
        if args[:2] == ("release", "upload"):
            self.assertEqual(self.path.read_bytes(), self.archive)
            self.release["assets"].append(dict(name=self.name, digest=self.digest))
        elif args[:2] == ("release", "download"):
            self.assertFalse(self.path.exists())
            self.path.write_bytes(self.archive)
        else:
            self.fail(args)

    def prepare(self, existing_only=False):
        return publisher.prepare(self.tag, self.directory, existing_only=existing_only)

    def test_new_release_builds_attaches_then_downloads(self):
        def package(args, *, check):
            if args[2] == "build":
                self.path.write_bytes(self.archive)
            else:
                self.assertEqual(args[2], "validate")
                self.assertEqual(self.path.read_bytes(), self.archive)
        self.run.side_effect = package
        self.assertEqual(self.prepare(), self.path)
        self.assertEqual(self.run.call_count, 2)

    def test_existing_release_uses_original(self):
        self.release["assets"].append(dict(name=self.name, digest=self.digest))
        self.prepare(existing_only=True)
        self.gh.assert_called_once()
        self.assertEqual(self.run.call_args.args[0][2], "validate")

    def test_missing_asset_in_manual_mode(self):
        with self.assertRaisesRegex(ValueError, "must already contain"):
            self.prepare(existing_only=True)
        self.gh.assert_not_called()

    def test_prerelease_is_skipped_before_writes(self):
        self.release["prerelease"] = True
        with self.assertRaisesRegex(ValueError, "published, stable"):
            self.prepare()
        self.gh.assert_not_called()

    def test_download_with_wrong_digest_fails(self):
        self.release["assets"].append(dict(name=self.name, digest="sha256:incorrect"))
        with self.assertRaisesRegex(ValueError, "asset digest"):
            self.prepare(existing_only=True)
        self.run.assert_not_called()
