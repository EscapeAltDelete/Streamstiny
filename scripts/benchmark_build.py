"""Measure Release builds without changing compiler optimization or app behavior."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time


def run(command, log):
    started = time.monotonic()
    with log.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    elapsed = time.monotonic() - started
    if result.returncode:
        print(log.read_text()[-12000:])
        raise subprocess.CalledProcessError(result.returncode, command)
    text = log.read_text()
    return {
        "seconds": round(elapsed, 3),
        "swift_compiles": len(re.findall(r"^SwiftCompile ", text, re.MULTILINE)),
        "asset_compiles": len(re.findall(r"^CompileAssetCatalogVariant ", text, re.MULTILINE)),
        "tasks": dict(re.findall(r"^(.+?) \(\d+ tasks?\) \| ([\d.]+) seconds$", text, re.MULTILINE)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, choices=("baseline", "optimized"))
    args = parser.parse_args()
    output = Path("build/benchmarks")
    output.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild", "build", "-project", "Streamstiny.xcodeproj", "-scheme", "Streamstiny",
        "-configuration", "Release", "-destination", "generic/platform=iOS",
        "-clonedSourcePackagesDirPath", "build/SourcePackages", "-disableAutomaticPackageResolution",
        "-skipPackageUpdates", "-derivedDataPath", "build/device", "-jobs",
        subprocess.check_output(["sysctl", "-n", "hw.logicalcpu"], text=True).strip(),
        "-parallelizeTargets", "-showBuildTimingSummary", "ARCHS=arm64", "CODE_SIGNING_ALLOWED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO", "MARKETING_VERSION=0.0.1", "CURRENT_PROJECT_VERSION=1",
    ]
    results = {
        "label": args.label, "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "machine": platform.machine(), "cpus": command[command.index("-jobs") + 1],
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "package_lock_sha256": hashlib.sha256(Path("build/SourcePackages/Package.resolved").read_bytes()).hexdigest(),
        "command": command, "builds": {},
    }
    source = Path("Streamstiny/ChatAttachmentSize.swift")
    original = source.read_bytes()
    source_stat = source.stat()
    try:
        shutil.rmtree("build/device", ignore_errors=True)
        for name in ("clean", "warm", "incremental", "fresh_checkout"):
            if name == "incremental":
                source.write_bytes(original + b"\n// Benchmark: invalidate one source file without changing behavior.\n")
            if name == "fresh_checkout":
                source.write_bytes(original)
                # Establish a cache matching the original source before simulating checkout.
                run(command, output / f"{args.label}-reset.log")
                subprocess.run(["python3", "scripts/build_input_times.py", "save"], check=True)
                for directory in (Path("Streamstiny"), Path("Streamstiny.xcodeproj")):
                    for path in directory.rglob("*"):
                        if not path.is_symlink():
                            os.utime(path, None)
                    os.utime(directory, None)
                subprocess.run(["python3", "scripts/build_input_times.py", "restore"], check=True)
            results["builds"][name] = run(command, output / f"{args.label}-{name}.log")
            (output / f"{args.label}.json").write_text(json.dumps(results, indent=2) + "\n")
            print(name, results["builds"][name], flush=True)
    finally:
        if source.read_bytes() != original:
            source.write_bytes(original)
            os.utime(source, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
    subprocess.run(["python3", "scripts/build_input_times.py", "save"], check=True)
    subprocess.run(["bash", "scripts/package.sh"], check=True)
    subprocess.run(["du", "-sk", "build/SourcePackages", "build/device"], check=True)
    frameworks = sorted(Path("build/SourcePackages/artifacts").rglob("*.xcframework"))
    sizes = []
    for framework in frameworks:
        for path in sorted(framework.iterdir()):
            if path.is_dir():
                kb = int(subprocess.check_output(["du", "-sk", str(path)], text=True).split()[0])
                sizes.append({"path": str(path), "kb": kb})
    (output / f"{args.label}-package-sizes.json").write_text(json.dumps(sizes, indent=2) + "\n")


if __name__ == "__main__":
    main()
