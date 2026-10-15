"""Check version selection and the limited scope of automated dependency edits."""

import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import update_dependencies as updates


MANIFEST = """packages:
  KSPlayer:
    url: https://github.com/kingslay/KSPlayer.git
    exactVersion: 2.3.4
  FFmpegKit:
    url: https://github.com/kingslay/FFmpegKit.git
    exactVersion: 6.1.3
"""


def tags(*versions):
    return "\n".join(f"{'a' * 40}\trefs/tags/{version}" for version in versions)


class DependencyUpdateTests(unittest.TestCase):
    def test_numeric_sort_ignores_major_bumps_and_unstable_tags(self):
        listing = tags("6.1.4", "6.1.10", "6.2.0-beta.1", "9.0.2", "6.1", "6.1.3.1")
        self.assertEqual(updates.latest_compatible("6.1.3", listing), "6.1.10")

    def test_prefixed_tags_are_supported(self):
        self.assertEqual(updates.latest_compatible("2.3.4", tags("v2.4.0")), "2.4.0")

    def test_does_not_downgrade_or_select_peeled_refs(self):
        self.assertEqual(updates.latest_compatible("2.3.4", tags("2.3.3", "2.9.0^{}")), "2.3.4")
        self.assertEqual(updates.latest_compatible("2.3.4", ""), "2.3.4")

    def test_unknown_manifest_format_fails_instead_of_silently_skipping(self):
        with self.assertRaises(ValueError):
            updates.pins(MANIFEST.replace("exactVersion", "from"))
        with self.assertRaises(ValueError):
            updates.pins(MANIFEST + MANIFEST)

    def workspace(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "dependencies.yml").write_text(MANIFEST)
        (root / "README.md").write_text("KSPlayer 2.3.4 and FFmpegKit 6.1.3.\n")
        notices = root / "Streamstiny/ThirdPartyNotices/Sources.txt"
        notices.parent.mkdir(parents=True)
        notices.write_text(
            "FFmpegKit 6.1.3 (GPLv3)\n"
            "https://github.com/kingslay/FFmpegKit/tree/6.1.3\n"
            "Unrelated FFmpegKit 6.1.30 remains unchanged.\n"
        )
        return root

    def test_plans_pins_and_notice_updates_without_touching_other_files(self):
        root = self.workspace()
        current = updates.pins(MANIFEST)
        target = dict(current, FFmpegKit="6.1.4")
        edits = updates.replacements(root, current, target)
        self.assertEqual(updates.pins(edits[root / "dependencies.yml"]), target)
        self.assertIn("FFmpegKit 6.1.4", edits[root / "README.md"])
        notices = edits[root / "Streamstiny/ThirdPartyNotices/Sources.txt"]
        self.assertIn("/tree/6.1.4\n", notices)
        self.assertIn("Unrelated FFmpegKit 6.1.30 remains unchanged.", notices)
        self.assertEqual(len(edits), 3)
        self.assertEqual((root / "dependencies.yml").read_text(), MANIFEST)

    def test_pin_change_during_preparation_fails(self):
        root = self.workspace()
        with self.assertRaises(ValueError):
            updates.replacements(root, {"KSPlayer": "2.3.3", "FFmpegKit": "6.1.3"}, updates.pins(MANIFEST))

    def test_dry_run_does_not_write_files_or_actions_outputs(self):
        root = self.workspace()
        before = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
        with patch.object(updates.Path, "cwd", return_value=root), \
             patch.object(updates, "remote_tags", side_effect=lambda name: tags("2.3.4" if name == "KSPlayer" else "6.1.4")), \
             patch("sys.argv", ["update_dependencies.py", "--check"]), \
             patch.dict(os.environ, {"GITHUB_OUTPUT": str(root / "outputs")}), \
             contextlib.redirect_stdout(io.StringIO()):
            updates.main()
        self.assertFalse((root / "outputs").exists())
        self.assertEqual(before, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})

    def test_apply_is_repeatable_and_keeps_exact_pins(self):
        root = self.workspace()
        output = root / "outputs"
        with patch.object(updates.Path, "cwd", return_value=root), \
             patch.object(updates, "remote_tags", side_effect=lambda name: tags("2.3.4" if name == "KSPlayer" else "6.1.4")), \
             patch("sys.argv", ["update_dependencies.py"]), \
             patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
             contextlib.redirect_stdout(io.StringIO()):
            updates.main()
            self.assertIn("changed=true", output.read_text())
            output.unlink()
            updated = (root / "dependencies.yml").read_bytes()
            updates.main()
        self.assertIn("changed=false", output.read_text())
        self.assertEqual(updated, (root / "dependencies.yml").read_bytes())
        self.assertEqual(updates.pins(updated.decode())["FFmpegKit"], "6.1.4")


if __name__ == "__main__":
    unittest.main()
