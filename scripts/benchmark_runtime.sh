#!/bin/bash
set -euo pipefail
source_root="${1:-.}/Streamstiny"
sources=()
for name in ChatModels ChatProtocol HLSPlaylist TwitchAdPlaylist StreamSource PlaybackResolver YouTubeResolver TwitchResolver ChatHTML ChatLinks ChatAssets; do
  sources+=("$source_root/$name.swift")
done
output="${RUNNER_TEMP:-/tmp}/streamstiny-runtime-benchmark"
xcrun swiftc -O -swift-version 5 -parse-as-library "${sources[@]}" Benchmarks/Runtime/RuntimeBenchmarks.swift -o "$output"
"$output"
