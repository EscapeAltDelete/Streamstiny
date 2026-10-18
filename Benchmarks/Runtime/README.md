# Runtime optimization follow-up

Measured 18 October 2026 against `185e4ae66e78a85fb9c4b2fd2cb9fedfef2e5b39`
(the WebKit chat overhaul), preserving functionality and the existing architecture.
No application dependency or second rendering implementation was introduced.

The Twitch date-range pre-parsing optimization was subsequently reverted at the
user’s request while investigating unavailable clean streams. Its measurements
below describe v0.0.15 and do not describe the current playlist parser. The chat
optimizations remain. Twitch ad blocking now always uses the former Force-mode
behavior behind one toggle.

## Audit and changes

The audit covered chat models, filtering, rendering, resource ownership, image
loading, connection/reconnect handling, playback controls, provider resolvers,
Twitch's local playlist gateway, authentication/session lifetimes, and the build
configuration. Changes target demonstrated work rather than replacing working
subsystems.

- **One retained message cache.** Removed duplicate Swift dictionaries containing
  full messages and already-transmitted HTML. The rendering-input cache supplies
  context-menu actions as well as change detection. Removed messages are pruned
  in place instead of rebuilding the whole dictionary each batch. Reveal/hide
  state is included in the cached input so invalidation preserves menu ownership.
- **Reuse unchanged row attributes.** Unchanged messages no longer recompute
  highlights, user/tag attributes, spotlight hashes, or focus state on every
  batch. A small per-surface rendering context covers metadata/options, caller
  revision, chat/user/tag revision and identity, focus, and mention preferences.
  Context changes still recompute attributes; actual HTML is emitted only when
  the rendered input changes. This retains correctness when a caller omits the
  optional revision argument.
- **Local asset completion.** Removed EmoteStore's observer registry and the
  broadcast of every image result to every WebKit surface. Results now go to the
  coordinator that owns the request. The canonical shared loader still deduplicates
  downloads across surfaces and independently completes each subscriber.
- **Single-pass escaping.** Ordinary strings return without five Foundation
  replacement passes. Strings containing markup characters use one UTF-8 output
  buffer, preserving Unicode and the original five escaping rules.
- **Parse Twitch ad intervals once.** Parse each advertised date range once per
  manifest instead of reparsing its dates for each segment. Retain conservative
  treatment of invalid/missing dates, trigger handling, encryption boundaries,
  discontinuities, rendition fallback and sequence rules.

Download concurrency remains four, with subscriber cancellation, bounded transient
retries, HTTP caching/revalidation, explicit corrupt-image cache bypass, and the
last good coherent metadata snapshot. Socket backoff, provider authorization and
client compatibility paths, stream-end handling, audio recovery, and playback
buffer/rate safeguards remain intact. None was removed merely to reduce code.

## Measurement method

`chat-benchmark.yml` runs optimized Catalyst builds on the same `macos-15` runner
with Xcode 16.4. Both refs use the same current benchmark harness and published
347-emote catalog. Metadata snapshots and HTTP caches are cleared for both cold
starts. Warm picker reopening follows without clearing. Both copies explicitly
animate because the hosted runner reports Reduce Motion enabled; production
accessibility behavior is unchanged.

Workloads include a 541×600 picker, 1000 retained messages behind it, animated
chat at a target 100 messages/s, a 5000-message plain history under the same
incoming rate, and hiding the renderer while retaining/updating the feed.
Synchronous native refresh times and separate browser rAF intervals are captured;
app display callbacks are not substituted for browser frame measurements.
Content-ready means the first nonempty DOM, not completion of visible image decoding.
A process sampler with a 200 ms delay between `ps` calls includes the app and
newly created WebKit/GPU/network processes; actual intervals include sampling overhead. RSS is not physical footprint; CPU percentages use one core = 100%.
GPU utilization, battery drain, and energy are not measured.

The Foundation microbenchmark compiles the actual production sources with `-O`.
Each workload has a separate first-call observation, warm-up, and five repeated
samples. Its checksum must match between versions. The 40-segment playlists
with 4/16 non-overlapping date ranges are synthetic stress cases, not a claim
that every Twitch manifest contains that many ranges. Normal/ad-free parsing is
included as a control. All benchmark/profiling instrumentation stays outside the
application target.

## Results

Final [paired run 39125094686](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/39125094686)
compares the original ref to the source released as **v0.0.15** (`ccf5b40`).
[Captured measurements](results.json) include all five microbenchmark samples,
first-call timings, phase latencies, frame intervals, memory and CPU estimates.
These are observed samples, not device guarantees or statistical confidence
intervals.

| Warm Foundation workload | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Escape 100,000 plain strings | 956 ms | 16.8 ms | 98.2% |
| Escape 100,000 markup strings | 964 ms | 62.6 ms | 93.5% |
| Render 10,000 message bodies | 2579 ms | 1254 ms | 51.4% |
| Parse 100 playlists, 4 ranges each | 2016 ms | 283 ms | 86.0% |
| Parse 100 playlists, 16 ranges each | 6373 ms | 438 ms | 93.1% |

The unmodified ad-free control varied from 302 to 238 ms; this illustrates runner
and execution-order variability and is not credited to an optimization. The
larger gains also appeared in preceding paired runs. Both versions produced the
same benchmark checksum, 96,124,797. First-call observations are in the JSON:
for example the 16-range parser took 52.5 versus 4.0 ms before warm-up. These
microbenchmarks do not mean the complete video player is 93% faster.

| Native / browser workload | Before | After |
| --- | ---: | ---: |
| 1000-message native refresh median / p95 | 7.03 / 10.75 ms | 2.72 / 4.92 ms |
| 1000-message browser FPS | 59.5 | 59.5 |
| 1000-message app RSS | 216.8 MiB | 196.4 MiB |
| 1000-message total median RSS | 419.1 MiB | 402.9 MiB |
| 5000-message native refresh median / p95 | 28.78 / 39.70 ms | 10.95 / 15.96 ms |
| 5000-message total synchronous native refresh work | 3325 ms | 1151 ms |
| 5000-message browser FPS / p95 frame interval | 17.8 / 77 ms | 28.1 / 59 ms |
| 5000-message app RSS | 316.3 MiB | 265.9 MiB |
| 5000-message total median / peak RSS | 618.4 / 623.9 MiB | 547.8 / 556.5 MiB |
| 5000-message combined CPU, one core = 100% | 147.5% | 120.0% |

For 5000 messages, median native refresh work drops **62.0%**, app RSS drops
**50.4 MiB (15.9%)**, total median RSS drops **70.6 MiB (11.4%)**, and browser FPS
rises **58%**. The isolated final context-cache change was also measured against
the intermediate cache cleanup in [run 39124917907](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/39124917907):
5000-message median native refresh fell 18.26 to 10.86 ms on that runner.
Refresh instrumentation includes coalesced early-return calls; their counts and
synchronous totals are included rather than assuming every invocation is a full
redraw. Each incoming phase delivers 500 synthetic messages; scheduler stalls mean
the target 100 messages/s is not a guaranteed achieved rate.

| Picker / hidden phase | Before | After |
| --- | ---: | ---: |
| Cold content-ready | 892 ms | 1331 ms |
| Warm content-ready | 605 ms | 559 ms |
| Scrolling browser FPS | 56.9 | 57.3 |
| Scrolling total median / peak RSS | 475.3 / 503.1 MiB | 461.5 / 493.0 MiB |
| Hidden CPU, one core = 100% | 3.0% | 4.1% |
| Hidden total median / peak RSS | 611.6 / 611.6 MiB | 577.1 / 638.3 MiB |

**No reliable cold-opening improvement or regression is established.** The first
version in a paired run consistently paid a larger opening cost. In the reversed
[control run 39124706933](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/39124706933),
the original code ran first and took 2124 ms cold, while the intermediate optimized
code ran second and took 1080 ms. This control reverses the apparent startup
regression; it does not prove a cold-start win. Warm reopening is modestly faster
in the final sample. This work does not remove WebKit's initial process/layout
cost.

Combined 1000-message CPU was 106.7% versus 101.5%; picker CPU varied substantially
between runs, so no universal CPU/battery reduction is claimed. Hidden CPU is low,
but hidden memory remains high after the 5000-message phase. The observed 638 MiB
hidden peak also means **peak memory did not improve in every phase**. Measurements
are taken after a fixed settling interval and cannot guarantee when WebKit will
release memory.

Both versions made **40 cold loader calls**, transferring approximately **1.079 MB**
each. Both warm reopenings added 35 local cache hits and **zero additional network
body bytes**. Thus no network reduction is claimed. Scrolling request counts vary
with animated scroll progress and viewport visibility; the final sample was
357 versus 367 cumulative calls. The optimization removes redundant cross-surface
IPC notifications while preserving shared network caching.

The main build/release [run 39125241163](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/39125241163)
passed Swift regressions, 19 Python tests, ARM64 optimized Release compilation,
package validation, and automatic publication. The bundled JavaScript matches
source, minimum iOS remains 17.0, and the release asset remains `streamstiny.ipa`.
Both versions in the final Catalyst comparison passed all three native test cases.


Remaining hot paths include full retained-ID indexing/message comparisons, bridge
ordering updates, browser layout, and native-format animation decoding. At the
5000-message cap, **28 FPS still misses 60 FPS**; the default-sized 1000-message
case remains near 59 FPS. This is an improvement, not a claim of globally optimal
resource use or complete elimination of WebKit overhead.

## Verification and limits

The existing Swift playback/chat/asset regressions and 19 Python build-tool tests
pass. New Foundation checks cover Unicode escaping, malformed ad dates, duration
fallback, invalid durations, multiple ranges, and conservative interval recovery.
Native UIKit tests exercise reveal/hide actions, unchanged row identity, pruning,
tag changes with the default revision argument, and preference invalidation.
The initial new action test checked a zero-sized view too early; its host layout
and content-ready check were corrected before accepting results.

Native pixel/timing and catalog tests continue to check Listening, pepeW,
PepoPunch, badges, and all published primary assets against direct HTTPS WebKit
behavior. The existing four Apple AVIF failures (ARRIVE, Classic, COKEJAW, HUH)
and upstream nathanOOO hover 404 remain unresolved; these optimizations do not
claim to fix platform decoding or missing upstream assets. Full default animation
fidelity is retained, rather than replaced by static images for speed.

WebKit remains a substantial memory and animation cost, including memory it can
retain after chat closes. A native CSS translator was not introduced: verified
styles include masks, filters, pseudo-elements, custom variables and contextual
rules beyond simple sprite timing. A partial replacement without conformance and
hardware measurements would sacrifice functionality or add a second pipeline.

Physical iPad 8th generation CPU/memory, video decoding/Metal GPU cost, battery
usage, authenticated production interactions, and hours-long sessions were not
measured in this Linux workspace/Catalyst runner. Synthetic hidden-feed results
exclude real socket parsing and video playback. Native release compilation does
not prove runtime behavior on every supported iOS version.

## Reproduce

- `bash scripts/benchmark_runtime.sh` on macOS for Foundation measurements.
- `bash scripts/test_playback.sh` for Swift regressions.
- `python3 -m unittest discover -s scripts -p 'test_*.py'` for build tools.
- Dispatch `chat-benchmark.yml` on `main` with `platform=catalyst` and
  `baseline_ref=185e4ae66e78a85fb9c4b2fd2cb9fedfef2e5b39` for the paired native run.
  Its artifacts contain logs, screenshots, xcresults and process samples.
- `platform=simulator` exercises the native checks on the pinned iOS runtime;
  it does not provide physical-device CPU or memory guarantees.
