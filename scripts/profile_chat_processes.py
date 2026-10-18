"""Sample benchmark + newly created WebKit processes, including their RSS."""
import json
from pathlib import Path
import subprocess
import sys
import time


def processes():
    result = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time=,comm="], text=True)
    return [line.strip().split(None, 4) for line in result.splitlines() if line.strip()]


def webkit(command):
    return "com.apple.WebKit.WebContent" in command or "com.apple.WebKit.Networking" in command


existing = {row[0] for row in processes() if webkit(row[4])}
with Path(sys.argv[1]).open("w") as output:
    while True:
        selected = [row for row in processes()
                    if "/ChatBenchmark.app/" in row[4] or (webkit(row[4]) and row[0] not in existing)]
        output.write(json.dumps({"unix": time.time(), "total_rss_bytes": sum(int(row[2]) * 1024 for row in selected),
                                 "processes": selected}) + "\n")
        output.flush()
        time.sleep(0.2)
