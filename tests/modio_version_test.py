"""Offline checks for release matching and version-only remote changes."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("modio_version", Path(__file__).resolve().parents[1] / "scripts/set_modio_version.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.files = [dict(id=i, filename=f"file{i}.zip", version="1.0", changelog=heading)
                      for i, heading in enumerate(["v1.2.0 — New feature", "1.2.0: Console", "v1.2.01 Wrong", "v1.1.2 Mention v1.2.0"], 1)]

    def test_exact_release_and_both_platform_files(self):
        self.assertEqual([f["id"] for f in mod.select_files(self.files, "1.2.0")], [1, 2])

    def test_explicit_ids_must_all_belong_to_mod(self):
        with self.assertRaises(ValueError):
            mod.select_files(self.files, "1.2.0", [1, 99])
        self.assertEqual(mod.select_files(self.files, "1.1.2", [4]), [self.files[3]])

    def test_no_match_refuses(self):
        with self.assertRaises(ValueError):
            mod.select_files(self.files, "9.0.0")

    def test_preview_never_writes_and_apply_only_sets_version(self):
        calls = []
        state = dict(self.files[0])

        class Client:
            def request(self, suffix, fields=None):
                calls.append((suffix, fields))
                if fields:
                    state.update(fields)
                return dict(state)

        with patch("builtins.print"):
            mod.update(Client(), [dict(state)], "1.2.0")
            self.assertEqual(calls, [])
            mod.update(Client(), [dict(state)], "1.2.0", True)
            self.assertEqual(calls, [("/1", None), ("/1", {"version": "1.2.0"}), ("/1", None)])
            calls.clear()
            mod.update(Client(), [dict(state)], "1.2.0", True)
            self.assertEqual(calls, [])

    def test_changed_file_refuses_write(self):
        class Client:
            def request(self, suffix, fields=None):
                self.assert_read(fields)
                return dict(id=1, version="1.0", changelog="changed")

            def assert_read(self, fields):
                if fields is not None:
                    raise AssertionError("Unexpected write")

        with patch("builtins.print"), self.assertRaises(RuntimeError):
            mod.update(Client(), [self.files[0]], "1.2.0", True)

    def test_html_changelog_from_website_edit_matches(self):
        files = [dict(id=7, filename="a.zip", version="1.0", changelog="<p>v1.4.0 &mdash; Crash fix</p>"),
                 dict(id=8, filename="b.zip", version="1.0", changelog="<p>v1.3.1 mentions v1.4.0</p>")]
        self.assertEqual([f["id"] for f in mod.select_files(files, "1.4.0")], [7])

    def test_interactive_pick_when_no_changelog_matches(self):
        with patch("builtins.print"):
            picked = mod.choose_files(self.files, "9.0.0", ask=lambda prompt: "3, 4")
            self.assertEqual([f["id"] for f in picked], [3, 4])
            with self.assertRaises(ValueError):
                mod.choose_files(self.files, "9.0.0", ask=lambda prompt: "")
            with self.assertRaises(ValueError):
                mod.choose_files(self.files, "9.0.0", ask=lambda prompt: "hiox")
            with self.assertRaises(ValueError):
                mod.choose_files(self.files, "9.0.0", ask=lambda prompt: "99")
        # Changelog matches and explicit IDs never prompt.
        never = lambda prompt: self.fail("Unexpected prompt")
        self.assertEqual([f["id"] for f in mod.choose_files(self.files, "1.2.0", ask=never)], [1, 2])
        self.assertEqual([f["id"] for f in mod.choose_files(self.files, "9.0.0", [4], ask=never)], [4])

    def test_confirmation_controls_writes(self):
        calls = []
        state = dict(self.files[0])

        class Client:
            def request(self, suffix, fields=None):
                calls.append((suffix, fields))
                if fields:
                    state.update(fields)
                return dict(state)

        with patch("builtins.print"):
            mod.update(Client(), [dict(state)], "1.4.0", confirm=lambda: False)
            self.assertEqual(calls, [])
            mod.update(Client(), [dict(state)], "1.4.0", confirm=lambda: True)
            self.assertEqual(calls, [("/1", None), ("/1", {"version": "1.4.0"}), ("/1", None)])

    def test_listing_handles_missing_fields(self):
        with patch("builtins.print") as printed:
            mod.show_files(self.files + [dict(id=5, filename="new.zip", date_added=2000000000,
                                              platforms=[{"platform": "windows"}], changelog="<p>v1.4.0</p>")])
        self.assertIn("ID 5", printed.call_args_list[0].args[0])

    def test_sync_plan_uses_changelog_release_and_keeps_deliberate_labels(self):
        files = [dict(id=1, version="1.0", changelog="v1.3.1 improves toolbar"),
                 dict(id=2, version="1.0", changelog="<p>v1.3.1 &mdash; console</p>"),
                 dict(id=3, version="1.2.0", changelog="v1.2.0 — already labelled"),
                 dict(id=4, version="1.2.0", changelog="v1.3.0 — deliberate other label"),
                 dict(id=5, version="1.0", changelog="Fixes a fatal error"),
                 dict(id=6, version="1.0", changelog="v1.2.01 not a release"),
                 dict(id=7, version="", changelog="1.1.2: Mention v1.2.0")]
        plan, conflicts = mod.plan_sync(files)
        self.assertEqual({release: [f["id"] for f in group] for release, group in plan.items()},
                         {"1.3.1": [1, 2], "1.1.2": [7]})
        self.assertEqual([(f["id"], release) for f, release in conflicts], [(4, "1.3.0")])

    def run_main(self, argv, token=None, tty=False):
        environ = {"MODIO_MOD_ID": "12345"}
        if token:
            environ["MODIO_ACCESS_TOKEN"] = token
        with patch.dict(mod.os.environ, environ, clear=True), patch.object(mod.sys, "argv", ["set_modio_version.py"] + argv), \
                patch.object(mod.sys.stdin, "isatty", lambda: tty), \
                patch.object(mod.getpass, "getpass", side_effect=AssertionError("Unexpected token prompt")):
            mod.main()

    def test_unattended_run_requires_token_and_never_prompts(self):
        with patch("sys.stderr"), self.assertRaises(SystemExit):
            self.run_main(["--sync", "--apply"])
        for combined in (["--sync", "--version", "1.4.0"], ["--sync", "--file-id", "5"], ["--sync", "--list"]):
            with patch("sys.stderr"), self.assertRaises(SystemExit):
                self.run_main(combined, token="t")

    def test_unattended_sync_applies_and_is_idempotent(self):
        state = {1: dict(id=1, filename="pc.zip", version="1.0", changelog="v1.4.1 — Fix"),
                 2: dict(id=2, filename="console.zip", version="1.0", changelog="<p>v1.4.1 — Fix</p>"),
                 3: dict(id=3, filename="old.zip", version="1.0", changelog="no release heading")}
        writes = []

        def request(client, suffix="", fields=None):
            file = state[int(suffix.strip("/"))]
            if fields:
                writes.append((file["id"], fields))
                file.update(fields)
            return dict(file)

        with patch.object(mod.Client, "files", lambda client: [dict(f) for f in state.values()]), \
                patch.object(mod.Client, "request", request), patch("builtins.print"):
            self.run_main(["--sync", "--apply"], token="t")
            self.assertEqual(writes, [(1, {"version": "1.4.1"}), (2, {"version": "1.4.1"})])
            self.assertEqual(state[3]["version"], "1.0")
            self.run_main(["--sync", "--apply"], token="t")
            self.assertEqual(len(writes), 2, "A second run must not write again")
            # Without --apply a non-interactive run only previews.
            state[3]["changelog"] = "v1.4.2 later"
            self.run_main(["--sync"], token="t")
            self.assertEqual(len(writes), 2)

    def test_pagination(self):
        with patch.dict(mod.os.environ, {"MODIO_MOD_ID": "12345"}, clear=True):
            client = mod.Client("unused-test-token")
        with patch.object(client, "request", side_effect=[
            {"data": self.files[:2], "result_total": 4},
            {"data": self.files[2:], "result_total": 4},
        ]) as request:
            self.assertEqual(client.files(), self.files)
            self.assertIn("_offset=2", request.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
