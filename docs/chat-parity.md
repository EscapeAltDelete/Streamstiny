# Native Destiny.gg chat

This change starts from Streamstiny 1.8.0 (`c69f846`) and retains native video playback, Twitch authorization, production audio recovery, and stream switching. The current candidate is version 1.9.2, build 21.

The reference audit used Destiny.gg's live `/embed/chat` page and public `destinygg/chat-gui` source. The public Go server repository is archived and was used only as supporting protocol evidence. An anonymous live connection confirmed ME, HISTORY, PAIDEVENTS, SPOTLIGHTS, PIN, NAMES, MSG, JOIN, and QUIT payloads. No messages, votes, moderation actions, or account writes were sent during that inspection.

## Implemented

- Website sign-in in an ephemeral browser, server verification, and separate device-only Keychain session storage. Website sessions authenticate both chat and website APIs.
- Full pin text, links, and emotes in an expanded native card; dismiss/reopen by pin identity and moderator unpin.
- Poll snapshots, server-adjusted deadlines, weighted totals, voting with acknowledgement, results, reopening, and authorized poll start/stop commands.
- Presence snapshots and deltas, native user search and profile retrieval, role-based controls, subscriber-only restrictions, and mute expiry.
- Separate whisper conversations, unread counts, acknowledgement of sent whispers, website conversation pagination, earlier-message loading, and read marking. Cached private messages are cleared on account changes and late requests are guarded against crossing accounts.
- Announcements, subscriptions, gifts, donations, cross-posts, spotlight and Vestaboard events; paid-event chips, native event cards, optional TTS playback, expiry, and moderator event removal.
- Spotlight emphasis and actions using the website's message identity format.
- Flair icons and priority colors, subscription-aware emotes, an emote picker and favorites, adjacent emote combos, and configurable animation.
- Username/emote/command suggestions, search, mention filtering/highlighting, user highlights/tags, individual unignore, configurable history capacity and timestamps.
- Custom highlight terms, optional word censorship and sensitive-link hiding, optional whisper display in public chat, foreground mention/whisper notifications, and explicit website settings load/save that preserves unsupported server preferences.
- Native slash commands for messaging, ignoring, highlighting, tags, history lookup, embeds, polls, pins, moderation, phrases, hosting, and ban information. Moderator privileges derive from server roles, never cosmetic flairs. The server remains authoritative for all privileged actions.

## Remaining parity and validation

This is not a claim of complete website parity. Desktop/browser notification behavior is represented by native foreground notifications. Subscription/donation checkout remains on the website. Background push notifications would require additional server/APNs infrastructure; the existing app suspends its chat connection in the background. Native settings synchronization reloads supported preferences when chat reconnects and saves them when message settings close; native word censorship uses an editable word list rather than reproducing the website's exact filter.

Authenticated sign-in, provider OAuth behavior inside WebKit, whispers/history APIs, live poll voting, moderator actions, layout, emote animations, TTS, and device playback still require device acceptance. Anonymous protocol checks and local core validation do not verify those interactions.

## Build

Use only `2872636/Streamstiny-Builds` for macOS compilation. The workflow caches pinned dependency sources and compatible compiled release products, skips package update checks, disables compiler indexing, and builds only the ARM64 release application. It retains dependency patch hashes, XcodeGen archive verification, ad-hoc signing, signature verification, and IPA validation. No test or diagnostic workflow is required.

The Linux Theos attempt reached iOS compilation after building its support tools, then failed because KSPlayer was not integrated. The published Theos Swift compiler is 5.8, but pinned KSPlayer declares Swift tools 5.9 and this app uses iOS 17 Observation. The published Theos SDK is iOS 16.5. The Linux build route was abandoned at the user's request; no IPA was generated there.

## 1.9.1 corrections

Website login now links automatically on return to Destiny.gg, validates in the same browser that completed sign-in, accepts the website cookie domain including `.www.destiny.gg`, and forwards the website `sid` explicitly to the trusted chat server. WebSocket handshakes retain explicitly supplied developer-token/session cookies. Twitch accepts the validated token's client ID instead of requiring the hardcoded web client, supports HTTPS login redirects/popups, recognizes dotted cookie domains, and exposes completion and actual validation/storage errors. Packaging signs with an app-specific Keychain access group; the IPA validator checks the embedded entitlement.

The Twitch manifest request enables `multigroup_video` along with device-supported H.264/HEVC codecs. Quality labels identify HEVC. Shroud was offline (Usher HTTP 404) during inspection, so the reported live source quality still requires a live device check; hardware support alone does not establish which variants Twitch returns.

Pins and polls expand inside chat. Appearance settings and their old theme override are removed. Added readable flair badges and profile descriptions, native animated rainbow usernames through the existing visible-cell animation controls, opt-in cached direct-image previews, harsh ignore, reversible ignored public-message filtering, and moderated-message retention with hide/placeholder/original modes and per-message reveal. Animations respect Reduce Motion and the existing animation setting. Moderation marks only messages preceding the event; later messages and combos stay independent.

Automatic website settings synchronization is enabled by default for linked website sessions, can be disabled, preserves unsupported server keys, and never polls in the background. API requests cannot rotate another account’s cookies after an account switch.

These changes were source-checked and core protocol/HEVC/moderation behavior was exercised on Linux. Authenticated browser-to-native handoff, Keychain persistence, real HEVC decode, and layout need device acceptance; no claim of complete device-tested website parity is made.

## 1.9.2 menu and parity sweep

Accounts now share one page and one layout: a sign-in row becomes the signed-in username and Sign out appears directly below. The separate Twitch account page, manual integrity refresh control, developer-token UI and validation path, token-based chat socket branch, and unused destructive buffer method are removed. Website login remains the existing working browser flow. Account names remain visible while the chat socket reconnects.

Every settings/menu surface uses consistent inline navigation titles, grouped controls and native actions, including playback/quality/server selection, stream selection, stream entry, chat tools, emotes, profiles, and account sheets. Expanded pins use a clear table and row background so their original card color remains unchanged.

Badge image URLs are nullable in the live schema; an entry without an image no longer rejects the entire catalog. Badge metadata loads independently of emotes from the live CDN. Image-cache revisions explicitly invalidate chat cards; roster changes refresh badge styles. The live Bot message retains its Bot sender and protected/bot features. System announcements show an announcement icon instead of a System label; username strings and objects both follow the documented broadcast protocol. No substitute badge text is generated when an image is loading.

Added website tag colors and notes with profile editing, increased tag visibility, autocomplete/focus-mentioned controls, notification preference synchronization and native permission handling, Events-role removal privileges, same-stream markers/filtering, and live roster metadata updates. Tags/notes survive synchronization and only edited profiles write preferences. Website-specific purchase flows and background push still require external services; no complete device-tested parity claim is made.

Compiled build caches now share a dependency/toolchain prefix across app version bumps; Xcode still validates source and build-setting changes before reusing outputs. No alternate application fallback or extra CI job was added.

Landscape chat can be placed on either side in split or overlay mode. Supported video links have a native Watch in Streamstiny action. Vestaboard cards show the official 6×22 character/color matrix, totals and contributor actions; auction purchases remain on the website.
