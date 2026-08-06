---
title: navegosa.el - browser control from Emacs via JXA
status: implementing
created: 2025-05-25
updated: 2026-08-05
projects:
  - repo: agzam/navegosa.el
    ref: main
    paths: [navegosa.el, navegosa-tabs.el, navegosa-media.el, navegosa-scripts.js]
related: [agzam/doom.d:modules/custom/web-browsing/autoload/browser.el]
---

# navegosa.el

## Synopsis

Elisp package for controlling web browsers from Emacs on macOS via JXA (JavaScript for Automation). Ported and expanded from personal Doom module. Name from Spanish "navegar" (to browse/navigate). Tabs and jump-to-link are macOS-only by design - Linux has no OSA equivalent; the media layer (V4) also runs on Linux over MPRIS.

## Architecture

### JS execution model

Single file `navegosa-scripts.js` contains all JXA logic in a namespaced object:

```
const Navegosa = {
  getTabs(browser) { ... },
  activateTab(browser, winIdx, tabIdx) { ... },
  ...
};
```

Elisp loads the file once into `navegosa--scripts-cache`. Each command appends a call line (e.g., `JSON.stringify(Navegosa.getTabs("Arc"))`) and pipes the full script to `osascript -l JavaScript` via stdin. Stdin avoids ARG_MAX and shell escaping.

All JXA functions return JSON. Elisp side parses with `json-read-from-string`.

### Core entry point

`navegosa--run (fn &rest args)` - single function for all JXA execution:
- Loads scripts if not cached
- Serializes args to JS literals
- Builds: cached-js-body + `JSON.stringify(Navegosa.FN(arg1, arg2, ...))`
- Calls `osascript -l JavaScript` via stdin (call-process with input string)
- Parses JSON result, returns Elisp data

### Browser detection

- `navegosa--browser` - cached browser name
- Auto-detect via LaunchServices plist (HTTPS handler) on first use
- `navegosa-browser` defcustom for manual override
- `navegosa-reset` clears all caches

### File layout

- `navegosa.el` - core: runner, browser detection, interactive commands
- `navegosa-scripts.js` - all JXA functions, single file, syntax-highlightable
- `navegosa-tabs.el` - Org-based tab manager buffer (autoloaded separately)
- `test/navegosa-tests.el` - buttercup tests

## V1 scope

### Core (navegosa.el)

- [done] JXA runner with stdin piping
- [done] Browser detection with caching + defcustom override
- [done] JS file loading from package directory
- [done] `navegosa-get-tabs` - list all tabs (returns list of plists)
- [done] `navegosa-switch-tab` - completing-read tab switcher
- [done] `navegosa-close-tab` - close tab by index
- [done] `navegosa-copy-tab-link` - active tab URL to kill-ring
- [done] `navegosa-insert-link` - insert formatted link (org/md/plain) at point
- [done] `navegosa-grab-text` - full text content of active tab
- [done] `navegosa-tab-to-eww` - render active tab in eww

### Tab buffer (navegosa-tabs.el)

- [done] `navegosa-tabs-mode` - derived from org-mode, read-only
- [done] `navegosa-tabs` - entry command, renders tab list
- [done] Structure: top-level headings = windows, sub-headings = tabs
- [done] Properties: :URL:, :WINDOW-INDEX:, :TAB-INDEX:, :ACTIVE:
- [done] Keybindings: RET=switch, d=close, g=refresh, q=quit, o=browse-url

### Tests (45 specs)

- [done] JS script loading (file exists, caches)
- [done] Argument serialization (quoting, special chars, type rejection)
- [done] JXA runner (object parsing, array parsing, error handling, empty output)
- [done] Tab data parsing (mock JSON to plist)
- [done] Org buffer rendering (grouping, heading counts, ACTIVE marker, properties, empty list)
- [done] Tab-at-point extraction (level-2 heading, nil on level-1)
- [done] Browser detection (defcustom priority, cache priority, reset)
- [done] navegosa-copy-tab-link (kill-ring, error on no tab)
- [done] navegosa-insert-link (org/md/plain format, notification count strip)
- [done] navegosa-grab-text (non-interactive return, error on no content)
- [done] navegosa-tabs-switch (correct args, error when not on tab)
- [done] navegosa-tabs-close (confirm+close+refresh, decline does nothing)
- [done] navegosa-tabs-browse-url (eww called with URL, error when not on tab)

## V2: Jump to link

- [done] `navegosa-jump-to-link` - collect links from active tab, inject hint overlays, present via consult/completing-read
- [done] JS: `getLinksAndInjectHints` - single round-trip: query `<a[href]>`, filter invisible/viewport, generate A-Z/AA-ZZ hints, inject styled overlays + highlight/cleanup functions, return `[{hint, text, href, index}]`
- [done] JS: `highlightLink`, `clearLinkHints`, `clickLink`, `openLinkNewTab`
- [done] `navegosa--run-async` - fire-and-forget JXA via `make-process` (non-blocking highlight/cleanup)
- [done] Debounced highlight timer (50ms) for consult `:state` preview
- [done] `unwind-protect` cleanup on C-g
- [done] `navegosa-jump-links-scope` defcustom: `viewport` (default) or `all`
- [done] `navegosa-jump-links-action` defcustom: `same-tab` (default) or `new-tab`
- [done] 10 new tests (candidate formatting, scope/action dispatch, cleanup on quit, async runner)
- [done] Fix existing tests for Emacs 29.4 buttercup compatibility (plist-get in expect, ensure-macos on Linux CI)

## V3: Media control

- [done] `navegosa-media.el` - control video playback in a browser tab: play/pause, seek, speed, volume, mute, subtitles, next/prev, timestamped URL copy, status echo
- [done] JS: `getMediaTabs(browser, urlPattern)` - URL-prefiltered tab listing; never executes JS into tabs (a discarded Memory Saver tab hangs `tab.execute` forever)
- [done] JS: `mediaCommand(browser, w, t, cmd, arg)` - single round-trip: pick most relevant `<video>` (playing beats paused, then largest on-screen), apply command, return full state `{time, duration, rate, paused, volume, muted, url, title, warning?}`; `mediaStatus` as the read-only alias
- [done] Commands: playPause, seekBy, seekTo, rateMul, rateSet (rate clamped 0.25-5x), volumeBy (clamped 0-1, volume-up unmutes), muteToggle, subsToggle, next, prev
- [done] subsToggle clicks `.ytp-subtitles-button` when present (YouTube), otherwise cycles `video.textTracks` modes
- [done] theaterToggle clicks `.ytp-size-button` (E2E: theater attribute cycles on a visible tab; hidden tabs apply it when shown)
- [done] `windowFullscreenToggle(browser, w)` - macOS window fullscreen via System Events AXFullScreen; needs Accessibility permission for osascript, reports the grant path otherwise. Player fullscreen is unreachable: synthetic clicks carry no user activation, Fullscreen API fires `fullscreenerror` (E2E-verified)
- [done] Timeout-guarded runner: every media JXA call is killed after `navegosa-media-timeout` (default 3s); async with result callback plus a sync wrapper
- [done] Tab cache + locate: candidates from `navegosa-media-url-patterns` (JS regexes, joined with `|`), `completing-read` on several, auto-pick first in retry context; on command failure invalidate cache, re-locate once, retry once
- [done] Echo from every command's returned state: `12:34/56:07 1.5x vol:80% [muted] [paused] Title`
- [done] `navegosa-media-copy-url` - `t=` query param for YouTube URLs, `#t=` media fragment for the rest
- [done] `navegosa-media-select-tab` always prompts (single candidate shows as the one choice) and brings the pick up in the browser
- [done] `navegosa-media-open-url` / JS `openMediaTab` - open a URL as the frontmost window's front tab and control it; tab switched in-window without activating the browser app, so Emacs keeps focus and playback starts as long as the window is visible on screen (E2E-verified)
- [done] Core refactor: `navegosa--build-script` + `navegosa--parse-result` extracted from `navegosa--run`, shared with the media runner
- [done] 33 new tests: formatting, URL stamping, locate/cache, dispatch args, retry-once, real-subprocess timeout guard (osascript swapped for sleep/sh so they run on Linux CI)
- [done] E2E against live Brave: full command matrix on a scratch tab, subtitles on a captioned video, timeout guard against a genuinely discarded tab, elisp echo/copy-url/retry flows

### Media findings (E2E, live Brave)

- Apple-Events JS runs in an isolated world: page JS (YouTube `movie_player` API) is unreachable; DOM control (video element + `.ytp-*` buttons) suffices.
- A never-focused background YouTube tab defers media load: video element exists with readyState 0, `play()` is accepted but no data loads until the tab becomes visible once. Distinct error for it: "Video not loaded - activate the tab once to start it". `navegosa-media-open-tab` is the escape hatch.
- `next` navigates SPA-style; once the page has been visible, playback continues in a background tab and the new video starts unmuted (muted state does not survive navigation).
- `prev` (`.ytp-prev-button`) is inert outside playlist/watch-history context - YouTube behavior, mirrors mpv playlist-prev semantics.
- In-page command latency 12-26ms; the ~150ms total round trip is dominated by osascript process spawn.
- Auto-relocate picks the first candidate, which can itself be a discarded tab; the guard turns that into a clean 3s failure, `navegosa-media-select-tab` is the manual override.

## V4: MPRIS lane (Linux)

- [done] `navegosa-mpris.el` - Linux transport for the same `navegosa-media-*` command set over the browser's MPRIS D-Bus interface; built-in `dbus.el`, in-process, ~1.2ms per property read (vs ~150ms osascript spawn)
- [done] `navegosa-media--use-mpris-p` routes `navegosa-media--dispatch` (and select-tab/open-url/fullscreen) to `navegosa-mpris-dispatch` on gnu/linux builds with D-Bus; the JXA lane is untouched on darwin
- [done] Discovery: `org.mpris.MediaPlayer2.*` names filtered by PlaybackStatus Playing/Paused (bus names linger in Stopped state after media ends), ranked by `navegosa-mpris-player-priority` (browsers first), Playing beats Paused within a rank; cache + revalidate + retry-once on D-Bus errors
- [done] All seeking via `SetPosition` (exact) - relative `Seek` is hijacked by the page's MediaSession seek handlers (YouTube quantizes to ~5s regardless of the requested offset)
- [done] Echo state shaped like the JXA lane's, with predicted outcome (seek target, flipped pause) because the browser applies commands asynchronously; no volume/muted fields - the bus lies about them
- [done] Honest degradation: speed (`Rate` writes ignored, Min=Max=1.0), volume/mute (`Volume` inert; muting deregisters the player), subtitles, theater, fullscreen all `user-error` with the reason; `next`/`prev` guarded by `CanGoNext`/`CanGoPrevious` (YouTube exposes them in playlists only); `copy-url` errors on Chromium (no `xesam:url` in metadata - Firefox has it)
- [done] `navegosa-media-open-url` on Linux: `browse-url` + player-cache reset (MPRIS cannot open tabs); `navegosa-media-select-tab` picks among active players (cannot raise a window)
- [done] 21 new specs, D-Bus fully mocked (list-names/get-property/call-method fakes); existing JXA dispatch specs pin the transport off since CI runs on ubuntu
- [done] Live E2E on Linux against Brave: status echo, seekBy exact, playPause with predicted echo, honest errors for speed/copy-url/next

### MPRIS findings (live Brave on Linux, 2026-08-05)

- The browser exposes a media session on the bus only while the media is audible: a tab-level-muted playing video reports Stopped with empty metadata and is uncontrollable. Unmuting registers it within a second.
- The bus name (`org.mpris.MediaPlayer2.brave.instancePID`) lingers in Stopped state long after media ends - discovery must filter by status, never by name presence.
- `Rate` writes are silently ignored (readback 1.0, wall-clock advance 1.0x); `MinimumRate = MaximumRate = 1.0` advertises it.
- `Volume` reads a static 1.0 regardless of the player's real level; writes bounce.
- Chromium metadata carries exactly artUrl/length/trackid/album/artist/title - no `xesam:url`.
- Relative `Seek` lands at the page handler's step (~5s on YouTube) whatever offset is requested; `SetPosition` is exact to the microsecond.
- `CanGoNext`/`CanGoPrevious` are false on a plain watch page; YouTube registers those handlers only in playlist/queue context.

## Deferred

- Media: skip known-bad candidates on retry; prefer :active tab in auto-locate
- Media: disambiguation when several tabs are actually playing (probe candidates, completing-read)
- Tab groups (Chrome/Brave expose via JXA; Safari doesn't; Arc has "spaces" with thin JXA)
- Search text across all tabs (execute JS in each tab, collect matches)
- Scroll-to-text / consult-line style live search (latency concern: ~50-100ms per osascript call, needs debounce ~200-300ms or grab-text-then-search-locally approach)
- Multi-window support (JXA gives windows() array; UX question is how to pick active window)
- DOM manipulation (select container, change font/style via execute JS)
- Tab reordering (Chrome/Brave support move(); write operations)

## Design decisions

- stdin over -e flag: no shell escaping, no ARG_MAX limit
- Single JS file: syntax highlighting, linting, grep-able; user preference over many small files
- Separate navegosa-tabs.el: users who only want link/copy commands skip Org loading
- Org buffer over tabulated-list: natural nesting for groups, properties for metadata, body text for future content/summaries, familiar folding UX
- Tab buffer is read-only with action keybindings (magit-style), not editable
- Linux: tabs/jump stay macOS-only (CDP against the default browser profile is dead since Chrome 136), but the media layer runs on Linux over MPRIS (V4) - one command set, per-OS transport picked in `navegosa-media--dispatch`
- Browser name cached per session: default browser rarely changes. navegosa-reset to invalidate.

## Browser-specific notes

- Chrome/Brave: share AppleScript/JXA API. Tab groups readable but not writable via JXA (write requires Chrome Extensions API). move() for reordering works.
- Safari: no tab groups in scripting API. Requires "Allow JavaScript from Apple Events" in Develop menu for execute() calls (content extraction, search).
- Arc: has "spaces" concept but thin JXA support. Basic tab/window operations work.
- All browsers supporting Standard Suite JXA work for core tab listing/switching.

## Prior art (source material)

Port from: agzam/doom.d:modules/custom/web-browsing/autoload/browser.el

Known issues in source:
- browser-find-default called on every operation (no cache) - shells out to osascript+plutil+jq each time
- JXA as inline format strings scattered across functions
- JSON parsing assumes single-line output (splits on newline, takes car)
- No error handling beyond exit-code check
- Linux path (xdotool) is separate, shares no logic - not porting

## Progress

Workspace:
- agzam/navegosa.el @ main (V3 pushed 2026-08-05; V4 built same day on the Linux box)

Confirmed:
- All v1 features implemented and E2E tested against live Brave with 49 tabs
- V2 jump-to-link E2E tested: link collection, hint injection, highlight, cleanup, clickLink all verified against live browser
- V3 media control implemented and E2E tested against live Brave: full command matrix, timeout guard against a real discarded tab, elisp echo/copy-url/retry flows
- V4 MPRIS lane implemented and E2E tested against live Brave on Linux: discovery/status/seek/pause plus honest degradation for the rest
- Browser detection returns "Brave Browser.app" (with .app suffix) - works fine with JXA
- 108 buttercup specs pass (unit + mocked integration + real-subprocess timeout guard + mocked D-Bus)
- Byte-compilation clean (navegosa.el, navegosa-tabs.el, navegosa-media.el, navegosa-mpris.el)
- GHA runs on push/PR against Emacs 29.4 and 30.1

Next actions:
- Start on deferred features (media retry refinements, tab groups, search across tabs)
- Jump-to-link: add keybinding to toggle same-tab/new-tab from within completing-read

## Changelog

- 2025-05-25: spec created from design session. V1 scope locked.
- 2025-05-25: v1 implemented. All core + tabs features done. 35 tests. E2E verified. Pushed 5677f66.
- 2025-05-25: v2 jump-to-link. Hint overlays, consult live highlight, async runner, 10 new tests, 29.4 test fixes.
- 2026-08-05: v3 media control. navegosa-media.el, getMediaTabs/mediaCommand/mediaStatus JS, timeout-guarded runner, 33 new tests, live E2E incl. discarded-tab guard. Version 0.3.0.
