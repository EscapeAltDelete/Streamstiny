"""Regression checks for safe reuse of Xcode inputs from the build cache."""

import json
import os
import shutil
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

    def test_asset_catalog_directories_restore_when_contents_match(self):
        image = self.write("Streamstiny/Assets.xcassets/AppIcon.appiconset/Icon.png", "image")
        catalog, icon = image.parent.parent, image.parent
        for path in (catalog, icon):
            os.utime(path, ns=(1_000_000_000, 1_000_000_000))
        times.save(self.root)
        for path in (image, catalog, icon):
            os.utime(path, ns=(2_000_000_000, 2_000_000_000))
        times.restore(self.root)
        for path in (image, catalog, icon):
            self.assertEqual(path.stat().st_mtime_ns, 1_000_000_000)

    def test_asset_changes_additions_deletions_and_renames_keep_fresh_catalog(self):
        for change in ("content", "add", "delete", "rename", "directory"):
            with self.subTest(change=change):
                image = self.write("Streamstiny/Assets.xcassets/AppIcon.appiconset/Icon.png", "image")
                catalog = image.parent.parent
                os.utime(catalog, ns=(1_000_000_000, 1_000_000_000))
                times.save(self.root)
                if change == "content": image.write_text("new image")
                elif change == "add": self.write(str(image.parent.relative_to(self.root) / "New.png"), "new")
                elif change == "delete": image.unlink()
                elif change == "directory": (image.parent / "New.imageset").mkdir()
                else: image.rename(image.with_name("Renamed.png"))
                os.utime(catalog, ns=(2_000_000_000, 2_000_000_000))
                times.restore(self.root)
                self.assertEqual(catalog.stat().st_mtime_ns, 2_000_000_000)
                shutil.rmtree(catalog)

    def test_asset_catalog_with_external_symlink_is_not_restored(self):
        external = self.write("other/image.png", "outside")
        catalog = self.root / "Streamstiny/Assets.xcassets"
        catalog.mkdir(parents=True)
        (catalog / "image.png").symlink_to(external)
        times.save(self.root)
        os.utime(catalog, ns=(2_000_000_000, 2_000_000_000))
        times.restore(self.root)
        self.assertEqual(catalog.stat().st_mtime_ns, 2_000_000_000)
        self.assertEqual(external.stat().st_mtime_ns, 1_000_000_000)


if __name__ == "__main__":
    unittest.main()
