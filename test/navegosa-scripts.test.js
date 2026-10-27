// Tests for the media logic in navegosa-scripts.js: node --test test/
// A fake browser stands in for JXA's Application, so this runs anywhere.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "navegosa-scripts.js"), "utf8");
const Navegosa = new Function(source + "\nreturn Navegosa;")();

// windows: [{active: TAB-INDEX, tabs: [{id, url, title, playing}]}]
function fakeBrowser(windows) {
  const commands = [];
  const tabSpec = (tab) => ({
    execute({javascript}) {
      if (javascript === Navegosa._probeJS) {
        if (tab.hangs) throw new Error("probed an unloaded tab " + tab.id);
        return tab.playing ? "playing" : "paused";
      }
      const cmd = javascript.match(/var cmd = "([^"]+)"/)[1];
      const arg = JSON.parse(javascript.match(/var arg = (.*);/)[1]);
      commands.push(arg === null ? [tab.id, cmd] : [tab.id, cmd, arg]);
      if (cmd === "pause") tab.playing = false;
      if (cmd === "playPause") tab.playing = !tab.playing;
      if (cmd === "playAt") tab.playing = true;
      return JSON.stringify({time: 1, paused: !tab.playing});
    },
    url: () => tab.url,
    name: () => tab.title,
  });
  const wins = windows.map((w) => ({
    activeTabIndex: () => w.active,
    tabs: {
      id: () => w.tabs.map((t) => t.id),
      url: () => w.tabs.map((t) => t.url),
      name: () => w.tabs.map((t) => t.title),
      byId: (id) => tabSpec(w.tabs.find((t) => t.id === id)),
    },
  }));
  const app = {windows: Object.assign(() => wins, wins)};
  return {app, commands};
}

function run(windows, pick, last, skip, cmd, arg = null) {
  const {app, commands} = fakeBrowser(windows);
  const logged = [];
  globalThis.Application = () => app;
  const log = console.log;
  console.log = (line) => logged.push(line);
  try {
    const result = Navegosa.mediaRun("Brave", "youtube", pick, last, skip, cmd, arg);
    return {result, commands, logged};
  } finally {
    console.log = log;
  }
}

const yt = (id, extra) => Object.assign({id, url: "https://youtube.com/watch?v=" + id, title: id}, extra);

test("a playing tab beats the last controlled one", () => {
  const {result} = run([{active: 9, tabs: [yt("a"), yt("b", {playing: true})]}], null, "a", "", "pick");
  assert.strictEqual(result.target.id, "b");
});

test("the last controlled tab wins among several playing ones", () => {
  const tabs = [yt("a", {playing: true}), yt("b", {playing: true})];
  const {result} = run([{active: 9, tabs}], null, "b", "", "pick");
  assert.strictEqual(result.target.id, "b");
});

test("a pick beats a playing tab", () => {
  const {result} = run([{active: 9, tabs: [yt("a", {playing: true}), yt("b")]}], "b", "a", "", "pick");
  assert.strictEqual(result.target.id, "b");
});

test("with nothing playing, the last tab, then the shown one, then the only one", () => {
  assert.strictEqual(run([{active: 1, tabs: [yt("a"), yt("b")]}], null, "b", "", "pick").result.target.id, "b");
  assert.strictEqual(run([{active: 2, tabs: [yt("a"), yt("b")]}], null, null, "", "pick").result.target.id, "b");
  assert.strictEqual(run([{active: 9, tabs: [yt("a")]}], null, null, "", "pick").result.target.id, "a");
});

test("several idle tabs and no hint leave the choice to the caller", () => {
  const {result} = run([{active: 9, tabs: [yt("a"), yt("b")]}], null, null, "", "pick");
  assert.deepStrictEqual(result.tabs.map((t) => t.id), ["a", "b"]);
});

test("play-pause on a picked tab pauses the playing one and plays the pick", () => {
  const tabs = [yt("a", {playing: true}), yt("b")];
  const {result, commands} = run([{active: 9, tabs}], "b", "a", "", "playPause");
  assert.deepStrictEqual(commands, [["a", "pause"], ["b", "playPause"]]);
  assert.strictEqual(result.id, "b");
  assert.strictEqual(result.paused, false);
});

test("play-pause on a playing target silences every playing tab", () => {
  const tabs = [yt("a", {playing: true}), yt("b", {playing: true})];
  const {commands} = run([{active: 9, tabs}], null, "a", "", "playPause");
  assert.deepStrictEqual(commands, [["b", "pause"], ["a", "playPause"]]);
  assert.ok(tabs.every((t) => !t.playing));
});

test("other commands touch only the target", () => {
  const tabs = [yt("a", {playing: true}), yt("b", {playing: true})];
  const {commands} = run([{active: 9, tabs}], null, "a", "", "seekBy");
  assert.deepStrictEqual(commands, [["a", "seekBy"]]);
});

test("pauseAll pauses every playing tab and needs no target", () => {
  const tabs = [yt("a", {playing: true}), yt("b"), yt("c", {playing: true})];
  const {result, commands} = run([{active: 9, tabs}], null, null, "", "pauseAll");
  assert.strictEqual(result.paused, 2);
  assert.deepStrictEqual(commands, [["a", "pause"], ["c", "pause"]]);
});

test("each check is named before it runs, and the command after the last one", () => {
  const {logged} = run([{active: 9, tabs: [yt("a"), yt("b")]}], null, "a", "", "status");
  assert.deepStrictEqual(logged, ["probe a", "probe b", "run"]);
});

test("a skipped tab is not checked unless it is shown", () => {
  const hidden = run([{active: 9, tabs: [yt("a"), yt("b", {hangs: true})]}], null, "a", "b", "status");
  assert.deepStrictEqual(hidden.logged, ["probe a", "run"]);
  const shown = run([{active: 2, tabs: [yt("a"), yt("b")]}], null, "a", "b", "status");
  assert.deepStrictEqual(shown.logged, ["probe a", "probe b", "run"]);
});

test("tabs are found by id across windows", () => {
  const {result} = run([{active: 9, tabs: [yt("a")]}, {active: 9, tabs: [yt("x"), yt("b")]}],
                       "b", null, "", "pick");
  assert.deepStrictEqual([result.target.windowIndex, result.target.tabIndex], [2, 2]);
});

test("no media tabs is an error, not a choice", () => {
  const {result} = run([{active: 1, tabs: [{id: "n", url: "https://example.com", title: "n"}]}],
                       null, null, "", "status");
  assert.strictEqual(result.error, "no media tabs open");
});

test("playAt pauses the other playing tabs and plays the pick from time at rate", () => {
  const tabs = [yt("a", {playing: true}), yt("b")];
  const {result, commands} = run([{active: 9, tabs}], "b", "a", "", "playAt", [754.3, 1.5]);
  assert.deepStrictEqual(commands, [["a", "pause"], ["b", "playAt", [754.3, 1.5]]]);
  assert.strictEqual(result.id, "b");
});

test("playAt never falls back to another tab when the pick is gone", () => {
  const tabs = [yt("a", {playing: true})];
  const {result, commands} = run([{active: 1, tabs}], "b", "a", "", "playAt", [5, 1]);
  assert.strictEqual(result.error, "The media tab is gone");
  assert.deepStrictEqual(commands, []);
});

test("the same YouTube video matches across URL forms", () => {
  const same = (a, b) => Navegosa._sameMedia(a, b);
  assert.ok(same("https://www.youtube.com/watch?v=dQ6X0-XCLIw",
                 "https://youtu.be/dQ6X0-XCLIw?t=754"));
  assert.ok(same("https://www.youtube.com/watch?list=PL1&v=dQ6X0-XCLIw&t=10s",
                 "https://m.youtube.com/watch?v=dQ6X0-XCLIw"));
  assert.ok(!same("https://www.youtube.com/watch?v=dQ6X0-XCLIw",
                  "https://www.youtube.com/watch?v=aaaaaaaaaaa"));
  assert.ok(!same("https://www.youtube.com/watch?v=dQ6X0-XCLIw", "https://vimeo.com/1"));
});

test("other media matches up to the fragment", () => {
  assert.ok(Navegosa._sameMedia("http://localhost:8000/clip.mp4#t=33s",
                                "http://localhost:8000/clip.mp4"));
  assert.ok(!Navegosa._sameMedia("https://vimeo.com/1", "https://vimeo.com/2"));
});

test("findMediaTab finds the tab showing the video across windows, else null", () => {
  const vid = (id, v) => ({id, url: "https://www.youtube.com/watch?v=" + v, title: id});
  const {app} = fakeBrowser([{active: 1, tabs: [vid("a", "aaaaaaaaaaa")]},
                             {active: 1, tabs: [vid("b", "dQ6X0-XCLIw")]}]);
  globalThis.Application = () => app;
  const found = Navegosa.findMediaTab("Brave", "youtube|youtu\\.be", "https://youtu.be/dQ6X0-XCLIw");
  assert.deepStrictEqual([found.id, found.windowIndex, found.tabIndex], ["b", 2, 1]);
  assert.strictEqual(Navegosa.findMediaTab("Brave", "youtube", "https://youtube.com/watch?v=bbbbbbbbbbb"),
                     null);
});

test("findMediaTab refuses a URL no media pattern matches", () => {
  const {app} = fakeBrowser([{active: 1, tabs: []}]);
  globalThis.Application = () => app;
  assert.match(Navegosa.findMediaTab("Brave", "youtube", "https://example.com/v.mp4").error,
               /no navegosa-media-url-patterns entry matches/);
});
