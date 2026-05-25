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
  }
};
