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
            if path.is_file() and path.resolve() == path.absolute():
                yield path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(root):
    records = {
        path.relative_to(root).as_posix(): {
            "sha256": digest(path), "mtime_ns": path.stat().st_mtime_ns
        }
        for path in inputs(root)
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
        if record.get("sha256") == digest(path):
            os.utime(path, ns=(path.stat().st_atime_ns, mtime))
            restored += 1
    print(f"Restored timestamps for {restored} unchanged build inputs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("save", "restore"))
    args = parser.parse_args()
    {"save": save, "restore": restore}[args.mode](Path.cwd().resolve())
