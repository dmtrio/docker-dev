#!/usr/bin/env python3
"""
Unit tests for wire_plugins.py — replaces the mirror-simulation + drift-guard
approach from tests/plugins.test.sh. Pins exact bash/jq/sed semantics that the
module ported into Python: merge order, collision detection, file atomicity,
marker detection, mode preservation, env var interpolation, and idempotency.
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add src/ to path for import
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
import wire_plugins


class QuietTestCase(unittest.TestCase):
    """Swallows the module's progress prints (✓/⚠ lines) so the unittest
    output stays readable; tests that assert on messages still work because
    redirect_stdout inside a test simply swaps in its own buffer."""

    def setUp(self):
        self._quiet = contextlib.redirect_stdout(io.StringIO())
        self._quiet.__enter__()

    def tearDown(self):
        self._quiet.__exit__(None, None, None)


class TestMergePluginEntries(unittest.TestCase):
    """Tests for merge_plugin_entries function."""

    def test_two_plugin_entries_merge_preserving_insertion_order(self):
        """Two plugin entry objects merge into one dict preserving insertion order."""
        entries = [
            {"serena": {"command": "bash"}},
            {"obsidian": {"command": "python3"}},
        ]
        result = wire_plugins.merge_plugin_entries(entries)
        self.assertEqual(list(result.keys()), ["serena", "obsidian"])
        self.assertEqual(result["serena"], {"command": "bash"})
        self.assertEqual(result["obsidian"], {"command": "python3"})

    def test_duplicate_server_name_raises_wireerror(self):
        """Same server name in two entries raises WireError with names."""
        entries = [
            {"serena": {"command": "bash"}},
            {"serena": {"command": "python3"}},
        ]
        with self.assertRaises(wire_plugins.WireError) as cm:
            wire_plugins.merge_plugin_entries(entries)
        self.assertIn("multiple enabled plugins define the same MCP server name(s): serena", str(cm.exception))

    def test_non_dict_entry_raises_wireerror(self):
        """Non-dict entry in plugin_mcp_entries raises WireError."""
        entries = ["not a dict"]
        with self.assertRaises(wire_plugins.WireError) as cm:
            wire_plugins.merge_plugin_entries(entries)
        self.assertIn("plugin_mcp_entries must be JSON objects", str(cm.exception))

    def test_non_dict_server_spec_raises_wireerror(self):
        """A non-dict server spec is rejected here (the choke point), so the
        local/remote classifiers never substring-match a non-dict downstream."""
        with self.assertRaises(wire_plugins.WireError) as cm:
            wire_plugins.merge_plugin_entries([{"srv": "commandline"}])
        self.assertIn("spec must be a JSON object", str(cm.exception))


class TestGenerateClaudeMcp(QuietTestCase):
    """Tests for generate_claude_mcp function."""

    def test_no_git_directory_skips_generation(self):
        """No workspace/main/.git → prints skip message, writes nothing."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            main_dir = workspace / "main"
            main_dir.mkdir()
            mcp_path = main_dir / ".mcp.json"
            marker = workspace / ".mcp.generated"

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                wire_plugins.generate_claude_mcp(workspace, {}, {})

            self.assertIn("skipping .mcp.json", output.getvalue())
            self.assertFalse(mcp_path.exists())
            self.assertFalse(marker.exists())

    def test_existing_mcp_json_without_marker_left_untouched(self):
        """Repo ships its own .mcp.json (no marker) → file left byte-identical."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()
            mcp_path = main_dir / ".mcp.json"
            original_content = '{"custom": "config"}\n'
            mcp_path.write_text(original_content)

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                wire_plugins.generate_claude_mcp(workspace, {"obsidian": True}, {})

            self.assertEqual(mcp_path.read_text(), original_content)
            self.assertFalse((workspace / ".mcp.generated").exists())
            self.assertIn("repo ships its own .mcp.json", output.getvalue())

    def test_fresh_generation_obsidian_plus_local_and_remote_plugins(self):
        """Fresh generation: obsidian generated + a local plugin (verbatim) +
        a remote plugin (gains type: http). Marker created, idempotent."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()
            mcp_path = main_dir / ".mcp.json"
            marker = workspace / ".mcp.generated"

            caps = {"obsidian": True}
            plugins = {
                "myserena": {"command": "bash", "args": ["-c"]},          # local
                "coding": {"url": "http://host.docker.internal:8811/mcp",  # remote
                           "headers": {"Authorization": "Bearer ${MCP_GATEWAY_TOKEN}"}},
            }

            wire_plugins.generate_claude_mcp(workspace, caps, plugins)

            self.assertTrue(mcp_path.exists())
            self.assertTrue(marker.exists())

            content = mcp_path.read_text()
            self.assertTrue(content.endswith("\n"))
            servers = json.loads(content)["mcpServers"]
            # obsidian generated first, then plugins in insertion order
            self.assertEqual(list(servers), ["obsidian-annotated", "myserena", "coding"])
            # local plugin passes through verbatim (no type: injected)
            self.assertEqual(servers["myserena"], {"command": "bash", "args": ["-c"]})
            # remote plugin gains type: http; header ${VAR} refs NOT expanded
            self.assertEqual(servers["coding"], {
                "type": "http",
                "url": "http://host.docker.internal:8811/mcp",
                "headers": {"Authorization": "Bearer ${MCP_GATEWAY_TOKEN}"}})
            self.assertEqual(servers["obsidian-annotated"]["headers"]["Authorization"],
                             "Bearer ${OBSIDIAN_ANNOTATED_KEY}")

            # Rerun with marker present (idempotency check)
            wire_plugins.generate_claude_mcp(workspace, caps, plugins)
            self.assertEqual(mcp_path.read_text(), content)

    def test_all_capabilities_false_no_plugins(self):
        """All capabilities false, no plugins → writes empty mcpServers."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()
            mcp_path = main_dir / ".mcp.json"

            wire_plugins.generate_claude_mcp(workspace, {}, {})

            data = json.loads(mcp_path.read_text())
            self.assertEqual(data["mcpServers"], {})

    def test_plugin_named_obsidian_collides_with_generated(self):
        """A plugin squatting the one still-generated name (obsidian-annotated)
        with obsidian enabled raises WireError."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()

            with self.assertRaises(wire_plugins.WireError) as cm:
                wire_plugins.generate_claude_mcp(
                    workspace,
                    {"obsidian": True},
                    {"obsidian-annotated": {"command": "bash"}}
                )
            self.assertIn("collide with generated servers", str(cm.exception))


class TestPreapproveClaude(QuietTestCase):
    """Tests for preapprove_claude function."""

    def test_no_mcp_json_does_nothing(self):
        """No .mcp.json → silently does nothing, no ~/.claude.json created."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            (workspace / "main").mkdir()

            wire_plugins.preapprove_claude(home, workspace)

            self.assertFalse((home / ".claude.json").exists())

    def test_mcp_json_present_creates_claude_json(self):
        """No ~/.claude.json → creates it with enabledMcpjsonServers and trust flag."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            main_dir = workspace / "main"
            main_dir.mkdir()
            mcp_path = main_dir / ".mcp.json"
            mcp_path.write_text('{"mcpServers": {"coding": {}, "obsidian-annotated": {}}}')

            wire_plugins.preapprove_claude(home, workspace)

            cj = home / ".claude.json"
            self.assertTrue(cj.exists())
            data = json.loads(cj.read_text())
            proj_key = str(workspace / "main")
            self.assertIn(proj_key, data["projects"])
            self.assertEqual(
                sorted(data["projects"][proj_key]["enabledMcpjsonServers"]),
                ["coding", "obsidian-annotated"]
            )
            self.assertTrue(data["projects"][proj_key]["hasTrustDialogAccepted"])

    def test_existing_claude_json_preserves_unrelated_keys(self):
        """Existing ~/.claude.json with unrelated keys and project → those survive."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            main_dir = workspace / "main"
            main_dir.mkdir()
            mcp_path = main_dir / ".mcp.json"
            mcp_path.write_text('{"mcpServers": {"coding": {}}}')

            cj = home / ".claude.json"
            initial_state = {
                "other_key": "value",
                "projects": {
                    str(workspace / "main"): {
                        "someField": "survives",
                    }
                }
            }
            cj.write_text(json.dumps(initial_state, indent=2) + "\n")

            wire_plugins.preapprove_claude(home, workspace)

            data = json.loads(cj.read_text())
            self.assertEqual(data["other_key"], "value")
            proj_key = str(workspace / "main")
            self.assertEqual(data["projects"][proj_key]["someField"], "survives")
            self.assertEqual(data["projects"][proj_key]["enabledMcpjsonServers"], ["coding"])

    def test_invalid_json_in_claude_json_raises_wireerror(self):
        """Invalid JSON in ~/.claude.json raises WireError."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            main_dir = workspace / "main"
            main_dir.mkdir()
            mcp_path = main_dir / ".mcp.json"
            mcp_path.write_text('{"mcpServers": {}}')

            cj = home / ".claude.json"
            cj.write_text("{invalid json")

            with self.assertRaises(wire_plugins.WireError):
                wire_plugins.preapprove_claude(home, workspace)


class TestWriteIdentity(QuietTestCase):
    """Tests for write_identity function."""

    def test_cursor_agent_missing_file_creates_with_correct_format(self):
        """cursor-agent on missing file → creates ~/.cursor/mcp.json mode 0600."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            key = "MYKEY123"

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                wire_plugins.write_identity("cursor-agent", key, home)

            mcp_path = home / ".cursor" / "mcp.json"
            self.assertTrue(mcp_path.exists())
            self.assertEqual(os.stat(mcp_path).st_mode & 0o777, 0o600)

            data = json.loads(mcp_path.read_text())
            self.assertEqual(
                data["mcpServers"]["obsidian-annotated"],
                {
                    "url": "https://mcp-obsidian.dmetr.io/mcp",
                    "headers": {"Authorization": "Bearer MYKEY123"}
                }
            )
            self.assertIn("cursor-agent MCP config", output.getvalue())

    def test_cursor_agent_existing_file_preserves_plugins(self):
        """cursor-agent on existing file with plugin → plugin preserved."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            mcp_path = home / ".cursor" / "mcp.json"
            mcp_path.parent.mkdir(parents=True)
            mcp_path.write_text(json.dumps({
                "mcpServers": {
                    "myserena": {"command": "bash"}
                }
            }))

            wire_plugins.write_identity("cursor-agent", "KEY", home)

            data = json.loads(mcp_path.read_text())
            self.assertIn("myserena", data["mcpServers"])
            self.assertIn("obsidian-annotated", data["mcpServers"])

    def test_zero_byte_existing_file_takes_create_path(self):
        """Zero-byte existing file takes create path (pins empty-input jq bug)."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            mcp_path = home / ".cursor" / "mcp.json"
            mcp_path.parent.mkdir(parents=True)
            mcp_path.write_text("")  # Zero bytes

            wire_plugins.write_identity("cursor-agent", "KEY", home)

            data = json.loads(mcp_path.read_text())
            self.assertEqual(list(data["mcpServers"].keys()), ["obsidian-annotated"])

    def test_gemini_uses_httpurl_key(self):
        """gemini writes ~/.gemini/settings.json with key 'httpUrl' not 'url'."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)

            wire_plugins.write_identity("gemini", "GKEY", home)

            settings_path = home / ".gemini" / "settings.json"
            data = json.loads(settings_path.read_text())
            self.assertIn("httpUrl", data["mcpServers"]["obsidian-annotated"])
            self.assertNotIn("url", data["mcpServers"]["obsidian-annotated"])
            self.assertEqual(data["mcpServers"]["obsidian-annotated"]["httpUrl"], "https://mcp-obsidian.dmetr.io/mcp")

    def test_pi_overwrites_wholesale_with_http_entry(self):
        """pi OVERWRITES ~/.pi/agent/mcp.json wholesale with http entry."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            pi_path = home / ".pi" / "agent" / "mcp.json"
            pi_path.parent.mkdir(parents=True)
            pi_path.write_text(json.dumps({"other": "data"}))

            wire_plugins.write_identity("pi", "PIKEY", home)

            data = json.loads(pi_path.read_text())
            self.assertEqual(list(data.keys()), ["mcpServers"])
            entry = data["mcpServers"]["obsidian-annotated"]
            self.assertEqual(entry["type"], "http")
            self.assertEqual(entry["url"], "https://mcp-obsidian.dmetr.io/mcp")
            self.assertIn("headers", entry)

    def test_codex_prints_warning_writes_no_file(self):
        """codex prints warning and writes no file."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                wire_plugins.write_identity("codex", "CKEY", home)

            self.assertIn("codex obsidian identity not yet wired", output.getvalue())
            self.assertFalse((home / ".codex" / "config.toml").exists())


class TestWirePluginServersJson(QuietTestCase):
    """Tests for wire_plugin_servers_json function."""

    def test_fresh_creates_config_and_sidecar(self):
        """Fresh (no file): creates config and sidecar with sorted names, mode 0600."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            plugins = {"serena": {"command": "bash"}, "agentic": {"command": "python3"}}

            wire_plugins.wire_plugin_servers_json(config_path, plugins)

            self.assertTrue(config_path.exists())
            self.assertEqual(os.stat(config_path).st_mode & 0o777, 0o600)

            sidecar = config_path.parent / (config_path.name + ".dev-agent-plugins")
            self.assertTrue(sidecar.exists())
            self.assertEqual(os.stat(sidecar).st_mode & 0o777, 0o600)

            sidecar_data = json.loads(sidecar.read_text())
            self.assertEqual(sidecar_data, ["agentic", "serena"])  # sorted

    def test_existing_config_removes_stale_plugin_keeps_identity_and_handadded(self):
        """Existing config with identity, hand-added, stale plugin → stale removed."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            config_path.write_text(json.dumps({
                "mcpServers": {
                    "obsidian-annotated": {"url": "..."},  # identity
                    "myhandadded": {"command": "custom"},  # hand-added
                    "oldplug": {"command": "removed"}  # stale plugin
                }
            }))

            sidecar = config_path.parent / (config_path.name + ".dev-agent-plugins")
            sidecar.write_text('["oldplug"]\n')

            # Wire with new plugins (no oldplug)
            wire_plugins.wire_plugin_servers_json(config_path, {"newplug": {"command": "new"}})

            data = json.loads(config_path.read_text())
            self.assertNotIn("oldplug", data["mcpServers"])
            self.assertIn("obsidian-annotated", data["mcpServers"])
            self.assertIn("myhandadded", data["mcpServers"])
            self.assertIn("newplug", data["mcpServers"])

    def test_idempotency_two_calls_byte_identical(self):
        """Calling twice yields byte-identical config and sidecar."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            plugins = {"serena": {"command": "bash"}}

            wire_plugins.wire_plugin_servers_json(config_path, plugins)
            content1 = config_path.read_text()
            sidecar = config_path.parent / (config_path.name + ".dev-agent-plugins")
            sidecar_content1 = sidecar.read_text()

            wire_plugins.wire_plugin_servers_json(config_path, plugins)
            content2 = config_path.read_text()
            sidecar_content2 = sidecar.read_text()

            self.assertEqual(content1, content2)
            self.assertEqual(sidecar_content1, sidecar_content2)

    def test_plugin_removal_wired_plugin_gone_identity_survives(self):
        """Removing a plugin: serena removed, identity survives."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            config_path.write_text(json.dumps({
                "mcpServers": {
                    "obsidian-annotated": {"url": "..."},
                    "serena": {"command": "bash"}
                }
            }))

            sidecar = config_path.parent / (config_path.name + ".dev-agent-plugins")
            sidecar.write_text('["serena"]\n')

            # Call with empty plugins
            wire_plugins.wire_plugin_servers_json(config_path, {})

            data = json.loads(config_path.read_text())
            self.assertNotIn("serena", data["mcpServers"])
            self.assertIn("obsidian-annotated", data["mcpServers"])
            self.assertEqual(json.loads(sidecar.read_text()), [])

    def test_invalid_json_in_config_raises_wireerror(self):
        """Invalid JSON in config raises WireError naming the file."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            config_path.write_text("{invalid")

            with self.assertRaises(wire_plugins.WireError):
                wire_plugins.wire_plugin_servers_json(config_path, {})

    def test_zero_byte_config_takes_create_path(self):
        """Zero-byte config takes create path."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            config_path.write_text("")

            wire_plugins.wire_plugin_servers_json(config_path, {"p": {"command": "x"}})

            data = json.loads(config_path.read_text())
            self.assertIn("p", data["mcpServers"])

    def test_zero_byte_sidecar_treated_as_empty_array(self):
        """Zero-byte sidecar treated as [], no error."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "mcp.json"
            config_path.write_text(json.dumps({"mcpServers": {"old": {}}}))

            sidecar = config_path.parent / (config_path.name + ".dev-agent-plugins")
            sidecar.write_text("")

            # Should not raise
            wire_plugins.wire_plugin_servers_json(config_path, {"new": {}})
            data = json.loads(config_path.read_text())
            self.assertIn("old", data["mcpServers"])  # old NOT removed since sidecar was empty
            self.assertIn("new", data["mcpServers"])


class TestWireCodexToml(QuietTestCase):
    """Tests for wire_codex_toml function."""

    def test_missing_file_one_plugin_exact_format(self):
        """Missing file + one plugin → exact format with markers and mode 0600."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            plugins = {"serena": {"command": "bash", "args": ["-lc", "x"]}}

            wire_plugins.wire_codex_toml(config_path, plugins)

            self.assertTrue(config_path.exists())
            self.assertEqual(os.stat(config_path).st_mode & 0o777, 0o600)

            content = config_path.read_text()
            self.assertIn("# >>> dev-agent plugin MCP", content)
            self.assertIn("[mcp_servers.serena]", content)
            self.assertIn('command = "bash"', content)
            self.assertIn('args = ["-lc","x"]', content)  # compact JSON
            self.assertIn("# <<< dev-agent plugin MCP", content)
            self.assertTrue(content.endswith("\n"))

    def test_existing_hand_config_survives_above_block(self):
        """Existing hand config + plugins → hand line survives above block."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text("keep = 1\n")

            plugins = {"serena": {"command": "bash", "args": []}}
            wire_plugins.wire_codex_toml(config_path, plugins)

            content = config_path.read_text()
            self.assertTrue(content.startswith("keep = 1\n"))
            self.assertIn("[mcp_servers.serena]", content)

            # Rerun is byte-idempotent
            content1 = content
            wire_plugins.wire_codex_toml(config_path, plugins)
            content2 = config_path.read_text()
            self.assertEqual(content1, content2)

    def test_args_absent_renders_empty_array(self):
        """args absent → renders args = []."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            plugins = {"serena": {"command": "bash"}}  # no args key

            wire_plugins.wire_codex_toml(config_path, plugins)

            content = config_path.read_text()
            self.assertIn("args = []", content)

    def test_toml_escaping_in_command(self):
        """TOML escaping: special chars in command → JSON escapes."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            plugins = {"serena": {"command": 'a"b\\c'}}

            wire_plugins.wire_codex_toml(config_path, plugins)

            content = config_path.read_text()
            # JSON escapes: " → \" and \ → \\
            self.assertIn('command = "a\\"b\\\\c"', content)

    def test_two_plugins_separated_by_blank_line(self):
        """Two plugins → two tables separated by exactly one blank line."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            plugins = {
                "serena": {"command": "bash"},
                "agentic": {"command": "python3"}
            }

            wire_plugins.wire_codex_toml(config_path, plugins)

            content = config_path.read_text()
            # Extract the managed block
            start = content.find("# >>> dev-agent plugin MCP")
            end = content.find("# <<< dev-agent plugin MCP") + len("# <<< dev-agent plugin MCP <<<")
            block = content[start:end]

            # Check two tables with exactly one blank line between them
            self.assertIn("[mcp_servers.serena]", block)
            self.assertIn("[mcp_servers.agentic]", block)
            self.assertIn("args = []\n\n[mcp_servers.agentic]", block)

    def test_empty_plugins_removes_managed_block_keeps_hand_content(self):
        """Empty plugins: managed block REMOVED, hand content survives."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text(
                "keep = 1\n"
                "# >>> dev-agent plugin MCP <<<\n"
                "[mcp_servers.old]\n"
                "# <<< dev-agent plugin MCP <<<\n"
                "keep_me = 2\n"
            )

            wire_plugins.wire_codex_toml(config_path, {})

            content = config_path.read_text()
            self.assertIn("keep = 1", content)
            self.assertIn("keep_me = 2", content)
            self.assertNotIn("[mcp_servers.old]", content)
            self.assertNotIn("# >>> dev-agent plugin MCP", content)

    def test_opening_marker_without_closing_raises_wireerror(self):
        """Opening marker present but no closing marker → WireError, file untouched."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            original = "# >>> dev-agent plugin MCP <<<\nstuff\n"
            config_path.write_text(original)

            with self.assertRaises(wire_plugins.WireError) as cm:
                wire_plugins.wire_codex_toml(config_path, {})
            self.assertIn("repair the markers", str(cm.exception))
            self.assertEqual(config_path.read_text(), original)

    def test_lone_closing_marker_left_in_place(self):
        """Lone closing marker with no opener is left in place."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text("keep = 1\n# <<< dev-agent plugin MCP <<<\n")

            wire_plugins.wire_codex_toml(config_path, {"p": {"command": "x"}})

            content = config_path.read_text()
            self.assertIn("# <<< dev-agent plugin MCP <<<", content)
            self.assertIn("[mcp_servers.p]", content)

    def test_content_between_markers_fully_removed(self):
        """Content between markers (stale entries) fully removed on rewire."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text(
                "# >>> dev-agent plugin MCP <<<\n"
                "[mcp_servers.stale]\n"
                "command = 'old'\n"
                "# <<< dev-agent plugin MCP <<<\n"
            )

            wire_plugins.wire_codex_toml(config_path, {"new": {"command": "bash"}})

            content = config_path.read_text()
            self.assertNotIn("[mcp_servers.stale]", content)
            self.assertIn("[mcp_servers.new]", content)


class TestRunIntegration(QuietTestCase):
    """Integration tests for the run function."""

    def test_full_payload_all_agents_wired(self):
        """Full payload with wire all true, capabilities, plugin, identity → configs generated."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()

            env = {"OBSIDIAN_KEY_0": "LITERALKEY"}
            payload = {
                "wire": {
                    "cursor": True,
                    "gemini": True,
                    "pi": True,
                    "codex": True,
                },
                "capabilities": {
                    "obsidian": True,
                },
                "plugin_mcp_entries": [
                    {"myserena": {"command": "bash", "args": ["-c"]}},   # local
                    {"coding": {"url": "http://host.docker.internal:8811/mcp",  # remote
                                "headers": {"Authorization": "Bearer ${MCP_GATEWAY_TOKEN}"}}},
                ],
                "identities": [
                    {"agent": "cursor-agent", "key_env": "OBSIDIAN_KEY_0"}
                ],
            }

            wire_plugins.run(payload, home, workspace, env)

            # .mcp.json generated (claude) — gets obsidian + BOTH plugins
            self.assertTrue((main_dir / ".mcp.json").exists())
            claude = json.loads((main_dir / ".mcp.json").read_text())["mcpServers"]
            self.assertEqual(set(claude), {"obsidian-annotated", "myserena", "coding"})
            # ~/.claude.json pre-approved
            self.assertTrue((home / ".claude.json").exists())
            # cursor identity (literal key) + LOCAL plugin only (no remote coding)
            cursor_mcp = home / ".cursor" / "mcp.json"
            self.assertTrue(cursor_mcp.exists())
            cursor_data = json.loads(cursor_mcp.read_text())
            self.assertIn("obsidian-annotated", cursor_data["mcpServers"])
            self.assertIn("myserena", cursor_data["mcpServers"])
            self.assertNotIn("coding", cursor_data["mcpServers"])
            self.assertEqual(
                cursor_data["mcpServers"]["obsidian-annotated"]["headers"]["Authorization"],
                "Bearer LITERALKEY"
            )
            # codex managed block carries the local plugin, not the remote one
            codex_toml = (home / ".codex" / "config.toml").read_text()
            self.assertIn("[mcp_servers.myserena]", codex_toml)
            self.assertNotIn("coding", codex_toml)
            # pi config exists
            self.assertTrue((home / ".pi" / "agent" / "mcp.json").exists())
            # gemini config exists
            self.assertTrue((home / ".gemini" / "settings.json").exists())
            # codex config exists
            self.assertTrue((home / ".codex" / "config.toml").exists())

    def test_wire_flags_false_no_agent_configs_created(self):
        """wire flags false → no agent config files created (claude .mcp.json still generated)."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()

            payload = {
                "wire": {
                    "cursor": False,
                    "gemini": False,
                    "pi": False,
                    "codex": False,
                },
                "capabilities": {},
                "plugin_mcp_entries": [],
                "identities": [],
            }

            wire_plugins.run(payload, home, workspace, {})

            # claude .mcp.json still generated
            self.assertTrue((main_dir / ".mcp.json").exists())
            # No agent home configs
            self.assertFalse((home / ".cursor").exists())
            self.assertFalse((home / ".gemini").exists())
            self.assertFalse((home / ".pi").exists())
            self.assertFalse((home / ".codex").exists())

    def test_payload_not_dict_raises_wireerror(self):
        """Payload not a dict raises WireError."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            with self.assertRaises(wire_plugins.WireError):
                wire_plugins.run(["not", "a", "dict"], Path(tmp), workspace, {})

    def test_plugin_entry_non_dict_raises_wireerror(self):
        """plugin_mcp_entries containing non-dict raises WireError."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = Path(tmp) / "workspace"
            workspace.mkdir()
            main_dir = workspace / "main"
            main_dir.mkdir()
            (main_dir / ".git").mkdir()

            payload = {
                "plugin_mcp_entries": ["not a dict"],
            }

            with self.assertRaises(wire_plugins.WireError):
                wire_plugins.run(payload, home, workspace, {})


class TestReservedNames(unittest.TestCase):
    """merge_plugin_entries is the unconditional backstop for reserved names
    (the host-side up.sh check is the fast-fail duplicate)."""

    def test_plugin_squatting_reserved_name_raises(self):
        # obsidian-annotated is the only still-reserved (generated) name.
        with self.assertRaises(wire_plugins.WireError) as cm:
            wire_plugins.merge_plugin_entries([{"obsidian-annotated": {"command": "x"}}])
        self.assertIn("reserved for generated servers", str(cm.exception))

    def test_former_capability_server_names_now_pass(self):
        # coding/proxyman/browser are plugin data now — no longer reserved.
        for name in ("coding", "proxyman", "browser"):
            merged = wire_plugins.merge_plugin_entries([{name: {"url": "http://h/mcp"}}])
            self.assertIn(name, merged)

    def test_ordinary_name_passes(self):
        merged = wire_plugins.merge_plugin_entries([{"serena": {"command": "x"}}])
        self.assertIn("serena", merged)


class TestPreapproveSkipsBadRepoMcpJson(QuietTestCase):
    """A repo-shipped .mcp.json we can't understand must skip pre-approval
    with a warning, not abort the whole wiring run (the file is explicitly
    not ours; the other agents still need their configs)."""

    def _setup(self, tmp, mcp_content):
        home = Path(tmp) / "home"
        home.mkdir()
        workspace = Path(tmp) / "workspace"
        (workspace / "main").mkdir(parents=True)
        (workspace / "main" / ".mcp.json").write_text(mcp_content)
        return home, workspace

    def test_no_mcpservers_object_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, workspace = self._setup(tmp, "{}")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                wire_plugins.preapprove_claude(home, workspace)
            self.assertIn("skipping claude pre-approval", output.getvalue())
            self.assertFalse((home / ".claude.json").exists())

    def test_invalid_json_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, workspace = self._setup(tmp, "{not json")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                wire_plugins.preapprove_claude(home, workspace)
            self.assertIn("skipping claude pre-approval", output.getvalue())
            self.assertFalse((home / ".claude.json").exists())

    def test_symlinked_claude_json_written_through(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, workspace = self._setup(tmp, '{"mcpServers": {"coding": {}}}')
            target = Path(tmp) / "dotfiles-claude.json"
            target.write_text("{}")
            (home / ".claude.json").symlink_to(target)
            wire_plugins.preapprove_claude(home, workspace)
            self.assertTrue((home / ".claude.json").is_symlink())
            data = json.loads(target.read_text())
            proj = data["projects"][str(workspace / "main")]
            self.assertEqual(proj["enabledMcpjsonServers"], ["coding"])


class TestWireCodexTomlMarkerEdges(QuietTestCase):
    """Cases where the old grep guard passed but the sed strip silently ate
    the file to EOF — now hard errors (block still open at end of file)."""

    def test_stray_second_opener_after_closed_block_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            original = (
                "# >>> dev-agent plugin MCP >>>\n"
                "[mcp_servers.old]\n"
                "# <<< dev-agent plugin MCP <<<\n"
                "# >>> dev-agent plugin MCP >>>\n"
                "user_config = 1\n"
            )
            config_path.write_text(original)
            with self.assertRaises(wire_plugins.WireError) as cm:
                wire_plugins.wire_codex_toml(config_path, {"p": {"command": "x"}})
            self.assertIn("repair the markers", str(cm.exception))
            self.assertEqual(config_path.read_text(), original)

    def test_closer_above_opener_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            original = (
                "# <<< dev-agent plugin MCP <<<\n"
                "# >>> dev-agent plugin MCP >>>\n"
                "user_config = 1\n"
            )
            config_path.write_text(original)
            with self.assertRaises(wire_plugins.WireError):
                wire_plugins.wire_codex_toml(config_path, {"p": {"command": "x"}})
            self.assertEqual(config_path.read_text(), original)

    def test_crlf_hand_content_preserved_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_bytes(b"keep = 1\r\nalso = 2\r\n")
            wire_plugins.wire_codex_toml(config_path, {"p": {"command": "x"}})
            content = config_path.read_bytes().decode()
            self.assertTrue(content.startswith("keep = 1\r\nalso = 2\r\n"))
            self.assertIn("[mcp_servers.p]", content)


class TestBuildPayload(unittest.TestCase):
    """Host-side payload assembly: strict [ = \"true\" ] boolean semantics and
    the env-var contract with up.sh."""

    def test_only_literal_true_enables_flags(self):
        env = {"WIRE_CURSOR": "true", "WIRE_GEMINI": "yes", "WIRE_PI": "1",
               "WIRE_CODEX": "True", "CAP_OBSIDIAN": "true"}
        payload = wire_plugins.build_payload(env)
        self.assertEqual(payload["wire"],
                         {"cursor": True, "gemini": False, "pi": False, "codex": False})
        # capabilities carries only obsidian now (gateway/proxyman/browser are
        # plugins and arrive via plugin_mcp_entries).
        self.assertEqual(payload["capabilities"], {"obsidian": True})

    def test_obsidian_flag_off_unless_literal_true(self):
        self.assertEqual(
            wire_plugins.build_payload({"CAP_OBSIDIAN": "yes"})["capabilities"],
            {"obsidian": False})

    def test_missing_env_means_everything_off_and_empty(self):
        payload = wire_plugins.build_payload({})
        self.assertEqual(payload["wire"],
                         {"cursor": False, "gemini": False, "pi": False, "codex": False})
        self.assertEqual(payload["plugin_mcp_entries"], [])
        self.assertEqual(payload["identities"], [])

    def test_plugin_entries_parsed_per_line_blank_lines_ignored(self):
        env = {"PLUGIN_MCP_ENTRIES": '{"serena": {"command": "bash"}}\n\n{"other": {"command": "x"}}\n'}
        payload = wire_plugins.build_payload(env)
        self.assertEqual(payload["plugin_mcp_entries"],
                         [{"serena": {"command": "bash"}}, {"other": {"command": "x"}}])

    def test_invalid_entry_line_raises(self):
        with self.assertRaises(wire_plugins.WireError) as cm:
            wire_plugins.build_payload({"PLUGIN_MCP_ENTRIES": "{broken\n"})
        self.assertIn("invalid JSON", str(cm.exception))

    def test_non_object_entry_line_raises(self):
        with self.assertRaises(wire_plugins.WireError):
            wire_plugins.build_payload({"PLUGIN_MCP_ENTRIES": "[1, 2]\n"})

    def test_identities_pairs_parse_codex_keyless(self):
        env = {"IDENTITY_AGENTS": "cursor-agent:IDENTITY_KEY_0 pi:IDENTITY_KEY_1 codex:"}
        payload = wire_plugins.build_payload(env)
        self.assertEqual(payload["identities"], [
            {"agent": "cursor-agent", "key_env": "IDENTITY_KEY_0"},
            {"agent": "pi", "key_env": "IDENTITY_KEY_1"},
            {"agent": "codex", "key_env": ""},
        ])

    def test_round_trips_through_run(self):
        """The payload build_payload emits is exactly what run() consumes, and
        a remote plugin reaches Claude only (Phase 1) while a local one reaches
        every agent."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            home.mkdir()
            workspace = Path(tmp) / "workspace"
            (workspace / "main" / ".git").mkdir(parents=True)
            gateway = ('{"coding": {"url": "http://host.docker.internal:8811/mcp",'
                       '"headers": {"Authorization": "Bearer ${MCP_GATEWAY_TOKEN}"}}}')
            env = {"WIRE_CURSOR": "true", "CAP_OBSIDIAN": "true",
                   "PLUGIN_MCP_ENTRIES": '{"serena": {"command": "bash"}}\n' + gateway + "\n",
                   "IDENTITY_AGENTS": "cursor-agent:K0", "K0": "SECRET"}
            payload = json.loads(json.dumps(wire_plugins.build_payload(env)))
            with contextlib.redirect_stdout(io.StringIO()):
                wire_plugins.run(payload, home, workspace, env)
            cursor = json.loads((home / ".cursor" / "mcp.json").read_text())
            # cursor: local plugin + its obsidian identity, NOT the remote server
            self.assertIn("serena", cursor["mcpServers"])
            self.assertNotIn("coding", cursor["mcpServers"])
            self.assertEqual(
                cursor["mcpServers"]["obsidian-annotated"]["headers"]["Authorization"],
                "Bearer SECRET")
            mcp = json.loads((workspace / "main" / ".mcp.json").read_text())
            # claude: obsidian (generated) + both plugins; remote gains type:http
            self.assertEqual(list(mcp["mcpServers"]), ["obsidian-annotated", "serena", "coding"])
            self.assertEqual(mcp["mcpServers"]["coding"]["type"], "http")


class TestMainSubprocess(unittest.TestCase):
    """Test main() entry point via subprocess."""

    def test_invalid_json_stdin_exits_1_with_error_message(self):
        """main() with invalid JSON on stdin → exit 1, 'Error: invalid JSON payload'."""
        import subprocess
        module_path = Path(__file__).parent.parent / "src" / "wire_plugins.py"
        result = subprocess.run(
            [sys.executable, str(module_path)],
            input=b"{invalid",
            capture_output=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Error: invalid JSON payload", result.stdout)


if __name__ == "__main__":
    unittest.main()
