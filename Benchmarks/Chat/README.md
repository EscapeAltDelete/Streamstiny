# Destiny.gg chat verification

Measured 18 October 2026. Baseline: `48aaca881b020e0004df2b7f588f4c6a0a00f463`.

## Verified sources and root causes

The production [embedded chat](https://www.destiny.gg/embed/chat) publishes its CDN
and asset version in `data-cdn` and `data-cache-key`. At verification these were
`https://r2cdn.destiny.gg` and `1792251906609.1275`. Its versioned
`emotes/emotes.json`, `emotes/emotes.css`, `flairs/flairs.json`, and
`flairs/flairs.css` contain 347 emotes and 47 flairs. The previous hardcoded CDN
returned 325 emotes and 46 flairs, missing current seasonal art and Blue Wave
Supporter. No endpoint was inferred from the retired Go backend.

The reference [chat-gui](https://github.com/destinygg/chat-gui) checkout was
`ed37a6da9c8d278a52295bcac5612c7c2ed2b30f`. Production browser inspection confirmed
the guest WebSocket `wss://chat.destiny.gg/ws`, native picker, animation, and
asset behavior. The application already uses that socket; it remains unchanged.
No authenticated messages were sent during inspection.

The old ImageIO renderer expanded animations into decoded frames, rejected more
than 240 frames, and evicted them from a 16 MB decoded cache. Historical Listening
and pepeW exceed that frame limit. The PepoPunch splitter treated its 47 px display
width as frame pitch; native CSS instead defines 56 px steps, two frame ranges,
different delays and loop counts, and contextual transforms. Asset completions
also incremented a global UI revision, repeatedly rebuilding unrelated chat and
picker content. The picker decoded entire animations while displaying one frame.

## Implementation

- Discover the published configuration and retrieve coherent, versioned metadata
  and native styles. Retain the last good snapshot on disk and recover after
  failures. Refresh on eligible lifecycle events and published asset-version
  events, with no repeating polling timer.
- One shared URLSession/URLCache loader serves chat, picker, and badge surfaces:
  four concurrent downloads, request deduplication, subscriber cancellation,
  transient-error retry, HTTP cache semantics, and failed-image cache bypass.
  Native CSS image URLs use a local transport scheme; upstream HTTPS URLs and
  server MIME types are retained. Some `.gif` URLs actually serve AVIF.
- WebKit interprets the authoritative CSS, GIF, APNG, and supported AVIF directly.
  No custom sprite splitter, whole-animation UIImage array, decoder dependency,
  or static replacement for broken animations remains.
- Preserve message identity and animation state. Only visible picker assets and
  nearby rich chat rows are mounted. Offscreen rows retain measured space and
  their original child nodes; restoring them preserves finite animation state.
  History remains bounded by the existing cap. Batch animation queries rather
  than querying the entire document once per outgoing row.
- Preserve picker search, favorites, insertion, account restrictions, chat menus,
  badges, user colors, moderation, links, previews, and existing preferences.
  Subscription tier, Patreon access, and privileged roles now use native fields;
  cosmetic badges do not grant permissions. Hidden badges with null image URLs
  are valid metadata. The explicit reduced-motion/disable-animation preference
  uses correctly scaled first-frame canvases; ordinary playback stays animated.

## Native and browser checks

The named emotes pass actual animated-pixel checks on Mac Catalyst and iOS 18.5
Simulator: Listening and pepeW produce multiple distinct captured frames.
PepoPunch matches native CSS positions, transforms, dimensions, delays, and
finite loops at seven times from 0 to 4500 ms. Badge order, hidden badges, and
the new Blue Wave badge's 18 px chat dimensions pass.

Chromium decodes all 347 primary assets. Apple WebKit decodes **343/347**:
**ARRIVE, Classic, COKEJAW, and HUH** fail both the application's transport and
direct HTTPS loading in the same native engine. ImageIO identifies their AVIF
sequence type but reports zero frames. These remain unresolved platform-format
compatibility failures, not successful emote rendering. Their entries are
retained with readable failure text; animations have not been silently replaced.
BlackGuyLaptop, another animated AVIF, does decode.

Native CSS contains five additional contextual image URLs. Four load; the native
`nathanOOO:hover` image URL returns HTTP 404. Its normal sprite loads. The original
CSS is retained rather than inventing an alternate asset.

## Before and after measurements

Paired [run 39104641678](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/39104641678)
uses the same `macos-15` runner, Xcode 16.4, optimized Catalyst builds, a 541×600
picker, and 1000 existing plain chat messages behind the picker. The historical
renderer is given the current R2 catalog to compare the same 347 entries. Image
caches are cold at each version's start. The copied benchmark sources enable
animations explicitly because the hosted runner reports Reduce Motion enabled;
production accessibility settings are untouched. These are single paired samples,
not confidence intervals or physical-iPhone results.

| Measurement | Before | After |
| --- | ---: | ---: |
| Cold presentation to first app callback | 618 ms | 768 ms |
| Warm presentation to first app callback | 514 ms | 404 ms |
| Picker scrolling FPS | 32.4 app | 56.9 browser |
| Chat at target 100 messages/s, FPS | 16.2 app | 59.2 browser |
| Metadata discovery/loading | 2.45 s | 2.72 s |
| Total cold picker median RSS | 176 MiB | 446 MiB |
| Total warm picker median RSS | 183 MiB | 458 MiB |
| Total scrolling median / peak RSS | 190 / 209 MiB | 476 / 499 MiB |
| Total chat median / peak RSS | 236 / 240 MiB | 419 / 437 MiB |

The app callback is not proof of rendered content. New WebKit content-ready time
was **1638 ms cold / 623 ms warm**; the old implementation has no equivalent DOM
readiness signal. New browser FPS cold/warm/scroll/chat was 50.3/58.5/56.9/59.2;
browser p95 frame intervals were 25/22/23/29 ms. App-thread FPS alone would hide
browser stalls. The old target-100-message/s phase actually delivered about 73/s,
versus 94/s after, because scheduling itself stalls in the old implementation.

Warm app presentation improves 21%; scrolling FPS rises 76% and loaded-chat FPS
3.7×. However cold startup, total memory, and several CPU workloads regress.
Combined app plus newly spawned WebKit/GPU/network process samples show roughly
35/92/97/103% of one CPU during cold/warm/scroll/chat, versus 46/24/64/110% before.
These coarse `ps` samples exclude intervals before the first and after the last
sample and are not Instruments energy measurements. Native animation fidelity
does more work than the old static picker. This overhaul is **not an across-the-
board resource reduction**; physical-device memory pressure needs further work.

The cold new picker made 40 loader calls including five configuration/metadata
requests, transferring 1,078,699 response-body bytes. Reopening added 35 local
cache hits and **zero additional network body bytes**. These counts include a
different workload from the old image-only counters, so they do not establish a
percentage network reduction. A 390×844 Chromium viewport initially requested
44 unique assets, rather than all 347. Search updates took 0.4–0.6 ms there.

A separate four-CPU Linux Chromium test streams 25,000 messages, retaining 5000.
Within the new renderer, measured rich-row windowing reduced elapsed time from
51.94 s to 14.66 s (**71.8%**), median update 54.8 to 8.4 ms, and p95 65.6 to
11.9 ms. Only 38 rich rows remained mounted; clearing history released all tracked
rows and image resources. This compares two new-renderer variants, not UIKit.

## Reproduction and validation

On macOS run `bash scripts/test_playback.sh` for existing playback/chat and the
new Foundation asset regressions. Run `python3 -m unittest discover -s scripts
-p 'test_*.py'` for the 19 build-tool regressions. JavaScript syntax and actionlint
also pass. ARM64 iOS Release compilation and IPA resource/package validation pass
in the build workflow; release optimizations and pinned playback dependencies
are unchanged.

With development-only Playwright and Chromium available, run
`node scripts/test_chat_renderer.cjs`. Set `CHROMIUM` if needed and
`CHAT_RESULTS_DIR` to retain assets, screenshots, and JSON. This checks all assets,
native animation timing, stable nodes, search, restrictions, cache recovery,
failed/corrupt images, cancellation lifecycle, reduced motion scaling, rapid
surface changes, previews, scrolling restoration, and a 25,000-message session.

For actual UIKit/WebKit measurements, dispatch `chat-benchmark.yml` on `main` with
`platform=catalyst` and the baseline commit above. `platform=simulator` runs the
iOS checks. The isolated host copies production chat sources rather than
reimplementing their behavior. Artifacts include logs, screenshots, xcresults,
and complete process-RSS samples. The iOS 18.5 harness configures the documented
[WebKit Simulator loader workaround](https://bugs.webkit.org/show_bug.cgi?id=293831)
in its test environment only; production deployment remains iOS 17.

Final verification runs: paired Catalyst **39104641678**, iOS Simulator
**39103992221**, and final working-tree ARM64 Release/Swift tests **39105419904**.
Native tests report the four unsupported assets explicitly; their passing test
status does not mean those four emotes render.

Unverified: physical iPhone/iPad memory pressure, iOS 17 runtime decoding, hours-
long sessions, every contextual hover/combo pseudo-element pixel sequence, and
authenticated production moderation/subscription interactions. No claim of
universal 60 FPS, complete Apple-format support, or lower total memory is made.
