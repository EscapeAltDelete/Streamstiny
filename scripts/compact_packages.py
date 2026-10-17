"""Compact the pinned FFmpegKit cache without changing its revision or iOS binaries."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args], text=True).strip()


def compact(root):
    root = root.resolve()
    lock = json.loads((root / "Package.resolved").read_text())
    pin = next(pin for pin in lock["pins"] if pin["identity"] == "ffmpegkit")
    checkout = root / "checkouts/FFmpegKit"
    revision = pin["state"]["revision"]
    assert git(checkout, "rev-parse", "HEAD") == revision, "Checkout must match Package.resolved"
    assert not git(checkout, "status", "--porcelain"), "Preserve dependency edits"
    gitdir = Path(git(checkout, "rev-parse", "--absolute-git-dir"))
    patterns = ["/*"]
    for framework in sorted((checkout / "Sources").glob("*.xcframework")):
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        selected = [entry["LibraryIdentifier"] for entry in info["AvailableLibraries"]
                    if entry["SupportedPlatform"] == "ios" and not entry.get("SupportedPlatformVariant")
                    and "arm64" in entry["SupportedArchitectures"]]
        path = framework.relative_to(checkout).as_posix()
        patterns.append(f"!/{path}/*/")
        patterns.extend(f"/{path}/{slice}/" for slice in selected)
    sparse = "\n".join(patterns) + "\n"
    sparse_file = gitdir / "info/sparse-checkout"
    if (gitdir / "shallow").exists() and sparse_file.exists() and sparse_file.read_text() == sparse:
        print("Verified compact FFmpegKit cache at", revision)
        return
    repositories = [path for path in (root / "repositories").iterdir()
                    if path.name.lower().startswith("ffmpegkit") and path.is_dir()]
    assert len(repositories) == 1, "Expected the pinned FFmpegKit repository"
    repository = repositories[0]
    with tempfile.TemporaryDirectory(dir=root.parent, prefix="compact-") as temporary:
        temporary = Path(temporary)
        new = temporary / "repository.git"
        subprocess.run(["git", "clone", "--quiet", "--bare", "--no-local", "--depth=1", "--branch", pin["state"]["version"], repository.as_uri(), str(new)], check=True)
        assert git(new, "rev-parse", "HEAD") == revision
        git(new, "remote", "set-url", "origin", pin["location"])
        backup = temporary / "original.git"
        repository.rename(backup)
        new.rename(repository)
        try:
            replacement = temporary / "checkout"
            subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(repository), str(replacement)], check=True)
            subprocess.run(["git", "-C", str(replacement), "sparse-checkout", "set", "--no-cone", "--stdin"], input=sparse, text=True, check=True)
            git(replacement, "reset", "--hard", revision)
            git(replacement, "fsck", "--connectivity-only")
            assert git(replacement, "rev-parse", "HEAD") == revision
            assert not git(replacement, "status", "--porcelain")
        except BaseException:
            shutil.rmtree(repository)
            backup.rename(repository)
            raise
        original = temporary / "original-checkout"
        try:
            checkout.rename(original)
            replacement.rename(checkout)
        except BaseException:
            if original.exists():
                original.rename(checkout)
            shutil.rmtree(repository)
            backup.rename(repository)
            raise
    print("Compacted FFmpegKit at", revision, "for iOS ARM64")


if __name__ == "__main__":
    compact(Path("build/SourcePackages"))
