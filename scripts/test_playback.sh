#!/bin/bash
set -euo pipefail
sources=(Streamstiny/{ChatModels,ChatProtocol,HLSPlaylist,TwitchAdPlaylist,PlaylistGateway,StreamSource,PlaybackResolver,PlaybackStatus,YouTubeResolver,TwitchResolver}.swift)
# Also permits checking historical references with the same benchmark tooling.
if [ -f Streamstiny/ChatAssets.swift ]; then
  sources+=(Streamstiny/{ChatAssets,ChatAssetLoader,ChatImageFormat,ChatHTML,ChatLinks,EmoteStore,AssetDownloadQueue}.swift)
fi
output="${RUNNER_TEMP:-/tmp}/streamstiny-regression-tests"
xcrun swiftc -swift-version 5 -parse-as-library "${sources[@]}" Tests/*.swift -o "$output"
"$output"
