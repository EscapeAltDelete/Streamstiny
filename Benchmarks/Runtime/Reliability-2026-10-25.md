# Chat and playback reliability — 25 October 2026

## Diagnoses and changes

**Cached-asset warning.** Production `https://www.destiny.gg/embed/chat`
currently publishes `data-cdn="https://r2cdn.destiny.gg"` and an explicitly empty
`data-cache-key=""`. Discovery rejected the empty value. Additionally, the old
refresh deadline did not schedule work: an open chat could remain stale without
another load trigger. Discovery now accepts the verified empty-key configuration,
revalidates its catalog, and schedules refresh/recovery while active. Failed
downloads preserve the last validated snapshot. Successful synchronization clears
the warning; unchanged catalogs retain their rendering revision. Suspension
cancels work and resumption restarts recovery. Failed images share bounded,
coalesced recovery rather than acquiring individual retry workers.

Existing first-party endpoints, URLSession HTTP caching/revalidation, four-request
concurrency, cancellation and request deduplication remain. Snapshot validation
rejects empty catalogs and HTML error documents masquerading as stylesheets.
There is no manually maintained asset list or new cache implementation.

**False AngelThump termination.** The player classified decoder `.finished`
without an accompanying error as an ended broadcast. That is insufficient
evidence for a live source. One playback status now owns UI state, and both EOF
and the existing stall detector enter the same recovery path. Recovery refreshes
provider information, replaces media in the existing player, and preserves
quality, audio and low-latency configuration. Retries use 1/2/4-second delays,
stop after three attempts, and reset after sustained healthy playback, an
explicit Retry, a stream switch or an actual network restoration. Pause/stop and
selection cancel conflicting work. Provider offline evidence, or a validated
media ENDLIST for direct HLS, confirms termination. HTTP failures and malformed
playlists do not. No additional buffering or transport extension was introduced.

**Scrolling pauses.** Every retained-history update wrote the scroll offset,
including zero-distance corrections, and pruning rewrote it during interaction.
Zero-distance writes are skipped. Pruned offscreen rows release their resources
immediately but retain measured space during the gesture/inertia. One correction
after scrolling settles removes that space and preserves the visible anchor.
Incoming messages render immediately. Backgrounding cancels gesture correction;
foregrounding releases retained space. Stable row identity, existing history
bounds, native scroll-view interaction state and the current WebKit renderer are
retained. No alternate renderer or message-dropping policy was introduced.

**Plain-text emotes.** All four names are in the current authoritative catalog.
ARRIVE, Classic and HUH contain animated AVIF even where their URL ends in GIF.
Their alpha movie track uses the primary-picture handler and lacks the auxiliary
declaration required by Apple's decoder. Branding changes did not fix it;
lossless remuxing did. The shared loader now repairs this specific ISO-BMFF
container defect using its existing alpha metadata. AV1 samples, timing, color,
transparency and original file offsets are preserved; valid assets are unchanged.
The parser is bounded and returns unsupported/malformed inputs unchanged. This
adds no decoder, conversion library or secondary asset pipeline. BlackGuyLaptop
already decoded correctly; catalog refresh/recovery fixes stale or failed lookup
without modifying its bytes.

**Show Bitrate.** A persisted setting in Playback preferences controls a small
player overlay. It uses the enabled video track's encoded bitrate metadata, or
audio metadata for audio-only playback. Positive values display kbps/Mbps;
missing values display unavailable. It samples at most once per second using
the existing player tick, only when enabled. It clears on switches/termination
and suppresses potentially misleading master metadata during Twitch backup
splicing. This is not network throughput and adds no request or media pipeline.

## Native rendering evidence

Apple ImageIO decoded these current CDN assets before/after container repair:

| Emote | Original frames decoded | Repaired frames decoded | Body bytes before → after |
| --- | ---: | ---: | ---: |
| ARRIVE | 0 | 81/81 | 28,281 → 30,188 |
| BlackGuyLaptop | 81/81 | 81/81 | 34,525 → 34,525 |
| Classic | 0 | 51/51 | 31,572 → 33,271 |
| HUH | 0 | 94/94 | 35,553 → 37,564 |

The full 347-emote catalog decoded with zero failures. Actual cropped WKWebView
snapshots of the four reported emotes each produced eight distinct frame hashes,
verifying visible animation rather than merely successful requests. Existing
Listening, pepeW, PepoPunch sprite/CSS and badge checks also passed. Tests retain
case-sensitive token matching, repeated/mixed/adjacent tokens and ordinary-word
boundaries rather than hardcoding these names in production.

## Measurements

Two paired Catalyst runs used optimized builds, Xcode 16.4, macos-15, the same
runner within each pair, baseline `bd3fced`, the current harness, and identical
current asset loading for both refs (`shared_assets=true`). This isolates the
scrolling change; it is not a benchmark of the broken original asset pipeline.
The optimized copy ran first. HTTP/image caches were cleared between copies.
CPU totals include the application and its WebKit processes; 100% means one core.
RSS is the sum of process resident sizes, not iPad physical-memory accounting.

Target workload: 5,000 retained messages, simulated scrolling, 100 incoming
messages/second, 500 arrivals observed in each copy. No messages were dropped.

| Metric | Pair 1 before → after | Pair 2 before → after |
| --- | ---: | ---: |
| Browser FPS | 34.31 → 55.33 | 27.03 → 41.46 |
| p95 browser frame interval | 59 → 36 ms | 59 → 50 ms |
| Median model-update-to-DOM latency | 30 → 21 ms | 35 → 26 ms |
| p95 model-update-to-DOM latency | 58 → 29 ms | 49 → 35 ms |
| Renderer offset writes during interaction | 100 → 0 | 100 → 0 |
| Offset corrections after interaction | 0 → 1 | 0 → 1 |
| Combined CPU | 121.88 → 96.44% | 130.34 → 117.52% |
| Combined median RSS | 607.59 → 588.62 MiB | 594.87 → 570.85 MiB |

That is 53–61% higher FPS, 29–50% lower p95 DOM latency, 10–21% less CPU
and 3–4% less median RSS in this workload. DOM latency starts at benchmark model
publication; it excludes WebSocket delivery, the existing publication queue and
final screen painting. Scrolling is scripted, not physical finger input.

There is substantial runner variance. Following the live bottom with 5,000
messages improved 34.53→51.16 FPS in pair 1 but worsened 40.98→22.35 in pair 2.
The 1,000-message animated workload was 55.92→59.43 and 60.04→59.12 FPS;
its CPU and RSS did not improve consistently. These results do not establish
universal CPU/memory improvement or sustained 60 FPS. The deterministic result
is eliminating interfering offset writes; targeted scrolling improved in both
pairs. Full phase metrics are in [the raw summary](reliability-2026-10-25.json).

Pair 1's performance phases passed, but its later baseline-only visual test
failed before emote nodes were ready. Explicit catalog/layout readiness checks
were added; the complete pair 2 suite passed for both versions. The original
failure is retained in the linked run artifacts, not counted as a passing suite.

## Validation and limits

- Changes are confined to chat discovery/loading/store/renderer coordination;
  `ChatImageFormat.swift`; playback resolver, status, player and settings;
  Twitch backup provenance; their regression tests and benchmark harness.
  There are no new application dependencies or changes to the strict ad filter,
  provider-specific low-latency transports, or chat connection protocol.
- The final release-build review passed all 19 Python tooling tests, the compiled
  Swift regression executable and optimized ARM64 Release/package validation.
  The complete browser renderer suite also passed with zero reported failures.
- Deterministic regression tests cover offline restart with disk assets,
  scheduled outage recovery and warning clearing, unchanged empty-key catalogs,
  invalid HTTP-200 content, suspension and bounded image recovery.
- AVIF tests cover sample/offset preservation, idempotence, valid unchanged
  input, truncated prefixes, oversized boxes and nonimages.
- Playback tests cover retry policy, cancellation, connectivity transitions,
  bitrate formatting/unknown values, valid master/media ENDLIST, live manifests,
  403/404/429/5xx and malformed responses. Existing Twitch ad/encryption,
  Kick prefetch/discontinuity, YouTube, resolver and quality tests remain.
- Browser regression tests verify immediate arrival rendering, no gesture-time
  offset writes, preserved anchors, one idle correction and background recovery,
  plus existing picker/search/animation/cache/cancellation behavior.
- Native Catalyst tests exercise real WebKit rendering, ImageIO, screenshots,
  asset-cache persistence, message actions and pruning. ARM64 Release packaging
  is validated separately by the app workflow. The final native suite passed
  six tests with zero failures, including the real cache-location persistence
  check and eight distinct visible frames for each reported emote.

No physical iPad, 120-Hz device, GPU/energy profiling or extended device playback
session was available. The default AngelThump Destiny channel was offline during
the live probe; no affected live channel was supplied. Thus the erroneous state
transition is proven in source and corrected, with deterministic policy/provider
tests, but the user's exact live interruption and real decoder recovery were not
reproduced end-to-end. PiP, real adaptive bitrate transitions, foreground audio
and network handover still need device checks. Bitrate enable/disable ownership
is inspected and compiles; there is no physical-player UI automation claim.

Large retained histories still require linear model reconciliation and carry
substantial WebKit memory. Worst-case tested scrolling remains below 60 FPS.
The final lifecycle cleanup only affects background/foreground transitions and
is covered by regression tests; paired foreground measurements precede it.
The last change after the review patch only corrects the no-cache failure text
to say that retry is automatic; the main-branch build validates that final text.

Evidence: [paired run 1](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40182649729),
[complete paired run 2](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40184011588),
[final native validation](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40184791084),
[final release-build review](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40184789433).
