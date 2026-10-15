# PietSmiet playlist regression captures

Captured from PietSmiet on 2026-10-14. Media URLs and date-range IDs are replaced with inert fixture values; tracking URLs and token-bearing metadata are removed. Segment titles, timing, sequence numbers, discontinuities, and relevant date-range attributes are retained.

- `pietsmiet-site-1080.m3u8`: 15 live segments at Source quality, with a `twitch-trigger` tag. This reproduced the false positive that made force mode wait indefinitely.
- `pietsmiet-embed-1080.m3u8`: a real Amazon preroll, with three ad-labelled segments and an active stitched-ad date range.
- `pietsmiet-autoplay-360.m3u8`: 15 live segments from the optional lower-quality fallback, also carrying a trigger tag.

Run from the repository root with a Swift toolchain:

```sh
swiftc Streamstiny/HLSPlaylist.swift Streamstiny/TwitchAdPlaylist.swift Tests/TwitchAdPlaylistTests.swift -o /tmp/twitch-ad-tests
/tmp/twitch-ad-tests
```

The captures verify playlist decisions, not real-device rendering or the absence of unmarked advertising.
