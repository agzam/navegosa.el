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

  activateTab(browserName, windowIndex, tabIndex) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (wins.length < windowIndex) return {error: "Window index out of range"};
    const win = wins[windowIndex - 1];
    if (win.tabs().length < tabIndex) return {error: "Tab index out of range"};
    win.activeTabIndex = tabIndex;
    win.index = 1;
    browser.activate();
    return {ok: true};
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
        default:
          return JSON.stringify({error: 'Unknown media command: ' + cmd});
      }
      var out = {
        time: v.currentTime,
        duration: v.duration,
        rate: v.playbackRate,
        paused: v.paused,
        volume: v.volume,
        muted: v.muted
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
  },

  // Player-level fullscreen is unreachable: synthetic clicks carry no
  // user activation, so the Fullscreen API rejects (fullscreenerror).
  // Instead toggle macOS window fullscreen via System Events AXFullScreen,
  // which needs Accessibility permission for osascript.
  windowFullscreenToggle(browserName, windowIndex) {
    const browser = Application(browserName);
    const wins = browser.windows();
    if (wins.length < windowIndex) return {error: "Window index out of range"};
    const winName = wins[windowIndex - 1].name();
    try {
      const se = Application("System Events");
      const proc = se.processes.byName(browserName.replace(/\.app$/, ""));
      const seWins = proc.windows();
      let target = null;
      for (let i = 0; i < seWins.length; i++) {
        if (seWins[i].name() === winName) { target = seWins[i]; break; }
      }
      if (!target && seWins.length) target = seWins[0];
      if (!target) return {error: "No browser window found via System Events"};
      const attr = target.attributes.byName("AXFullScreen");
      const next = !attr.value();
      attr.value = next;
      return {ok: true, fullscreen: next};
    } catch (e) {
      return {error: "Window fullscreen needs Accessibility permission for osascript " +
              "(System Settings > Privacy & Security > Accessibility): " + String(e)};
    }
  }
};
