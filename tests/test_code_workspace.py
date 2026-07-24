"""Unit tests for src/code_workspace.py — idempotent merge of REPO_NAMES into
the VS Code multi-root workspace file.
"""

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))
import code_workspace  # noqa: E402


def _run(path, repo_names):
    env = {"REPO_NAMES": repo_names}
    return code_workspace.main([str(path)], env)


def _load(path):
    return json.loads(path.read_text(encoding="utf-8"))


class FreshFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "dev.code-workspace"

    def test_two_names_sorted_artifacts_last(self):
        # Unsorted input → output sorted by name; /artifacts always last.
        rc = _run(self.path, "shared-lib app")
        self.assertEqual(rc, 0)
        data = _load(self.path)
        self.assertEqual(
            data["folders"],
            [
                {"path": "repos/app", "name": "app"},
                {"path": "repos/shared-lib", "name": "shared-lib"},
                {"path": "/artifacts", "name": "artifacts"},
            ],
        )
        self.assertEqual(
            data["settings"], {"terminal.integrated.cwd": "/workspace/repos"}
        )

    def test_empty_repo_names_just_artifacts(self):
        rc = _run(self.path, "")
        self.assertEqual(rc, 0)
        self.assertEqual(
            _load(self.path),
            {
                "folders": [{"path": "/artifacts", "name": "artifacts"}],
                "settings": {"terminal.integrated.cwd": "/workspace/repos"},
            },
        )

    def test_zero_byte_file_treated_as_missing(self):
        self.path.write_text("", encoding="utf-8")
        rc = _run(self.path, "app")
        self.assertEqual(rc, 0)
        data = _load(self.path)
        self.assertEqual(
            [f["path"] for f in data["folders"]],
            ["repos/app", "/artifacts"],
        )
        self.assertEqual(
            data["settings"], {"terminal.integrated.cwd": "/workspace/repos"}
        )


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "dev.code-workspace"

    def _write(self, obj):
        self.path.write_text(code_workspace._dump_json(obj), encoding="utf-8")

    def test_merge_repos_then_others_then_artifacts(self):
        self._write(
            {
                "folders": [
                    {"path": "worktrees/app/feature", "name": "feature"},
                    {"path": "notes", "name": "hand-added"},
                    {"path": "/artifacts", "name": "artifacts"},
                ],
                "settings": {},
            }
        )
        rc = _run(self.path, "shared-lib app")
        self.assertEqual(rc, 0)
        self.assertEqual(
            _load(self.path)["folders"],
            [
                {"path": "repos/app", "name": "app"},
                {"path": "repos/shared-lib", "name": "shared-lib"},
                {"path": "worktrees/app/feature", "name": "feature"},
                {"path": "notes", "name": "hand-added"},
                {"path": "/artifacts", "name": "artifacts"},
            ],
        )

    def test_rerun_is_byte_identical(self):
        self._write(
            {
                "folders": [
                    {"path": "worktrees/app/feature", "name": "feature"},
                    {"path": "/artifacts", "name": "artifacts"},
                ],
                "settings": {},
            }
        )
        self.assertEqual(_run(self.path, "app"), 0)
        first = self.path.read_bytes()
        self.assertEqual(_run(self.path, "app"), 0)
        self.assertEqual(self.path.read_bytes(), first)

    def test_adding_one_more_name_inserts_exactly_that_entry(self):
        self._write(
            {
                "folders": [
                    {"path": "repos/app", "name": "app"},
                    {"path": "worktrees/app/feature", "name": "feature"},
                    {"path": "/artifacts", "name": "artifacts"},
                ],
                "settings": {},
            }
        )
        before = _load(self.path)["folders"]
        self.assertEqual(_run(self.path, "app shared-lib"), 0)
        after = _load(self.path)["folders"]
        self.assertEqual(len(after), len(before) + 1)
        self.assertEqual(
            after,
            [
                {"path": "repos/app", "name": "app"},
                {"path": "repos/shared-lib", "name": "shared-lib"},
                {"path": "worktrees/app/feature", "name": "feature"},
                {"path": "/artifacts", "name": "artifacts"},
            ],
        )

    def test_extra_keys_on_entries_and_settings_survive(self):
        self._write(
            {
                "folders": [
                    {
                        "path": "repos/app",
                        "name": "app",
                        "foo": 1,
                    },
                    {
                        "path": "worktrees/app/x",
                        "name": "x",
                        "bar": "keep",
                    },
                    {"path": "/artifacts", "name": "artifacts", "baz": True},
                ],
                "settings": {"editor.tabSize": 2, "custom": {"a": 1}},
                "extensions": {"recommendations": ["ms-python.python"]},
            }
        )
        self.assertEqual(_run(self.path, "app"), 0)
        data = _load(self.path)
        self.assertEqual(data["folders"][0]["foo"], 1)
        self.assertEqual(data["folders"][1]["bar"], "keep")
        self.assertEqual(data["folders"][2]["baz"], True)
        self.assertEqual(data["settings"], {"editor.tabSize": 2, "custom": {"a": 1}})
        self.assertEqual(
            data["extensions"], {"recommendations": ["ms-python.python"]}
        )


class RefusalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "dev.code-workspace"

    def test_invalid_json_exits_1_and_leaves_file_untouched(self):
        raw = b"{not json\n"
        self.path.write_bytes(raw)
        err = io.StringIO()
        with redirect_stderr(err):
            rc = _run(self.path, "app")
        self.assertEqual(rc, 1)
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertIn("not valid JSON", err.getvalue())

    def test_folders_not_a_list_exits_1_and_leaves_file_untouched(self):
        payload = b'{"folders": {}, "settings": {}}\n'
        self.path.write_bytes(payload)
        err = io.StringIO()
        with redirect_stderr(err):
            rc = _run(self.path, "app")
        self.assertEqual(rc, 1)
        self.assertEqual(self.path.read_bytes(), payload)
        self.assertIn("folders", err.getvalue())


if __name__ == "__main__":
    unittest.main()
