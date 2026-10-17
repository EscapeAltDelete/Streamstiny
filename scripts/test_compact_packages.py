"""Exercise real Git shared checkouts, shallow history and iOS slice selection."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from compact_packages import compact, git


class CompactPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        subprocess.run(["git", "init", "--quiet", str(self.source)], check=True)
        git(self.source, "config", "user.name", "EscapeAltDelete")
        git(self.source, "config", "user.email", "96600150+EscapeAltDelete@users.noreply.github.com")
        libraries = []
        for name, platform, variant in [("ios-arm64", "ios", None), ("macos-arm64_x86_64", "macos", None), ("ios-arm64_x86_64-simulator", "ios", "simulator")]:
            path = self.source / "Sources/Example.xcframework" / name
            path.mkdir(parents=True)
            (path / "binary").write_bytes(name.encode())
            entry = dict(LibraryIdentifier=name, SupportedPlatform=platform, SupportedArchitectures=["arm64"])
            if variant: entry["SupportedPlatformVariant"] = variant
            libraries.append(entry)
        (self.source / "Sources/Example.xcframework/Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libraries}))
        git(self.source, "add", ".")
        git(self.source, "commit", "--quiet", "-m", "pinned fixture")
        git(self.source, "tag", "-a", "6.1.4", "-m", "pinned version")
        self.revision = git(self.source, "rev-parse", "HEAD")
        (self.source / "history.txt").write_text("later revision")
        git(self.source, "add", ".")
        git(self.source, "commit", "--quiet", "-m", "later fixture")
        self.later_revision = git(self.source, "rev-parse", "HEAD")
        self.cache = self.root / "SourcePackages"
        (self.cache / "repositories").mkdir(parents=True)
        (self.cache / "checkouts").mkdir()
        self.repository = self.cache / "repositories/FFmpegKit.git"
        self.checkout = self.cache / "checkouts/FFmpegKit"
        subprocess.run(["git", "clone", "--quiet", "--bare", str(self.source), str(self.repository)], check=True)
        subprocess.run(["git", "clone", "--quiet", "--shared", str(self.repository), str(self.checkout)], check=True)
        git(self.checkout, "checkout", "--detach", "--quiet", self.revision)
        (self.cache / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "ffmpegkit", "location": str(self.source), "state": {"revision": self.revision, "version": "6.1.4"}}]}))

    def test_pinned_bytes_git_integrity_clean_status_and_repeatability(self):
        binary = self.checkout / "Sources/Example.xcframework/ios-arm64/binary"
        original = binary.read_bytes()
        unused = git(self.checkout, "rev-parse", "HEAD:Sources/Example.xcframework/macos-arm64_x86_64/binary")
        lock = (self.cache / "Package.resolved").read_bytes()
        compact(self.cache)
        self.assertEqual(binary.read_bytes(), original)
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.revision)
        self.assertEqual(git(self.checkout, "status", "--porcelain"), "")
        self.assertEqual(git(self.checkout, "rev-list", "--count", "HEAD"), "1")
        self.assertFalse((binary.parent.parent / "macos-arm64_x86_64").exists())
        self.assertFalse((binary.parent.parent / "ios-arm64_x86_64-simulator").exists())
        self.assertEqual((self.cache / "Package.resolved").read_bytes(), lock)
        git(self.checkout, "fsck", "--full")
        git(self.repository, "fsck", "--full")
        self.assertIn("?" + unused, git(self.repository, "rev-list", "--objects", "--missing=print", "HEAD"))
        alternates = self.checkout / ".git/objects/info/alternates"
        self.assertEqual(alternates.read_text().strip(), str(self.repository / "objects"))
        before = binary.stat().st_mtime_ns
        compact(self.cache)
        self.assertEqual(binary.stat().st_mtime_ns, before)

    def test_dirty_checkouts_are_preserved(self):
        path = self.checkout / "Sources/Example.xcframework/ios-arm64/binary"
        path.write_text("local edit")
        with self.assertRaises(AssertionError): compact(self.cache)
        self.assertEqual(path.read_text(), "local edit")
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.revision)

    def test_mismatched_pins_are_rejected(self):
        git(self.checkout, "checkout", "--detach", "--quiet", self.later_revision)
        with self.assertRaises(AssertionError): compact(self.cache)

    def test_source_history_preserves_patches_untracked_files_and_timestamps(self):
        repository = self.cache / "repositories/KSPlayer.git"
        checkout = self.cache / "checkouts/KSPlayer"
        subprocess.run(["git", "clone", "--quiet", "--bare", str(self.source), str(repository)], check=True)
        subprocess.run(["git", "clone", "--quiet", "--shared", str(repository), str(checkout)], check=True)
        git(checkout, "checkout", "--detach", "--quiet", self.revision)
        # Large histories use longer automatic abbreviations than compact clones.
        git(checkout, "config", "core.abbrev", "12")
        lock = self.cache / "Package.resolved"
        data = json.loads(lock.read_text())
        data["pins"].append(dict(data["pins"][0], identity="ksplayer"))
        lock.write_text(json.dumps(data))
        binary = checkout / "Sources/Example.xcframework/ios-arm64/binary"
        binary.write_bytes(b"existing dependency patch")
        (checkout / "untracked.txt").write_text("preserve me")
        before = {path.relative_to(checkout): (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in checkout.rglob("*") if path.is_file() and ".git" not in path.parts}
        compact(self.cache, "ksplayer")
        self.assertEqual(before, {path.relative_to(checkout): (path.read_bytes(), path.stat().st_mtime_ns)
                                 for path in checkout.rglob("*") if path.is_file() and ".git" not in path.parts})
        self.assertEqual(git(checkout, "rev-list", "--count", "HEAD"), "1")
        git(checkout, "fsck", "--full")
        git(repository, "fsck", "--full")
        compact(self.cache, "ksplayer")
