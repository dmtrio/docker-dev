#!/usr/bin/env python3
"""Unit tests for src/manifest.py (Phase 2 of the Python extraction).

Table-driven: every validation rule the old up.sh bash enforced is a row
here, with the EXACT error message the bash produced (parity was verified
against the extracted old code before the port landed). The yq/jq semantic
quirks (`//` on false, contains() substring matching, agent-suffix case
order) get dedicated pins so a future "cleanup" can't change them silently.
"""

import contextlib
import io
import json
import shlex
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
import manifest as m

SERENA = {"install": "x", "mcp": {"serena": {"command": "bash", "args": ["-lc", "s"]}},
          "egress": ["blob.core.windows.net"]}
OTHER = {"install": "x", "mcp": {"other-tool": {"command": "python3"}}, "egress": []}
PLUGIN_FILES = {"serena": SERENA, "other": OTHER}
ENV = {"SECRET_KEY_VARS": "OBSIDIAN_KEY_me_claude OBSIDIAN_WATCH_KEY_w_pi",
       "SECRETS_FILE": "/sec/secrets.env"}


def derive(man, plugin_files=None, env=None):
    return m.derive(man, PLUGIN_FILES if plugin_files is None else plugin_files,
                    ENV if env is None else env)


class TestErrorTable(unittest.TestCase):
    """Every named error, with the exact old-bash message."""

    CASES = [
        ("bad forge", {"forge": "bitbucket"}, None,
         "forge must be github or gitea"),
        ("scalar plugins", {"plugins": "serena"}, None,
         "manifest plugins: must be a list, e.g. plugins: [serena]"),
        ("plugin name charset", {"plugins": ["../evil"]}, None,
         "manifest plugins failed validation:\n"
         "  plugin '../evil': illegal characters (allowed: letters, digits, underscore, dash)"),
        ("missing plugin file", {"plugins": ["ghost"]}, None,
         "manifest plugins failed validation:\n"
         "  plugin 'ghost': no plugin file at plugins/ghost.yml"),
        ("aggregated plugin errors", {"plugins": ["../evil", "ghost"]}, None,
         "manifest plugins failed validation:\n"
         "  plugin '../evil': illegal characters (allowed: letters, digits, underscore, dash)\n"
         "  plugin 'ghost': no plugin file at plugins/ghost.yml"),
        ("remote without ssh", {"remote": {"tmux": True}}, None,
         "manifest has remote: but no ssh: section — remote access rides the SSH login path (add ssh.port)"),
        ("bad notify kind", {"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "slack"}}, None,
         "remote.notify must be 'ntfy' (got 'slack')"),
        ("notify without tmux", {"ssh": {"port": 22}, "remote": {"notify": "ntfy"}}, None,
         "remote.notify requires remote.tmux: true (the idle monitor runs inside the tmux session)"),
        ("malformed mosh ports",
         {"ssh": {"port": 22}, "remote": {"mosh": True, "mosh_ports": "9:banana"}}, None,
         "remote.mosh_ports must be START:END (got '9:banana')"),
        ("mosh ports below 1024",
         {"ssh": {"port": 22}, "remote": {"mosh": True, "mosh_ports": "500:600"}}, None,
         "remote.mosh_ports '500:600' out of range (need 1024 <= START <= END <= 65535)"),
        ("mosh ports above 65535",
         {"ssh": {"port": 22}, "remote": {"mosh": True, "mosh_ports": "60000:70000"}}, None,
         "remote.mosh_ports '60000:70000' out of range (need 1024 <= START <= END <= 65535)"),
        ("mosh ports inverted",
         {"ssh": {"port": 22}, "remote": {"mosh": True, "mosh_ports": "3000:2000"}}, None,
         "remote.mosh_ports '3000:2000' out of range (need 1024 <= START <= END <= 65535)"),
        ("illegal ref char", {"identities": {"obsidian": ["bad-dash_claude"]}}, None,
         "manifest identity references failed validation:\n"
         "  obsidian ref 'bad-dash_claude': illegal characters (allowed: letters, digits, underscore)"),
        ("unknown agent suffix", {"identities": {"obsidian": ["me_nobody"]}}, None,
         "manifest identity references failed validation:\n"
         "  obsidian ref 'me_nobody': suffix is not a known agent (_claude/_codex/_pi/_gemini/_cursor_agent)"),
        ("secret missing", {"identities": {"obsidian": ["gone_claude"]}}, None,
         "manifest identity references failed validation:\n"
         "  obsidian ref 'gone_claude': OBSIDIAN_KEY_gone_claude not found in /sec/secrets.env"),
        ("aggregated identity errors",
         {"identities": {"obsidian": ["bad-dash_claude"], "watch": ["w_nobody"]}}, None,
         "manifest identity references failed validation:\n"
         "  obsidian ref 'bad-dash_claude': illegal characters (allowed: letters, digits, underscore)\n"
         "  watch ref 'w_nobody': suffix is not a known agent (_claude/_codex/_pi/_gemini/_cursor_agent)"),
        ("ntfy url missing",
         {"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "ntfy"}}, ENV,
         "manifest has remote.notify: ntfy but NTFY_URL is missing from /sec/secrets.env"),
        ("ntfy url with hash",
         {"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "ntfy"}},
         dict(ENV, NTFY_URL="https://x.com/#frag"),
         "NTFY_URL must be a bare origin (no '#', quotes) — put the topic in NTFY_TOPIC"),
        ("ntfy url unparseable",
         {"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "ntfy"}},
         dict(ENV, NTFY_URL="https:///path"),
         "cannot parse a host from NTFY_URL 'https:///path'"),
    ]

    def test_error_table(self):
        for name, man, env, message in self.CASES:
            with self.subTest(name):
                with self.assertRaises(m.ManifestError) as cm:
                    derive(man, env=env)
                self.assertEqual(str(cm.exception), message)

    PLUGIN_MCP_CASES = [
        ("dot in server name", {"bad.name": {"command": "x"}},
         "plugin 'p' mcp server 'bad.name': illegal characters in name (allowed: letters, digits, underscore, dash — it becomes a TOML/JSON key)"),
        ("reserved name", {"coding": {"command": "x"}},
         "plugin 'p' mcp server 'coding': name is reserved for generated servers"),
        ("non-string command", {"srv": {"command": 1}},
         "plugin 'p' mcp server 'srv': command must be a string (local stdio server)"),
        ("extra field", {"srv": {"command": "x", "env": {"A": "b"}}},
         "plugin 'p' mcp server 'srv': unsupported field(s): env (only command and args are wired, identically for every agent)"),
    ]

    def test_plugin_mcp_error_table(self):
        for name, mcp, message in self.PLUGIN_MCP_CASES:
            with self.subTest(name):
                files = {"p": {"install": "x", "mcp": mcp}}
                with self.assertRaises(m.ManifestError) as cm:
                    derive({"plugins": ["p"]}, plugin_files=files)
                self.assertEqual(str(cm.exception), message)

    def test_bad_plugin_egress_domain(self):
        for bad in ("https://x.com", "x.com/path", "*.foo.com", "foo", "a b.com"):
            with self.subTest(bad):
                files = {"p": {"install": "x", "egress": [bad]}}
                with self.assertRaises(m.ManifestError) as cm:
                    derive({"plugins": ["p"]}, plugin_files=files)
                self.assertEqual(
                    str(cm.exception),
                    f"plugin 'p' egress entry '{bad}' is not a bare hostname (no scheme, path, port, or wildcard — a domain already covers its subdomains)")

    def test_duplicate_server_name_across_plugins(self):
        files = {"a": {"mcp": {"srv": {"command": "x"}}},
                 "b": {"mcp": {"srv": {"command": "y"}}}}
        with self.assertRaises(m.ManifestError) as cm:
            derive({"plugins": ["a", "b"]}, plugin_files=files)
        self.assertEqual(str(cm.exception),
                         "multiple enabled plugins define the same MCP server name: srv")


class TestYqSemanticsPins(unittest.TestCase):
    """The jq/yq quirks the port must NOT silently fix."""

    def test_alternative_operator_fires_on_false(self):
        d = derive({"plugins": False, "repo": False, "memory": False, "tools": False})
        self.assertEqual(d["PLUGINS"], "")
        self.assertEqual(d["REPO_URL"], "")
        self.assertEqual(d["MEM_LIMIT"], "2g")
        self.assertEqual(d["INSTALL_AIDER"], "true")  # default tool set

    def test_tools_contains_is_substring_match(self):
        d = derive({"tools": ["claude-code"]})
        self.assertEqual(d["INSTALL_CLAUDE"], "true")   # jq contains() quirk
        self.assertEqual(d["INSTALL_CODEX"], "false")

    def test_cap_flags_render_raw_scalars(self):
        d = derive({"capabilities": {"gateway": "yes", "proxyman": 1, "browser": True}})
        self.assertEqual(d["CAP_GATEWAY"], "yes")
        self.assertEqual(d["CAP_PROXYMAN"], "1")
        self.assertEqual(d["CAP_BROWSER"], "true")
        # only the literal "true" opens host ports
        self.assertEqual(d["HOST_MCP_PORTS"], "8814")

    def test_agent_suffix_case_order(self):
        self.assertEqual(m.agent_for_ref("x_cursor_agent"), "cursor-agent")
        self.assertEqual(m.agent_for_ref("weird_claude_cursor_agent"), "cursor-agent")
        self.assertEqual(m.agent_for_ref("cursor_agent"), "")  # no leading _
        self.assertEqual(m.agent_for_ref("a_pi"), "pi")
        self.assertEqual(m.agent_for_ref("nope"), "")


class TestDerivedValues(unittest.TestCase):
    def test_defaults_on_empty_manifest(self):
        d = derive({})
        self.assertEqual(d["FORGE"], "github")
        self.assertEqual(d["MEM_LIMIT"], "2g")
        self.assertEqual(d["SSH_BIND"], "127.0.0.1")
        self.assertEqual(d["INSTALL_CLAUDE"], "true")
        self.assertEqual(d["EGRESS"], "")
        self.assertEqual(d["PLUGIN_MCP_ENTRIES"], "")

    def test_git_fallbacks_from_env(self):
        d = derive({}, env=dict(ENV, GIT_NAME_DEFAULT="N", GIT_EMAIL_DEFAULT="e@x"))
        self.assertEqual(d["GIT_USER_NAME"], "N")
        self.assertEqual(d["GIT_USER_EMAIL"], "e@x")
        d = derive({"git": {"name": "M"}}, env=dict(ENV, GIT_NAME_DEFAULT="N"))
        self.assertEqual(d["GIT_USER_NAME"], "M")

    def test_host_mcp_ports_combos(self):
        d = derive({"capabilities": {"gateway": True, "browser": True}})
        self.assertEqual(d["HOST_MCP_PORTS"], "8811,8814")

    def test_obsidian_identity_implies_egress(self):
        d = derive({"identities": {"obsidian": ["me_claude"]}})
        self.assertEqual(d["EGRESS"], "mcp-obsidian.dmetr.io")
        self.assertEqual(d["OBS_REF_AGENTS"], "me_claude:claude")

    def test_plugin_egress_folds_with_literal_dedup(self):
        files = {"p": {"egress": ["api.foo.com"]}}
        d = derive({"capabilities": {"egress": ["api-foo.com"]}, "plugins": ["p"]},
                   plugin_files=files)
        # api-foo.com must NOT swallow api.foo.com (the old regex-dot bug)
        self.assertEqual(d["EGRESS"], "api-foo.com,api.foo.com")
        d2 = derive({"capabilities": {"egress": ["api.foo.com"]}, "plugins": ["p"]},
                    plugin_files=files)
        self.assertEqual(d2["EGRESS"], "api.foo.com")

    def test_plugin_mcp_entries_one_line_json_per_plugin(self):
        d = derive({"plugins": ["serena", "other"]})
        lines = d["PLUGIN_MCP_ENTRIES"].splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(json.loads(lines[0]), SERENA["mcp"])
        self.assertEqual(json.loads(lines[1]), OTHER["mcp"])
        self.assertTrue(d["PLUGIN_MCP_ENTRIES"].endswith("\n"))

    def test_mosh_defaults_and_dash_form(self):
        d = derive({"ssh": {"port": 22}, "remote": {"mosh": True}})
        self.assertEqual(d["MOSH_PORTS"], "60000:60010")
        self.assertEqual(d["MOSH_PORTS_DASH"], "60000-60010")

    def test_ntfy_host_strip_order_path_before_userinfo(self):
        env = dict(ENV, NTFY_URL="https://ntfy.example.com/a@b", NTFY_TOPIC="t")
        d = derive({"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "ntfy"}}, env=env)
        # '@' in the PATH must not masquerade as userinfo
        self.assertIn("ntfy.example.com", d["EGRESS"].split(","))
        self.assertEqual(d["CONTAINER_NTFY_URL"], "https://ntfy.example.com/a@b")
        self.assertEqual(d["CONTAINER_NTFY_TOPIC"], "t")

    def test_ntfy_userinfo_and_port_stripped(self):
        env = dict(ENV, NTFY_URL="https://user@h.example.com:8443")
        d = derive({"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "ntfy"}}, env=env)
        self.assertIn("h.example.com", d["EGRESS"].split(","))

    def test_ntfy_ip_literal_goes_to_cidrs(self):
        env = dict(ENV, NTFY_URL="http://10.1.2.3:8080/p")
        d = derive({"ssh": {"port": 22}, "remote": {"tmux": True, "notify": "ntfy"},
                    "capabilities": {"egress_cidrs": ["10.1.2.3/32"]}}, env=env)
        self.assertEqual(d["EGRESS_CIDRS"], "10.1.2.3/32")  # deduped
        self.assertNotIn("10.1.2.3", d["EGRESS"])


class TestRenderAndStdin(unittest.TestCase):
    def test_render_shell_quoting_round_trips(self):
        d = m.Derived({"A": "plain", "B": "has space", "C": "it's; $HOME `x`"})
        rendered = d.render()
        out = subprocess.run(
            ["bash", "-c", rendered + 'printf "%s|%s|%s" "$A" "$B" "$C"'],
            capture_output=True, text=True)
        self.assertEqual(out.stdout, "plain|has space|it's; $HOME `x`")

    def test_read_stdin_docs(self):
        stream = io.StringIO('{"plugins": ["p"]}\np\t{"mcp": {}}\n')
        man, files = m.read_stdin_docs(stream)
        self.assertEqual(man, {"plugins": ["p"]})
        self.assertEqual(files, {"p": {"mcp": {}}})

    def test_read_stdin_null_manifest_is_empty(self):
        man, files = m.read_stdin_docs(io.StringIO("null\n"))
        self.assertEqual(man, {})

    def test_read_stdin_errors(self):
        with self.assertRaises(m.ManifestError):
            m.read_stdin_docs(io.StringIO(""))
        with self.assertRaises(m.ManifestError):
            m.read_stdin_docs(io.StringIO("{bad\n"))
        with self.assertRaises(m.ManifestError):
            m.read_stdin_docs(io.StringIO('{}\nno-tab-here\n'))

    def test_main_derive_end_to_end(self):
        module = Path(__file__).parent.parent / "src" / "manifest.py"
        out = subprocess.run(
            [sys.executable, str(module), "--derive"],
            input='{"memory": "3g"}\n', capture_output=True, text=True,
            env={"SECRETS_FILE": "/s", "PATH": "/usr/bin:/bin"})
        self.assertEqual(out.returncode, 0)
        self.assertIn("MEM_LIMIT=3g\n", out.stdout)

    def test_main_error_goes_to_stderr_exit_1(self):
        module = Path(__file__).parent.parent / "src" / "manifest.py"
        out = subprocess.run(
            [sys.executable, str(module), "--derive"],
            input='{"forge": "bad"}\n', capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin"})
        self.assertEqual(out.returncode, 1)
        self.assertEqual(out.stdout, "")
        self.assertIn("Error: forge must be github or gitea", out.stderr)


if __name__ == "__main__":
    unittest.main()
