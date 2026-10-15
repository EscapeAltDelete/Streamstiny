# Building Streamstiny

This is a source-only repository. It contains no executable files under `.github/workflows`, so the transferred code cannot start GitHub Actions builds. Do not enable Actions or install build workflows on this account unless the owner explicitly requests it.

The previous build configuration is preserved at [build.yml.disabled](build.yml.disabled) for reference. Its old build-repository destination is historical and must be reviewed before any future reuse. GitHub does not execute this file.

## Local native builds

Use macOS with Xcode 16.4 selected and XcodeGen 2.44.1 installed:

```sh
xcodegen generate
xcodebuild -resolvePackageDependencies -project Streamstiny.xcodeproj -scheme Streamstiny -clonedSourcePackagesDirPath build/SourcePackages -skipPackageUpdates
python3 scripts/patch_playback.py
xcodebuild build -project Streamstiny.xcodeproj -scheme Streamstiny -configuration Release -destination 'generic/platform=iOS' -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates -derivedDataPath build/device ARCHS=arm64 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
bash scripts/package.sh
```

## Regression checks

These checks use Foundation and run locally on macOS or Linux with Swift 6.1.3. Set `SWIFTC` to the compiler path and `MODULE_CACHE` to a writable cache directory if needed.

```sh
SWIFTC=swiftc
MODULE_CACHE=/tmp/streamstiny-swift-module-cache
"$SWIFTC" -module-cache-path "$MODULE_CACHE" Streamstiny/HLSPlaylist.swift Streamstiny/TwitchAdPlaylist.swift Tests/TwitchAdPlaylistTests.swift -o /tmp/twitch-ad-tests
/tmp/twitch-ad-tests
"$SWIFTC" -module-cache-path "$MODULE_CACHE" Streamstiny/ChatModels.swift Streamstiny/ChatProtocol.swift Streamstiny/StreamSource.swift Streamstiny/ChatSize.swift Streamstiny/ChatVisibility.swift Streamstiny/ChatScrollAnchor.swift Streamstiny/ChatAttachmentSize.swift Tests/ChatPresentationTests.swift -o /tmp/chat-presentation-tests
/tmp/chat-presentation-tests
"$SWIFTC" -O -module-cache-path "$MODULE_CACHE" Streamstiny/ChatTextRules.swift Streamstiny/AssetDownloadQueue.swift Tests/ResourceEfficiencyTests.swift -o /tmp/resource-efficiency-tests
/tmp/resource-efficiency-tests
```

UIKit interaction, rotation, playback, battery use, and memory pressure need validation on an iOS device.
