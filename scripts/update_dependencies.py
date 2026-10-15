"""Propose stable, same-major playback updates without changing patch checksums."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


PACKAGES = ("KSPlayer", "FFmpegKit")
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"


def pin_pattern(name):
    return re.compile(
        rf"(?m)^(  {name}:\n    url: https://github\.com/kingslay/{name}\.git\n"
        rf"    exactVersion: )(?P<version>{VERSION})(?=\n|$)"
    )


def pins(manifest):
    result = {}
    for name in PACKAGES:
        matches = list(pin_pattern(name).finditer(manifest))
        if len(matches) != 1:
            raise ValueError(f"Expected one exactVersion pin for kingslay/{name}")
        result[name] = matches[0]["version"]
    return result


def version_tuple(version):
    return tuple(map(int, version.split(".")))


def latest_compatible(current, tag_listing):
    candidates = {current}
    for line in tag_listing.splitlines():
        match = re.fullmatch(rf"[0-9a-f]+\s+refs/tags/v?({VERSION})", line)
        if match and version_tuple(match[1])[0] == version_tuple(current)[0]:
            candidates.add(match[1])
    return max(candidates, key=version_tuple)


def remote_tags(name):
    return subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", f"https://github.com/kingslay/{name}.git"],
        check=True, capture_output=True, text=True, timeout=30,
    ).stdout


def replacements(root, current, target):
    """Plan all edits before writing; preserve all unrelated content."""
    manifest = (root / "dependencies.yml").read_text(encoding="utf-8")
    if pins(manifest) != current:
        raise ValueError("Dependency pins changed while preparing the update")
    for name in PACKAGES:
        manifest = pin_pattern(name).sub(lambda match: match[1] + target[name], manifest)
    result = {root / "dependencies.yml": manifest}
    for relative in ("README.md", "Streamstiny/ThirdPartyNotices/Sources.txt"):
        path = root / relative
        text = path.read_text(encoding="utf-8")
        for name in PACKAGES:
            text = re.sub(
                rf"\b{re.escape(name)} {re.escape(current[name])}(?![\w-]|\.\w)",
                lambda _: f"{name} {target[name]}", text,
            )
            text = text.replace(
                f"https://github.com/kingslay/{name}/tree/{current[name]}\n",
                f"https://github.com/kingslay/{name}/tree/{target[name]}\n",
            )
        result[path] = text
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report updates without writing files")
    args = parser.parse_args()
    root = Path.cwd()
    current = pins((root / "dependencies.yml").read_text(encoding="utf-8"))
    target = {name: latest_compatible(current[name], remote_tags(name)) for name in PACKAGES}
    changed = current != target
    branch = f"dependencies/playback-{target['KSPlayer']}-{target['FFmpegKit']}"
    print(json.dumps({"current": current, "proposed": target, "changed": changed, "branch": branch}))
    if args.check:
        return
    if changed:
        for path, text in replacements(root, current, target).items():
            path.write_text(text, encoding="utf-8")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"changed={str(changed).lower()}\nbranch={branch}\n")


if __name__ == "__main__":
    main()
