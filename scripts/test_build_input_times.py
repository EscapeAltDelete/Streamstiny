"""Regression checks for safe reuse of Xcode inputs from the build cache."""

import json
import os
from pathlib import Path
import tempfile
import unittest

import build_input_times as times


class BuildInputTimesTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name).resolve()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        os.utime(path, ns=(1_000_000_000, 1_000_000_000))
        return path

    def test_fresh_checkout_restores_only_identical_inputs(self):
        unchanged = self.write("Streamstiny/Keep.swift", "unchanged")
        changed = self.write("Streamstiny/Edit.swift", "old")
        project = self.write("Streamstiny.xcodeproj/project.pbxproj", "generated")
        removed = self.write("Streamstiny/Removed.swift", "removed")
        times.save(self.root)
        changed.write_text("new", encoding="utf-8")
        removed.unlink()
        added = self.write("Streamstiny/New.swift", "new file")
        for path in (unchanged, changed, project, added):
            os.utime(path, ns=(2_000_000_000, 2_000_000_000))
        times.restore(self.root)
        self.assertEqual(unchanged.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual(project.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual(changed.stat().st_mtime_ns, 2_000_000_000)
        self.assertEqual(added.stat().st_mtime_ns, 2_000_000_000)
        self.assertEqual(changed.read_text(), "new")

    def test_cache_miss_and_corrupt_manifest_leave_inputs_untouched(self):
        source = self.write("Streamstiny/App.swift", "source")
        times.restore(self.root)
        state = self.root / times.STATE
        state.parent.mkdir(parents=True)
        for content in ("{", "[]", json.dumps({"Streamstiny/App.swift": {"mtime_ns": "bad"}})):
            state.write_text(content)
            times.restore(self.root)
            self.assertEqual(source.stat().st_mtime_ns, 1_000_000_000)

    def test_symlinks_cannot_change_other_files(self):
        external = self.write("other/External.swift", "outside input directories")
        sources = self.root / "Streamstiny"
        sources.mkdir()
        (sources / "Link.swift").symlink_to(external)
        (sources / "LinkedDirectory").symlink_to(external.parent, target_is_directory=True)
        times.save(self.root)
        self.assertEqual(json.loads((self.root / times.STATE).read_text()), {})
        times.restore(self.root)
        self.assertEqual(external.stat().st_mtime_ns, 1_000_000_000)

    def test_changed_generated_project_keeps_fresh_timestamp(self):
        project = self.write("Streamstiny.xcodeproj/project.pbxproj", "old settings")
        times.save(self.root)
        project.write_text("new settings")
        fresh = project.stat().st_mtime_ns
        times.restore(self.root)
        self.assertEqual(project.stat().st_mtime_ns, fresh)


if __name__ == "__main__":
    unittest.main()
