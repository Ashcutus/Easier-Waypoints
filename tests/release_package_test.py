"""Verify the deliverable and make sure the inherited release target is gone."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class ReleaseTests(unittest.TestCase):
    def test_runtime_archive_is_reproducible_and_excludes_tooling(self):
        builder = module("package_release")
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            archive = builder.build(Path(first))
            again = builder.build(Path(second))
            self.assertEqual(archive.read_bytes(), again.read_bytes())
            self.assertEqual(archive.with_suffix(".zip.sha256").read_text().split()[0],
                             hashlib.sha256(archive.read_bytes()).hexdigest())
            with zipfile.ZipFile(archive) as package:
                self.assertIsNone(package.testzip())
                prefix = "easier_waypoints_1/"
                self.assertEqual(set(package.namelist()), {prefix + path for path in builder.RUNTIME_FILES})
                manifest = json.loads(package.read(prefix + "mod.json"))
                self.assertEqual(manifest["modId"], "easier_waypoints")
                self.assertEqual(manifest["revision"], 3)
                self.assertNotIn("version", manifest)
                self.assertEqual(package.read(prefix + "license.txt"), (ROOT / "LICENSE").read_bytes())
                # No mod.io listing is ever baked into the runtime package.
                for name in package.namelist():
                    self.assertNotRegex(package.read(name), rb"modapi\.io|mod\.io/g/|/mods/\d+")
                info = json.loads(package.read(prefix + "_metadata/modinfo.json"))
                self.assertIn("v" + (ROOT / "VERSION").read_text().strip(), info["description"])

    def test_unconfigured_target_refuses_before_network(self):
        labels = module("set_modio_version")
        with patch.dict(labels.os.environ, {}, clear=True), patch.object(labels, "build_opener") as network:
            with self.assertRaisesRegex(ValueError, "own mod.io ID"):
                labels.Client("fake-token")
            network.assert_not_called()

    def test_explicit_target_stays_on_tf3_and_cannot_inject_url(self):
        labels = module("set_modio_version")
        with patch.dict(labels.os.environ, {"MODIO_MOD_ID": "12345"}, clear=True):
            self.assertEqual(labels.target_base(), "https://g-10640.modapi.io/v1/games/10640/mods/12345/files")
        for bad in ("0", "-1", "true", "123/../../999", "1.5", "https://example.org"):
            with patch.dict(labels.os.environ, {"MODIO_MOD_ID": bad}, clear=True):
                with self.assertRaises(ValueError):
                    labels.target_base()


if __name__ == "__main__":
    unittest.main()
