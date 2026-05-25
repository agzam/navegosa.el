---
title: navegosa.el - browser control from Emacs via JXA
status: implementing
created: 2025-05-25
updated: 2025-05-25
projects:
  - repo: agzam/navegosa.el
    ref: 5677f66
    paths: [navegosa.el, navegosa-tabs.el, navegosa-scripts.js]
related: [agzam/doom.d:modules/custom/web-browsing/autoload/browser.el]
---

# navegosa.el

## Synopsis

Elisp package for controlling web browsers from Emacs on macOS via JXA (JavaScript for Automation). Ported and expanded from personal Doom module. Name from Spanish "navegar" (to browse/navigate). macOS-only by design - Linux has no OSA equivalent.

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

### Tests (35 specs)

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

## Deferred (post-v1)

- Tab groups (Chrome/Brave expose via JXA; Safari doesn't; Arc has "spaces" with thin JXA)
- Search text across all tabs (execute JS in each tab, collect matches)
- Scroll-to-text / consult-line style live search (latency concern: ~50-100ms per osascript call, needs debounce ~200-300ms or grab-text-then-search-locally approach)
- Multi-window support (JXA gives windows() array; UX question is how to pick active window)
- DOM manipulation (select container, change font/style via execute JS)
- Async execution (make-process + sentinel for batch operations)
- Tab reordering (Chrome/Brave support move(); write operations)

## Design decisions

- stdin over -e flag: no shell escaping, no ARG_MAX limit
- Single JS file: syntax highlighting, linting, grep-able; user preference over many small files
- Separate navegosa-tabs.el: users who only want link/copy commands skip Org loading
- Org buffer over tabulated-list: natural nesting for groups, properties for metadata, body text for future content/summaries, familiar folding UX
- Tab buffer is read-only with action keybindings (magit-style), not editable
- No Linux support: explicit macOS-only. README states this. If someone adds Chrome DevTools Protocol backend later, navegosa--run abstraction allows it
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
- agzam/navegosa.el @ main (5677f66, clean, pushed)

Confirmed:
- All v1 features implemented and E2E tested against live Brave with 49 tabs
- Browser detection returns "Brave Browser.app" (with .app suffix) - works fine with JXA
- 35 buttercup specs pass (unit + mocked integration)
- Byte-compilation clean
- GHA runs on push/PR against Emacs 29.4 and 30.1

Next actions:
- Start on deferred features (tab groups, search across tabs, scroll-to-text)
- Consider adding `openTab` to JS dispatch for programmatic tab creation

## Changelog

- 2025-05-25: spec created from design session. V1 scope locked.
- 2025-05-25: v1 implemented. All core + tabs features done. 35 tests. E2E verified. Pushed 5677f66.
