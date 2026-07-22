"""Guard: every per-container named volume mounted under /home/coder must have its
mountpoint pre-created (owned by coder) in the Dockerfile.

Docker seeds a fresh named volume from the image directory it mounts over — copying
that directory's ownership. If the mountpoint does NOT exist in the image, Docker
creates it root-owned and the coder-run agent can't write there. That is exactly how
cursor-agent's ~/.config/cursor auth silently failed to persist. This test fails if a
compose named-volume target under /home/coder is missing from the Dockerfile mkdir.
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).parent.parent
COMPOSE = REPO / "compose" / "docker-compose.local.yml"
DOCKERFILE = REPO / "Dockerfile"

HOME = "/home/coder"
# A compose volume line: "- <source>:<target>[:ro]". A *named* volume source is a
# bare identifier (no "/" and no "${...}"), which distinguishes it from bind mounts
# like ${KEYS_PATH} or ${ARTIFACTS_PATH}.
_VOL_LINE = re.compile(r"^\s*-\s*([A-Za-z0-9_-]+):(/home/coder/[^:\s]+)(:ro)?\s*$")


def named_volume_targets_under_home():
    targets = set()
    for line in COMPOSE.read_text().splitlines():
        m = _VOL_LINE.match(line)
        if m and not m.group(3):  # skip read-only mounts (no ownership needs)
            targets.add(m.group(2))
    return targets


def dockerfile_precreated_dirs():
    """Dirs from the 'Auth/state dirs pre-created as coder' mkdir -p block."""
    text = DOCKERFILE.read_text()
    # Grab the RUN mkdir -p block that follows the auth-dirs comment, joining the
    # backslash-continued lines into one.
    block = re.search(
        r"Auth/state dirs pre-created.*?\n(RUN mkdir -p (?:[^\n\\]*\\\n)*[^\n]*)",
        text,
        re.DOTALL,
    )
    assert block, "could not find the auth-dirs 'RUN mkdir -p' block in Dockerfile"
    joined = block.group(1).replace("\\\n", " ")
    dirs = set(re.findall(r"/home/\$USERNAME/(\S+)", joined))
    return {f"{HOME}/{d}" for d in dirs}


class AuthVolumeDirTests(unittest.TestCase):
    def test_every_named_volume_mountpoint_is_precreated(self):
        targets = named_volume_targets_under_home()
        created = dockerfile_precreated_dirs()
        missing = targets - created
        self.assertFalse(
            missing,
            f"named volume(s) mounted under {HOME} but not pre-created in the "
            f"Dockerfile mkdir (will mount root-owned): {sorted(missing)}",
        )

    def test_cursor_auth_dir_is_covered(self):
        # The regression that motivated this test: the token lives in ~/.config/cursor.
        self.assertIn(f"{HOME}/.config/cursor", named_volume_targets_under_home())
        self.assertIn(f"{HOME}/.config/cursor", dockerfile_precreated_dirs())

    def test_parsing_found_the_expected_auth_dirs(self):
        # Sanity-check the parsers actually matched something meaningful.
        targets = named_volume_targets_under_home()
        self.assertIn(f"{HOME}/.claude", targets)
        self.assertIn(f"{HOME}/.config/gh", targets)


if __name__ == "__main__":
    unittest.main()
