# Stream bookmarks and dynamic bitrate

Stream pinning stores original `StreamSource` identities and names in the
existing `StreamLibrary`/UserDefaults store. It does not resolve URLs, create
players, announce additional watched streams, or start connections. The selected
source continues through the existing selection/playback path. Bookmarks survive
directory removal, zero viewer counts, restart and disabling the pinning UI.
Invalid and duplicate saved identities are ignored on load; normal saved settings
are preserved. Names come from the directory, then saved bookmark metadata, then
the source title.

The chooser uses one native popover list with independent play/pin buttons.
Now Playing, Pinned and discovery rows exclude duplicate identities. This replaces
the old single-action UIKit menu; it is not a second chooser implementation.

The old bitrate reader matched advertised HLS bandwidth to a representation.
That metadata describes a declared peak/average, not changing encoded video.
The existing KSPlayer 2.3.4 engine already exposes `dynamicInfo.videoBitrate`:
compressed video packet bytes divided by media time between keyframes, multiplied
by eight. The application now reads that existing estimate. It excludes audio and
transport overhead and is not download throughput. Values are always shown in
kbps with an approximation marker. Missing measurements show an unavailable dash;
there is no invented value or alternate advertised-bandwidth fallback.

Bitrate sits beside the original DGG/overall viewer counts in player controls.
The duplicate statistics section is removed from playback settings. Quality,
resolution, buffer, server selection and Reload remain accessible. The existing
Show Bitrate preference retains its value; Enable Stream Pinning defaults on and
preserves bookmarks when switched off.

Sampling reuses the existing playback tick, at most once a second while enabled,
foregrounded and visible. Covered/hidden controls stop sampling immediately.
The UI publishes only changed measurements, scoped to the small statistics view.
The variant matcher, track scan and detached bitrate tasks were removed. No new
timer, media download, decoder, packet counter or dependency was added. Pin writes
occur only on user pin/unpin actions. A constant-bitrate source may legitimately
remain steady; the decoder's measurement window follows keyframe timing.

## Validation limits

Apple runtime tests run in hosted Simulators; physical iPad/iPhone, Instruments
CPU/RAM/battery measurements and touch interaction on hardware are unavailable.
No percentage CPU, memory or battery improvement is claimed. Earlier presentation
tests exposed setup/readiness issues: the bookmark was initially still selected,
and snapshots were taken during the first native popover transition. The tests
now switch away and wait for presentation completion, without weakening the
duplicate/persistence assertions. Offline external channels are skips, not proof
of bitrate behavior; subsequent live checks use first-party-confirmed channels.

## Results

- Release review [40787610617](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40787610617)
  passed 19 Python tooling tests, the compiled Swift regression executable,
  optimized ARM64 compilation and package validation.
- Exact iOS 17 menu run [40789421255](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40789421255)
  passed presentation, disable/re-enable, directory removal and selected-bookmark
  name/duplicate checks. Persistence/model tests also passed in the native runs.
- All seven existing chat tests passed in the full iOS 17 run 40787606850,
  including asset/emote animation, pruning and scroll-to-bottom regressions.
  Its player tests failed because the manually installed UIHostingController had
  no SwiftUI Scene ancestor. The fixture now explicitly supplies foreground and
  background environments; production visibility gating was not bypassed.
- Final iOS 18.5 run [40794231302](https://github.com/EscapeAltDelete/Streamstiny/actions/runs/40794231302)
  passed **all five player/bookmark tests, zero failures and zero skips**.
  Live Twitch samples were 2,897,168 / 2,972,220 / 3,290,200 bits/s;
  live Kick samples were 7,013,568 / 7,399,676 / 8,996,724 bits/s.
  AngelThump displayed 1,783 kbps and passed the existing EOF/recovery checks.
- Fixed/automatic quality switching, unchanged player ownership during pinning,
  disabled-setting propagation and restoration of visible metrics passed.
  Two-second observation windows recorded **zero additional metric reads** when
  disabled, covered by an application sheet, backgrounded or behind the chooser.
  Existing playback continued; no bitrate timer was introduced.
- Full screenshots retain the original controls placement and were visually
  inspected. Viewer counts use deterministic directory fixtures while media is
  live. OCR examines small captions in the header, excluding unrelated video
  subtitles. An earlier AngelThump screenshot visibly showed 1,860 kbps but the
  full-image OCR missed it; those failed assertions were not counted as passes.

These checks verify store reconstruction from persisted UserDefaults data,
not a physical-device force-quit/relaunch. Full device interaction and process
CPU/RAM/battery profiling remain unverified. The performance result is removal
of redundant work and verified visibility gating, not a measured percentage
speedup.
