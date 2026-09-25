// navegosa-scripts.js - JXA functions for browser control from Emacs
// Called via: osascript -l JavaScript < (this file + dispatch call)
// All functions return JSON-serializable values.

const Navegosa = {
  getTabs(browserName) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return [];
    const tabs = [];
    wins.forEach((win, winIdx) => {
      let activeIdx = -1;
      try { activeIdx = win.activeTabIndex(); } catch (_) {}
      win.tabs().forEach((tab, tabIdx) => {
        tabs.push({
          windowIndex: winIdx + 1,
          tabIndex: tabIdx + 1,
          url: tab.url(),
          title: tab.name(),
          active: (tabIdx + 1) === activeIdx
        });
      });
    });
    return tabs;
  },

  // Make the tab its window's front tab and raise that window within
  // the browser, without activating the browser app: the caller
  // (Emacs) keeps keyboard focus.
  showTab(browserName, windowIndex, tabIndex) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (wins.length < windowIndex) return {error: "Window index out of range"};
    const win = wins[windowIndex - 1];
    if (win.tabs().length < tabIndex) return {error: "Tab index out of range"};
    win.activeTabIndex = tabIndex;
    win.index = 1;
    return {ok: true};
  },

  activateTab(browserName, windowIndex, tabIndex) {
    const shown = this.showTab(browserName, windowIndex, tabIndex);
    if (shown.error) return shown;
    Application(browserName).activate();
    return shown;
  },

  // Wait while spinning the run loop.  NSWorkspace refreshes
  // frontmostApplication from run-loop notifications and delay() does
  // not spin the run loop, so a poll built on delay() keeps reading its
  // first value.
  _spin(seconds) {
    ObjC.import("Foundation");
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(seconds));
  },

  // For waitMs, hand keyboard focus back to the process pid (Emacs)
  // every time the browser takes it.  Runs as its own fire-and-forget
  // osascript next to an operation that activates the browser after its
  // Apple Event has returned: entering fullscreen activates the browser
  // twice, on the request and again when the animation ends ~0.7s
  // later, so the watch never ends early.  The AppleScript activate
  // command does the handing back;
  // NSRunningApplication.activateWithOptions is refused under
  // cooperative activation.
  reclaimFocus(browserName, pid, waitMs) {
    ObjC.import("AppKit");
    const ws = $.NSWorkspace.sharedWorkspace;
    const browserId = Application(browserName).id();
    const browserInFront = () => ws.frontmostApplication.bundleIdentifier.js === browserId;
    const owner = Application(pid);
    let reclaims = 0;
    const deadline = Date.now() + waitMs;
    while (Date.now() < deadline) {
      if (browserInFront()) { owner.activate(); reclaims++; this._spin(0.2); }
      else this._spin(0.05);
    }
    return {ok: !browserInFront(), reclaims: reclaims};
  },

  closeTab(browserName, windowIndex, tabIndex) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (wins.length < windowIndex) return {error: "Window index out of range"};
    const win = wins[windowIndex - 1];
    const tabs = win.tabs();
    if (tabs.length < tabIndex) return {error: "Tab index out of range"};
    tabs[tabIndex - 1].close();
    return {ok: true};
  },

  getActiveTabInfo(browserName) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return null;
    const win = wins[0];
    const tab = win.activeTab;
    return {
      windowIndex: 1,
      tabIndex: win.activeTabIndex(),
      url: tab.url(),
      title: tab.name()
    };
  },

  // Requires "Allow JavaScript from Apple Events" for Safari
  getActiveTabContent(browserName) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return null;
    const tab = wins[0].activeTab;
    const html = tab.execute({javascript: "document.documentElement.outerHTML"});
    return {
      url: tab.url(),
      title: tab.name(),
      content: html
    };
  },

  // Requires "Allow JavaScript from Apple Events" for Safari
  getActiveTabText(browserName) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return null;
    const tab = wins[0].activeTab;
    const text = tab.execute({javascript: "document.body.innerText"});
    return {
      url: tab.url(),
      title: tab.name(),
      content: text
    };
  },

  // Requires "Allow JavaScript from Apple Events" for Safari
  getLinksAndInjectHints(browserName, viewportOnly) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return [];
    const tab = wins[0].activeTab;
    const js = `(function() {
      if (window.__navegosaClearHints) window.__navegosaClearHints();
      var vpOnly = ${viewportOnly ? 'true' : 'false'};
      var all = Array.from(document.querySelectorAll('a[href]')).filter(function(a) {
        var s = window.getComputedStyle(a);
        if (s.display === 'none' || s.visibility === 'hidden') return false;
        var r = a.getBoundingClientRect();
        return r.width > 0 || r.height > 0;
      });
      var links = vpOnly ? all.filter(function(a) {
        var r = a.getBoundingClientRect();
        return r.top < window.innerHeight && r.bottom > 0 &&
               r.left < window.innerWidth && r.right > 0;
      }) : all;
      if (!links.length) return JSON.stringify([]);
      window.__navegosaLinks = links;
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      var hints = [];
      var n = links.length;
      for (var i = 0; i < n; i++) {
        if (n <= 26) hints.push(chars[i]);
        else hints.push(chars[Math.floor(i / 26) % 26] + chars[i % 26]);
      }
      var style = document.createElement('style');
      style.id = '__navegosa-style';
      style.textContent = '.__navegosa-hint{position:absolute;z-index:2147483647;background:#f5c518;color:#000;font:bold 11px/1.2 monospace;padding:1px 4px;border-radius:3px;pointer-events:none;box-shadow:0 1px 3px rgba(0,0,0,.3)}.__navegosa-highlight{outline:3px solid #f5c518!important;outline-offset:2px!important;background-color:rgba(245,197,24,.15)!important}';
      document.head.appendChild(style);
      var container = document.createElement('div');
      container.id = '__navegosa-container';
      container.style.cssText = 'position:absolute;top:0;left:0;z-index:2147483647;pointer-events:none';
      for (var i = 0; i < links.length; i++) {
        var rect = links[i].getBoundingClientRect();
        var h = document.createElement('span');
        h.className = '__navegosa-hint';
        h.textContent = hints[i];
        h.style.top = (rect.top + window.scrollY) + 'px';
        h.style.left = (rect.left + window.scrollX) + 'px';
        container.appendChild(h);
      }
      document.body.appendChild(container);
      window.__navegosaHighlightedIdx = -1;
      window.__navegosaHighlight = function(idx) {
        var l = window.__navegosaLinks;
        if (!l) return;
        if (window.__navegosaHighlightedIdx >= 0 && window.__navegosaHighlightedIdx < l.length)
          l[window.__navegosaHighlightedIdx].classList.remove('__navegosa-highlight');
        if (idx >= 0 && idx < l.length) {
          l[idx].classList.add('__navegosa-highlight');
          l[idx].scrollIntoView({behavior:'smooth',block:'center'});
        }
        window.__navegosaHighlightedIdx = idx;
      };
      window.__navegosaClearHints = function() {
        var el = document.getElementById('__navegosa-container');
        if (el) el.remove();
        var st = document.getElementById('__navegosa-style');
        if (st) st.remove();
        if (window.__navegosaLinks) {
          for (var j = 0; j < window.__navegosaLinks.length; j++)
            window.__navegosaLinks[j].classList.remove('__navegosa-highlight');
        }
        window.__navegosaLinks = null;
        window.__navegosaHighlight = null;
        window.__navegosaClearHints = null;
        window.__navegosaHighlightedIdx = -1;
      };
      var result = [];
      for (var i = 0; i < links.length; i++) {
        var text = (links[i].textContent || '').replace(/\\s+/g, ' ').trim();
        if (text.length > 200) text = text.substring(0, 200);
        result.push({hint: hints[i], text: text, href: links[i].href, index: i});
      }
      return JSON.stringify(result);
    })()`;
    const resultStr = tab.execute({javascript: js});
    if (!resultStr) return [];
    return JSON.parse(resultStr);
  },

  highlightLink(browserName, index) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return {error: "No browser windows"};
    const tab = wins[0].activeTab;
    tab.execute({javascript: "if(window.__navegosaHighlight)window.__navegosaHighlight(" + index + ")"});
    return {ok: true};
  },

  clearLinkHints(browserName) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return {ok: true};
    const tab = wins[0].activeTab;
    tab.execute({javascript: "if(window.__navegosaClearHints)window.__navegosaClearHints()"});
    return {ok: true};
  },

  clickLink(browserName, index) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return {error: "No browser windows"};
    const tab = wins[0].activeTab;
    tab.execute({javascript: "if(window.__navegosaLinks&&window.__navegosaLinks[" + index + "])window.__navegosaLinks[" + index + "].click()"});
    return {ok: true};
  },

  openLinkNewTab(browserName, url) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return {error: "No browser windows"};
    const tab = wins[0].activeTab;
    tab.execute({javascript: "window.open('" + url.replace(/'/g, "%27") + "', '_blank')"});
    return {ok: true};
  },

  // --- Media control ---
  // URL prefilter only, no JS execution: executing into a discarded
  // (Memory Saver) tab hangs the osascript call indefinitely, so tabs
  // are never blind-probed.  urlPattern is a JS regex string.
  getMediaTabs(browserName, urlPattern) {
    const re = new RegExp(urlPattern, "i");
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return [];
    const result = [];
    wins.forEach((win, winIdx) => {
      let activeIdx = -1;
      try { activeIdx = win.activeTabIndex(); } catch (_) {}
      win.tabs().forEach((tab, tabIdx) => {
        const url = tab.url();
        if (url && re.test(url)) {
          result.push({
            windowIndex: winIdx + 1,
            tabIndex: tabIdx + 1,
            url: url,
            title: tab.name(),
            active: (tabIdx + 1) === activeIdx
          });
        }
      });
    });
    return result;
  },

  // Page-side JS for media ops.  Runs in the Apple-Events isolated
  // world: DOM only, the page's own JS (e.g. YT's movie_player API) is
  // unreachable - control goes through the <video> element and player
  // buttons.  Picks the most relevant video: playing beats paused,
  // then largest on-screen area.
  _mediaJS(cmd, arg) {
    return `(function() {
      var all = Array.prototype.slice.call(document.querySelectorAll('video'));
      var vids = all.filter(function(v) { return v.readyState > 0 || (v.duration || 0) > 0; });
      if (!vids.length)
        return JSON.stringify({error: all.length
          ? 'Video not loaded - activate the tab once to start it'
          : 'No video element in tab'});
      vids.sort(function(a, b) {
        function score(v) {
          var r = v.getBoundingClientRect();
          return (v.paused ? 0 : 1e9) + r.width * r.height;
        }
        return score(b) - score(a);
      });
      var v = vids[0];
      var cmd = ${JSON.stringify(cmd)};
      var arg = ${JSON.stringify(arg === undefined ? null : arg)};
      var warning = null;
      var fullscreen = !!document.fullscreenElement;
      function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)); }
      switch (cmd) {
        case 'status':
          break;
        case 'playPause':
          if (v.paused) v.play(); else v.pause();
          break;
        case 'seekBy':
          v.currentTime = clamp(v.currentTime + arg, 0, v.duration || Infinity);
          break;
        case 'seekTo':
          v.currentTime = clamp(arg, 0, v.duration || Infinity);
          break;
        case 'rateMul':
          v.playbackRate = clamp(v.playbackRate * arg, 0.25, 5);
          break;
        case 'rateSet':
          v.playbackRate = clamp(arg, 0.25, 5);
          break;
        case 'volumeBy':
          v.volume = clamp(v.volume + arg, 0, 1);
          if (arg > 0 && v.muted) v.muted = false;
          break;
        case 'muteToggle':
          v.muted = !v.muted;
          break;
        case 'subsToggle': {
          var btn = document.querySelector('.ytp-subtitles-button');
          if (btn) { btn.click(); }
          else if (v.textTracks && v.textTracks.length) {
            var showing = -1;
            for (var i = 0; i < v.textTracks.length; i++)
              if (v.textTracks[i].mode === 'showing') showing = i;
            if (showing >= 0) v.textTracks[showing].mode = 'hidden';
            else v.textTracks[0].mode = 'showing';
          } else { warning = 'no subtitles'; }
          break;
        }
        case 'next':
        case 'prev': {
          var b = document.querySelector(cmd === 'next' ? '.ytp-next-button' : '.ytp-prev-button');
          if (b) b.click(); else warning = 'no ' + cmd + ' button';
          break;
        }
        case 'theaterToggle': {
          // Layout applies only while the tab is visible (rendering is
          // paused in hidden tabs); the click still registers.
          var sz = document.querySelector('.ytp-size-button');
          if (sz) sz.click(); else warning = 'no theater button';
          break;
        }
        case 'fullscreenToggle': {
          // Entering needs transient user activation, which
          // mediaFullscreenToggle supplies with a key posted to the
          // browser first; exiting needs none.
          if (fullscreen) { document.exitFullscreen(); fullscreen = false; break; }
          if (!navigator.userActivation.isActive)
            return JSON.stringify({error: 'Fullscreen needs a user gesture and the page got no key event - ' +
              'grant osascript Accessibility permission, and keep focus off the address bar'});
          var fb = document.querySelector('.ytp-fullscreen-button');
          if (fb) fb.click(); else v.requestFullscreen();
          fullscreen = true;
          break;
        }
        default:
          return JSON.stringify({error: 'Unknown media command: ' + cmd});
      }
      var out = {
        time: v.currentTime,
        duration: v.duration,
        rate: v.playbackRate,
        paused: v.paused,
        volume: v.volume,
        muted: v.muted,
        fullscreen: fullscreen
      };
      if (warning) out.warning = warning;
      return JSON.stringify(out);
    })()`;
  },

  // Callers must prefilter tabs by URL (getMediaTabs) and timeout-guard
  // the call: a discarded tab hangs tab.execute forever.
  mediaCommand(browserName, windowIndex, tabIndex, cmd, arg) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (wins.length < windowIndex) return {error: "Window index out of range"};
    const win = wins[windowIndex - 1];
    const tabs = win.tabs();
    if (tabs.length < tabIndex) return {error: "Tab index out of range"};
    const tab = tabs[tabIndex - 1];
    const resultStr = tab.execute({javascript: this._mediaJS(cmd, arg)});
    if (!resultStr) return {error: "No result from tab"};
    const state = JSON.parse(resultStr);
    if (state.error) return state;
    state.url = tab.url();
    state.title = tab.name();
    state.windowIndex = windowIndex;
    state.tabIndex = tabIndex;
    return state;
  },

  mediaStatus(browserName, windowIndex, tabIndex) {
    return this.mediaCommand(browserName, windowIndex, tabIndex, "status", null);
  },

  // Player fullscreen needs transient user activation, which JS run
  // from Apple Events never has.  A key posted to the browser process
  // is real input to its front tab even while the browser stays in the
  // background: F19, which no page, extension or browser binding
  // claims, gives the tab a few seconds of activation, and the
  // player's own fullscreen button, clicked from the isolated world,
  // then enters fullscreen.  Posting events needs Accessibility
  // permission for osascript.  Entering fullscreen activates the
  // browser twice (on the request and when the animation ends), so the
  // caller runs reclaimFocus alongside.
  mediaFullscreenToggle(browserName, windowIndex, tabIndex) {
    const shown = this.showTab(browserName, windowIndex, tabIndex);
    if (shown.error) return shown;
    const browser = Application(browserName);
    const tab = browser.windows()[windowIndex - 1].tabs()[tabIndex - 1];
    const inFullscreen = () => tab.execute({javascript: "!!document.fullscreenElement"});
    if (!inFullscreen()) {
      ObjC.import("AppKit");
      ObjC.import("CoreGraphics");
      const pid = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier(browser.id()).objectAtIndex(0).processIdentifier;
      const F19 = 80;
      $.CGEventPostToPid(pid, $.CGEventCreateKeyboardEvent(null, F19, true));
      $.CGEventPostToPid(pid, $.CGEventCreateKeyboardEvent(null, F19, false));
      const activationDeadline = Date.now() + 500;
      while (!tab.execute({javascript: "navigator.userActivation.isActive"}) &&
             Date.now() < activationDeadline)
        this._spin(0.0125);
    }
    const state = this.mediaCommand(browserName, windowIndex, tabIndex, "fullscreenToggle", null);
    if (state.error) return state;
    const deadline = Date.now() + 1000;
    while (inFullscreen() !== state.fullscreen && Date.now() < deadline) this._spin(0.025);
    if (inFullscreen() !== state.fullscreen)
      return {error: "The page did not " + (state.fullscreen ? "enter" : "leave") + " fullscreen"};
    return state;
  },

  // Open url as the front tab of the frontmost window: tabs.push
  // activates the new tab in-window, and the browser app itself is NOT
  // activated - Emacs keeps focus.  Media loads as long as the browser
  // window is visible somewhere on screen (visibility-gated otherwise).
  openMediaTab(browserName, url) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (!wins.length) return {error: "No browser windows"};
    const win = wins[0];
    const tab = new (browser.Tab)({url: url});
    win.tabs.push(tab);
    const tabIndex = win.tabs().length;
    return {
      windowIndex: 1,
      tabIndex: tabIndex,
      url: url,
      title: ""
    };
  }
};
