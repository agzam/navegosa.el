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
  // URL prefilter, no JS execution: executing into a discarded (Memory
  // Saver) tab hangs the osascript call indefinitely.  urlPattern is a JS
  // regex string; tabs in alsoIds, and each window's shown tab with
  // withShown, join whatever their URL.  One Apple Event per window each.
  getMediaTabs(browserName, urlPattern, alsoIds, withShown) {
    const re = new RegExp(urlPattern, "i");
    const also = alsoIds || [];
    const result = [];
    Application(browserName).windows().forEach((win, winIdx) => {
      let activeIdx = -1;
      try { activeIdx = win.activeTabIndex(); } catch (_) {}
      const ids = win.tabs.id(), urls = win.tabs.url(), titles = win.tabs.name();
      urls.forEach((url, i) => {
        const matched = !!url && re.test(url);
        const active = i + 1 === activeIdx;
        if (matched || (withShown && active) || also.indexOf(ids[i]) >= 0)
          result.push({id: ids[i], windowIndex: winIdx + 1, tabIndex: i + 1,
                       url: url, title: titles[i], active: active, matched: matched});
      });
    });
    return result;
  },

  _probeJS() {
    return "(function() {" + this._pageJS() + "\nreturn JSON.stringify(probe());\n})()";
  },

  // A page the browser serves no script to (its own UI, the PDF viewer)
  // throws; it holds no player for this lane either.
  _probe(browser, c) {
    try {
      return JSON.parse(browser.windows[c.windowIndex - 1].tabs.byId(c.id)
                        .execute({javascript: this._probeJS()}));
    } catch (_) {
      return {player: false, playing: false, audible: false};
    }
  },

  // A tab keeps its id while it moves; its indices shift with every
  // tab opened, closed or dragged, and window order follows focus.
  _tabById(browserName, id) {
    const wins = Application(browserName).windows();
    for (let w = 0; w < wins.length; w++) {
      const i = wins[w].tabs.id().indexOf(id);
      if (i >= 0) return {id: id, windowIndex: w + 1, tabIndex: i + 1, tab: wins[w].tabs[i]};
    }
    return null;
  },

  // The tab a command acts on: the picked one, else a playing one (the
  // last controlled first), else a shown one, else the last controlled,
  // else the only one.  Null means the caller has to ask.
  _pickTarget(cands, pickId, lastId) {
    const byId = (id) => cands.find((c) => c.id === id);
    const playing = cands.filter((c) => c.playing);
    return byId(pickId)
      || playing.find((c) => c.id === lastId) || playing[0]
      || cands.find((c) => c.active)
      || byId(lastId)
      || (cands.length === 1 ? cands[0] : null);
  },

  // An embed takes commands only after the reload that enables its API
  // and the handshake that follows, which both finish between calls.
  _runOn(browser, c, cmd, arg) {
    const tab = browser.windows[c.windowIndex - 1].tabs.byId(c.id);
    const exec = () => {
      const resultStr = tab.execute({javascript: this._mediaJS(cmd, arg)});
      return resultStr ? JSON.parse(resultStr) : {error: "No result from tab"};
    };
    let state = exec();
    const deadline = Date.now() + 2000;
    while (state.pending && Date.now() < deadline) {
      this._spin(0.1);
      state = exec();
    }
    if (state.pending) return {error: "The embedded player did not answer; try again"};
    if (state.error) return state;
    state.page = tab.url();
    state.url = state.url || state.page;
    state.title = state.title || tab.name();
    state.id = c.id;
    return state;
  },

  // One call per media command: list the media tabs, check which play,
  // pick the target, run cmd.  Each check is logged to stderr first: an
  // unloaded (Memory Saver) tab never answers, so the caller kills the call
  // and skips that tab; only a shown tab on the URL patterns is checked anyway.
  mediaRun(browserName, urlPattern, pickId, lastId, skipIds, cmd, arg) {
    const browser = Application(browserName);
    const skip = (skipIds || "").split(",");
    // a tab outside the URL patterns stays while it holds a player, and
    // plays only with sound: muted loops stand in for GIFs on many sites
    const cands = this.getMediaTabs(browserName, urlPattern, [pickId, lastId], true)
      .filter((c) => {
        if (skip.indexOf(c.id) >= 0 && !(c.active && c.matched))
          return c.matched || c.id === pickId || c.id === lastId;
        console.log("probe " + c.id);
        const found = this._probe(browser, c);
        c.playing = c.matched ? found.playing : found.audible;
        return c.matched || c.id === pickId || found.player;
      });
    console.log("run");
    if (!cands.length) return {error: "no media tabs open"};
    if (cmd === "list") return {tabs: cands};
    if (cmd === "pauseAll") {
      const playing = cands.filter((c) => c.playing);
      playing.forEach((c) => this._runOn(browser, c, "pause"));
      return {paused: playing.length};
    }
    // playAt continues one video in the tab that shows it, never in another
    if (cmd === "playAt" && !cands.some((c) => c.id === pickId))
      return {error: "The media tab is gone"};
    const target = this._pickTarget(cands, pickId, lastId);
    if (!target) return {tabs: cands};
    if (cmd === "pick") return {target: target};
    // play-pause and playAt never leave two videos playing: they pause
    // every other playing tab, then act on the target
    if (cmd === "playPause" || cmd === "playAt")
      cands.filter((c) => c.playing && c !== target)
        .forEach((c) => this._runOn(browser, c, "pause"));
    return this._runOn(browser, target, cmd, arg);
  },

  // Two URLs show the same media when their YouTube video ids match,
  // else when they match up to the #fragment.
  _sameMedia(a, b) {
    const ytId = (url) =>
      (url.match(/(?:youtube\.com\/watch\?(?:.*&)?v=|youtu\.be\/)([\w-]{11})/) || [])[1];
    const idA = ytId(a), idB = ytId(b);
    if (idA || idB) return idA === idB;
    return a.split("#")[0] === b.split("#")[0];
  },

  // The media tab showing url's video, or null.  Found by URL alone, so
  // an unloaded tab cannot hang the call.  An embedded video goes back to
  // its home tab while that tab still shows homePage.
  findMediaTab(browserName, urlPattern, url, homeId, homePage) {
    if (!new RegExp(urlPattern, "i").test(url))
      return {error: "no navegosa-media-url-patterns entry matches " + url};
    const home = homeId ? this._tabById(browserName, homeId) : null;
    if (home && home.tab.url().split("#")[0] === homePage.split("#")[0])
      return {id: homeId, windowIndex: home.windowIndex, tabIndex: home.tabIndex,
              url: homePage, title: home.tab.name()};
    return this.getMediaTabs(browserName, urlPattern)
      .find((c) => this._sameMedia(c.url, url)) || null;
  },

  showTabById(browserName, tabId) {
    const found = this._tabById(browserName, tabId);
    if (!found) return {error: "The media tab is gone"};
    return this.showTab(browserName, found.windowIndex, found.tabIndex);
  },

  // The page side of every media call, run in the Apple-Events isolated
  // world: the page's own JS is out of reach, so <video> elements are
  // driven directly and YouTube embeds through their IFrame API messages.
  // An embed answers after the call returns, so its state lives on window.
  _pageJS() {
    return String.raw`
      var EMBED = /^https:\/\/(www\.)?youtube(-nocookie)?\.com\/embed\//;
      var YT_ORIGIN = /^https:\/\/(www\.)?youtube(-nocookie)?\.com$/;
      var RATES = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
      // a command's effect stands in for the state until the embed reports it
      var AHEAD_MS = 1500;
      var GESTURE = 'Fullscreen needs a user gesture and the page got no key event - ' +
        'grant osascript Accessibility permission, and keep focus off the address bar';

      function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)); }

      function embeds() {
        return Array.prototype.slice.call(document.querySelectorAll('iframe'))
          .filter(function(f) { return EMBED.test(f.src); });
      }

      var K = window.__navegosaEmbeds;
      if (!K || K.version !== 1) {
        if (K) window.removeEventListener('message', K.onMessage);
        K = window.__navegosaEmbeds = {version: 1, states: new Map()};
        K.onMessage = function(e) {
          if (typeof e.data !== 'string' || !YT_ORIGIN.test(e.origin)) return;
          var f = embeds().find(function(x) { return x.contentWindow === e.source; });
          if (!f) return;
          var m;
          try { m = JSON.parse(e.data); } catch (_) { return; }
          var s = stateOf(f);
          if (m.event === 'initialDelivery' || m.event === 'infoDelivery') {
            Object.assign(s.info, m.info);
            if (m.info && typeof m.info.currentTime === 'number') s.timeAt = Date.now();
          }
          if (m.event === 'apiInfoDelivery') s.modules = m.info || {};
          // onReady follows initialDelivery; any other message means it listens
          if (m.event !== 'initialDelivery') s.ready = true;
        };
        window.addEventListener('message', K.onMessage);
      }

      function freshState(reloaded) {
        return {info: {}, modules: {}, ahead: {}, ready: false, timeAt: 0, reloaded: reloaded};
      }

      function stateOf(f) {
        var s = K.states.get(f);
        if (!s) { s = freshState(false); K.states.set(f, s); }
        return s;
      }

      function apiOn(f) { return new URL(f.src).searchParams.get('enablejsapi') === '1'; }

      function send(f, msg) {
        msg.id = 'navegosa';
        msg.channel = 'widget';
        f.contentWindow.postMessage(JSON.stringify(msg), '*');
      }

      function listen(f) { send(f, {event: 'listening'}); }

      function post(f, func, args) { send(f, {event: 'command', func: func, args: args || []}); }

      // the player takes commands only with enablejsapi=1, and setting it reloads the embed
      function enable(f) {
        var u = new URL(f.src);
        u.searchParams.set('enablejsapi', '1');
        K.states.set(f, freshState(true));
        f.addEventListener('load', function() { listen(f); }, {once: true});
        f.src = u.toString();
      }

      function val(s, k) {
        var a = s.ahead[k];
        return a && Date.now() - a.at < AHEAD_MS ? a.v : s.info[k];
      }

      function setAhead(s, k, v) { s.ahead[k] = {v: v, at: Date.now()}; }

      function playingNow(s) {
        var st = val(s, 'playerState');
        return st === 1 || st === 3;
      }

      function timeOf(s) {
        var a = s.ahead.currentTime;
        var fresh = a && Date.now() - a.at < AHEAD_MS;
        var t = fresh ? a.v : s.info.currentTime;
        if (typeof t !== 'number') return null;
        if (val(s, 'playerState') === 1) {
          // the position runs from the later of its reading and the start
          var p = s.ahead.playerState;
          var started = p && Date.now() - p.at < AHEAD_MS ? p.at : 0;
          var from = Math.max(fresh ? a.at : s.timeAt, started);
          t += (Date.now() - from) / 1000 * (val(s, 'playbackRate') || 1);
        }
        return s.info.duration ? Math.min(t, s.info.duration) : t;
      }

      // pin the position reached so far before a change of state or rate
      function freeze(s) {
        var now = timeOf(s);
        if (now !== null) setAhead(s, 'currentTime', now);
      }

      function rates(info) {
        var r = info.availablePlaybackRates;
        return r && r.length ? r.slice().sort(function(a, b) { return a - b; }) : RATES;
      }

      function nearestRate(info, r) {
        return rates(info).reduce(function(best, x) {
          return Math.abs(x - r) < Math.abs(best - r) ? x : best;
        });
      }

      // YouTube plays only the rates it lists, so a step moves to the next one
      function stepRate(info, cur, factor) {
        var list = rates(info);
        if (1 < factor)
          return list.find(function(x) { return cur < x - 1e-6; }) || list[list.length - 1];
        for (var i = list.length - 1; 0 <= i; i--) if (list[i] < cur - 1e-6) return list[i];
        return list[0];
      }

      function visibleArea(r) {
        var w = Math.min(r.right, window.innerWidth) - Math.max(r.left, 0);
        var h = Math.min(r.bottom, window.innerHeight) - Math.max(r.top, 0);
        return 0 < w && 0 < h ? w * h : 0;
      }

      // Playing with sound beats playing muted beats paused; then the larger
      // area on screen wins, then the larger area.
      function players() {
        var list = Array.prototype.slice.call(document.querySelectorAll('video'))
          .filter(function(v) { return v.readyState > 0 || (v.duration || 0) > 0; })
          .map(function(v) {
            return {el: v, embed: false, playing: !v.paused,
                    audible: !v.paused && !v.muted && 0 < v.volume};
          })
          .concat(embeds().map(function(f) {
            var s = stateOf(f);
            var playing = playingNow(s);
            return {el: f, embed: true, playing: playing,
                    audible: playing && !val(s, 'muted') && val(s, 'volume') !== 0};
          }));
        list.forEach(function(p) {
          var r = p.el.getBoundingClientRect();
          p.seen = visibleArea(r);
          p.area = r.width * r.height;
        });
        return list.sort(function(a, b) {
          return (b.audible - a.audible) || (b.playing - a.playing) ||
            (b.seen - a.seen) || (b.area - a.area);
        });
      }

      // Off the URL patterns a page is media when a reader would use its
      // player: an embed, a <video> with controls, or one with sound.
      function probe() {
        var list = players();
        embeds().forEach(function(f) { if (apiOn(f) && !stateOf(f).ready) listen(f); });
        return {
          player: list.some(function(p) { return p.embed || p.el.controls || p.audible; }),
          playing: list.some(function(p) { return p.playing; }),
          audible: list.some(function(p) { return p.audible; })
        };
      }

      function youtubeId(url) {
        return (url.match(/(?:youtube(?:-nocookie)?\.com\/(?:watch\?(?:.*&)?v=|embed\/)|youtu\.be\/)([\w-]{11})/) || [])[1];
      }

      function embedId(f) {
        return (stateOf(f).info.videoData || {}).video_id || youtubeId(f.src);
      }

      // playAt continues one video, so on a page with several players the
      // embed that shows it plays, brought into view
      function run(cmd, arg) {
        var list = players();
        if (!list.length)
          return {error: document.querySelector('video')
            ? 'Video not loaded - activate the tab once to start it'
            : 'No video element in tab'};
        var p = list[0];
        var id = cmd === 'playAt' && arg[2] && youtubeId(arg[2]);
        var same = id && list.find(function(q) { return q.embed && embedId(q.el) === id; });
        if (same) {
          same.el.scrollIntoView({block: 'nearest'});
          p = same;
        }
        return p.embed ? runEmbed(p.el, cmd, arg) : runVideo(p.el, cmd, arg);
      }

      function runVideo(v, cmd, arg) {
        var warning = null;
        var fullscreen = !!document.fullscreenElement;
        switch (cmd) {
          case 'status':
            break;
          case 'playPause':
            if (v.paused) v.play(); else v.pause();
            break;
          case 'pause':
            v.pause();
            break;
          case 'playAt':
            v.currentTime = clamp(arg[0], 0, v.duration || Infinity);
            v.playbackRate = clamp(arg[1], 0.25, 5);
            v.play();
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
            if (!navigator.userActivation.isActive) return {error: GESTURE};
            var fb = document.querySelector('.ytp-fullscreen-button');
            if (fb) fb.click(); else v.requestFullscreen();
            fullscreen = true;
            break;
          }
          default:
            return {error: 'Unknown media command: ' + cmd};
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
        return out;
      }

      function embedOut(f, fullscreen, warning) {
        var s = stateOf(f), info = s.info, data = info.videoData || {};
        var id = embedId(f);
        var volume = val(s, 'volume');
        var out = {
          time: timeOf(s),
          duration: info.duration,
          rate: val(s, 'playbackRate') || 1,
          paused: !playingNow(s),
          volume: typeof volume === 'number' ? volume / 100 : null,
          muted: !!val(s, 'muted'),
          fullscreen: fullscreen,
          url: id ? 'https://www.youtube.com/watch?v=' + id : null,
          title: data.title || null
        };
        if (s.reloaded) {
          s.reloaded = false;
          warning = warning || 'reloaded the embed to control it';
        }
        if (warning) out.warning = warning;
        return out;
      }

      function runEmbed(f, cmd, arg) {
        var fullscreen = !!document.fullscreenElement;
        if (cmd === 'fullscreenToggle') {
          // the iframe itself goes fullscreen, which needs no player API
          if (fullscreen) document.exitFullscreen();
          else if (!navigator.userActivation.isActive) return {error: GESTURE};
          else f.requestFullscreen();
          return embedOut(f, !fullscreen);
        }
        if (!apiOn(f)) { enable(f); return {pending: true}; }
        var s = stateOf(f);
        if (!s.ready) { listen(f); return {pending: true}; }
        var info = s.info;
        var end = info.duration || Infinity;
        var warning = null;
        switch (cmd) {
          case 'status':
            break;
          case 'playPause': {
            var playing = playingNow(s);
            freeze(s);
            post(f, playing ? 'pauseVideo' : 'playVideo');
            setAhead(s, 'playerState', playing ? 2 : 1);
            break;
          }
          case 'pause':
            freeze(s);
            post(f, 'pauseVideo');
            setAhead(s, 'playerState', 2);
            break;
          case 'playAt': {
            var at = clamp(arg[0], 0, end), rate = nearestRate(info, arg[1]);
            post(f, 'seekTo', [at, true]);
            post(f, 'setPlaybackRate', [rate]);
            post(f, 'playVideo');
            setAhead(s, 'currentTime', at);
            setAhead(s, 'playbackRate', rate);
            setAhead(s, 'playerState', 1);
            break;
          }
          case 'seekBy':
          case 'seekTo': {
            var to = clamp(cmd === 'seekBy' ? (timeOf(s) || 0) + arg : arg, 0, end);
            post(f, 'seekTo', [to, true]);
            setAhead(s, 'currentTime', to);
            break;
          }
          case 'rateMul':
          case 'rateSet': {
            var r = cmd === 'rateMul'
              ? stepRate(info, val(s, 'playbackRate') || 1, arg)
              : nearestRate(info, arg);
            freeze(s);
            post(f, 'setPlaybackRate', [r]);
            setAhead(s, 'playbackRate', r);
            break;
          }
          case 'volumeBy': {
            var v = val(s, 'volume');
            var vol = clamp(Math.round((typeof v === 'number' ? v : 100) + arg * 100), 0, 100);
            post(f, 'setVolume', [vol]);
            setAhead(s, 'volume', vol);
            if (arg > 0 && val(s, 'muted')) { post(f, 'unMute'); setAhead(s, 'muted', false); }
            break;
          }
          case 'muteToggle': {
            var muted = !!val(s, 'muted');
            post(f, muted ? 'unMute' : 'mute');
            setAhead(s, 'muted', !muted);
            break;
          }
          case 'subsToggle': {
            // the embed lists its tracks but never reports which one shows,
            // and it takes a track only as the object it listed
            var cap = s.modules.captions || {};
            var tracks = cap.tracklist || [];
            var on = s.captions !== undefined ? s.captions : !!(cap.track && cap.track.languageCode);
            if (on) {
              post(f, 'setOption', ['captions', 'track', {}]);
              s.captions = false;
            } else if (tracks.length) {
              post(f, 'setOption', ['captions', 'track',
                                    tracks.find(function(t) { return t.is_default; }) || tracks[0]]);
              s.captions = true;
            } else {
              post(f, 'loadModule', ['captions']);
              warning = 'no subtitles';
            }
            break;
          }
          case 'next':
          case 'prev':
            if ('playlist' in info && !info.playlist) warning = 'no playlist in this player';
            else post(f, cmd === 'next' ? 'nextVideo' : 'previousVideo');
            break;
          case 'theaterToggle':
            warning = 'an embedded player has no theater mode';
            break;
          default:
            return {error: 'Unknown media command: ' + cmd};
        }
        return embedOut(f, fullscreen, warning);
      }
    `;
  },

  _mediaJS(cmd, arg) {
    return "(function() {" + this._pageJS() + "\nreturn JSON.stringify(run(" +
      JSON.stringify(cmd) + ", " + JSON.stringify(arg === undefined ? null : arg) + "));\n})()";
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
  mediaFullscreenToggle(browserName, tabId) {
    const found = this._tabById(browserName, tabId);
    if (!found) return {error: "The media tab is gone"};
    const shown = this.showTab(browserName, found.windowIndex, found.tabIndex);
    if (shown.error) return shown;
    const browser = Application(browserName);
    const tab = found.tab;
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
    const state = this._runOn(browser, found, "fullscreenToggle", null);
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
    const ids = win.tabs.id();
    const tabIndex = ids.length;
    return {
      id: ids[tabIndex - 1],
      windowIndex: 1,
      tabIndex: tabIndex,
      url: url,
      title: ""
    };
  }
};
