"""Generate an isolated iOS chat benchmark from the actual production sources."""
from pathlib import Path
import shutil

root = Path("build/chat-benchmark")
source = root / "Sources"
source.mkdir(parents=True, exist_ok=True)
names = [*Path("Streamstiny").glob("Chat*.swift"), *Path("Streamstiny").glob("Emote*.swift")]
names += [Path("Streamstiny") / name for name in ["AssetDownloadQueue.swift", "StreamSource.swift", "DestinyAccount.swift", "TokenStore.swift"]]
for path in names:
    text = path.read_text()
    if path.name == "EmoteStore.swift":
        # Hold the catalog source constant when measuring the legacy decoder.
        text = text.replace('"https://cdn.destiny.gg/" + path', '"https://r2cdn.destiny.gg/" + path')
        text = text.replace("let (data, response) = try await session.data(from: url)", "ChatBenchmarkMetrics.requests += 1\n        let (data, response) = try await session.data(from: url)\n        ChatBenchmarkMetrics.bytes += data.count")
    (source / path.name).write_text(text)
shutil.copy("Benchmarks/Chat/Host.swift", source)
for path in Path("Streamstiny").glob("Chat*.js"):
    shutil.copy(path, source)
shutil.copy("Benchmarks/Chat/ChatBenchmarkTests.swift", root)
(root / "project.yml").write_text("""name: ChatBenchmark
options:
  deploymentTarget:
    iOS: '17.0'
settings:
  base:
    SWIFT_VERSION: '5.0'
    CODE_SIGNING_ALLOWED: NO
    GENERATE_INFOPLIST_FILE: YES
    SWIFT_OPTIMIZATION_LEVEL: '-O'
    ENABLE_TESTABILITY: YES
    SUPPORTS_MACCATALYST: YES
    DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO
targets:
  ChatBenchmark:
    type: application
    platform: iOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: gg.streamstiny.chatbenchmark
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
  ChatBenchmarkTests:
    type: bundle.unit-test
    platform: iOS
    sources: [ChatBenchmarkTests.swift]
    dependencies:
      - target: ChatBenchmark
schemes:
  ChatBenchmark:
    build:
      targets:
        ChatBenchmark: all
        ChatBenchmarkTests: [test]
    test:
      targets: [ChatBenchmarkTests]
""")
