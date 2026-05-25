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
  }
};
