"""Preserve unchanged Xcode input mtimes across fresh Actions checkouts.

Git checkout and XcodeGen otherwise make unchanged files newer than restored
DerivedData. Content hashes ensure changed files always keep their fresh mtimes.
Run from the repository root; the manifest belongs to the compiled-products cache.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path


STATE = Path("build/device/ci-inputs.json")


def inputs(root):
    for directory in ("Streamstiny", "Streamstiny.xcodeproj"):
        for path in sorted((root / directory).rglob("*")):
            # Never change targets outside the checkout, including symlinked parents.
            if path.resolve() != path.absolute():
                continue
            asset_directory = path.is_dir() and any(
                parent.suffix == ".xcassets" for parent in (path, *path.parents))
            if path.is_file() or asset_directory:
                yield path


def digest(path):
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    children = sorted(path.rglob("*"))
    if any(child.resolve() != child.absolute() for child in children):
        return None
    contents = [(child.relative_to(path).as_posix(), "directory" if child.is_dir() else digest(child))
                for child in children]
    return hashlib.sha256(json.dumps(contents).encode()).hexdigest()


def save(root):
    records = {
        path.relative_to(root).as_posix(): {
            "sha256": checksum, "mtime_ns": path.stat().st_mtime_ns
        }
        for path in inputs(root) if (checksum := digest(path)) is not None
    }
    state = root / STATE
    state.parent.mkdir(parents=True, exist_ok=True)
    temporary = state.with_suffix(".tmp")
    temporary.write_text(json.dumps(records, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(state)
    print(f"Saved timestamps for {len(records)} build inputs")


def restore(root):
    state = root / STATE
    if not state.exists():
        print("No cached input timestamps; building with fresh timestamps")
        return
    try:
        records = json.loads(state.read_text(encoding="utf-8"))
        if not isinstance(records, dict):
            raise ValueError("Expected a timestamp map")
    except (ValueError, UnicodeError):
        print("Ignoring invalid cached input timestamps; rebuilding")
        return
    restored = 0
    for path in inputs(root):
        record = records.get(path.relative_to(root).as_posix())
        if not isinstance(record, dict):
            continue
        mtime = record.get("mtime_ns")
        if type(mtime) is not int or not 0 <= mtime <= 2**63 - 1:
            continue
        checksum = digest(path)
        if checksum is not None and record.get("sha256") == checksum:
            os.utime(path, ns=(path.stat().st_atime_ns, mtime))
            restored += 1
    print(f"Restored timestamps for {restored} unchanged build inputs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("save", "restore"))
    args = parser.parse_args()
    {"save": save, "restore": restore}[args.mode](Path.cwd().resolve())
