"""Unit tests for plugins/serena/derive_context.py."""

import sys
import tempfile
import unittest
from pathlib import Path

# Import the module under test from the serena plugin directory.
sys.path.insert(0, str(Path(__file__).parent.parent / "plugins" / "serena"))
import derive_context  # noqa: E402


# A trimmed but representative slice of Serena's claude-code.yml, including the
# comment block that sits directly above the flag.
SAMPLE = """description: Claude Code (single project mode)
prompt: |
  You are running in a CLI coding agent context.

excluded_tools:
  - read_file
  - execute_shell_command

tool_description_overrides: {}

# whether to assume that Serena shall only work on a single project ...
# The `activate_project` tool is always disabled in this case ...
single_project: true

structured_tool_output: false
"""


class TransformTests(unittest.TestCase):
    def test_flips_flag_to_false(self):
        out = derive_context.transform(SAMPLE)
        self.assertIn("single_project: false", out)
        self.assertNotRegex(out, r"(?m)^[ \t]*single_project:[ \t]*true[ \t]*$")

    def test_prepends_generated_header(self):
        out = derive_context.transform(SAMPLE)
        self.assertTrue(out.startswith("# GENERATED"))
        # The rest of the upstream content is preserved verbatim.
        self.assertIn("excluded_tools:", out)
        self.assertIn("structured_tool_output: false", out)
        self.assertIn("You are running in a CLI coding agent context.", out)

    def test_tolerates_surrounding_whitespace(self):
        out = derive_context.transform(SAMPLE.replace("single_project: true", "single_project:   true  "))
        self.assertIn("single_project: false", out)

    def test_raises_when_flag_absent(self):
        with self.assertRaises(ValueError):
            derive_context.transform(SAMPLE.replace("single_project: true", "single_project: false"))

    def test_raises_when_flag_duplicated(self):
        with self.assertRaises(ValueError):
            derive_context.transform(SAMPLE + "\nsingle_project: true\n")

    def test_does_not_touch_unrelated_true_values(self):
        text = SAMPLE.replace("structured_tool_output: false", "structured_tool_output: true")
        out = derive_context.transform(text)
        self.assertIn("structured_tool_output: true", out)


class FindSourceTests(unittest.TestCase):
    def test_locates_context_under_tool_root(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = root / "lib" / "python3.13" / "site-packages" / "serena" / "resources" / "config" / "contexts"
            ctx.mkdir(parents=True)
            expected = ctx / "claude-code.yml"
            expected.write_text(SAMPLE, encoding="utf-8")
            self.assertEqual(derive_context.find_source(root), expected)

    def test_raises_when_missing(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(FileNotFoundError):
                derive_context.find_source(Path(td))


class DestPathTests(unittest.TestCase):
    def test_dest_is_resolvable_context_name(self):
        dest = derive_context.dest_path()
        self.assertEqual(dest.name, "ide-assistant-worktrees.yml")
        self.assertEqual(dest.parent.name, "contexts")
        self.assertEqual(dest.parent.parent.name, ".serena")


if __name__ == "__main__":
    unittest.main()
