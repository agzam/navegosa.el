// Tests for the media logic in navegosa-scripts.js: node --test test/
// A fake browser stands in for JXA's Application, so this runs anywhere.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "navegosa-scripts.js"), "utf8");
const Navegosa = new Function(source + "\nreturn Navegosa;")();

const runCall = /return JSON\.stringify\(run\(("(?:[^"\\]|\\.)*"), ([\s\S]*)\)\);\n\}\)\(\)$/;

// windows: [{active: TAB-INDEX, tabs: [{id, url, title, player, playing, muted}]}]
function fakeBrowser(windows) {
  const commands = [];
  const tabSpec = (tab) => ({
    execute({javascript}) {
      if (javascript === Navegosa._probeJS()) {
        if (tab.hangs) throw new Error("probed an unloaded tab " + tab.id);
        if (tab.refuses) throw new Error("this page takes no script");
        return JSON.stringify({player: !!tab.player, playing: !!tab.playing,
                               audible: !!tab.playing && !tab.muted});
      }
      const call = javascript.match(runCall);
      const cmd = JSON.parse(call[1]), arg = JSON.parse(call[2]);
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
    // JXA's tab list answers bulk getters and indexing alike
    tabs: Object.assign(w.tabs.map((t) => tabSpec(t)), {
      id: () => w.tabs.map((t) => t.id),
      url: () => w.tabs.map((t) => t.url),
      name: () => w.tabs.map((t) => t.title),
      byId: (id) => tabSpec(w.tabs.find((t) => t.id === id)),
    }),
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

const yt = (id, extra) =>
  Object.assign({id, url: "https://youtube.com/watch?v=" + id, title: id, player: true}, extra);
const page = (id, extra) => Object.assign({id, url: "https://blog.example/" + id, title: id}, extra);

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

test("with nothing playing, the shown tab, then the last one, then the only one", () => {
  assert.strictEqual(run([{active: 2, tabs: [yt("a"), yt("b")]}], null, "a", "", "pick").result.target.id, "b");
  assert.strictEqual(run([{active: 9, tabs: [yt("a"), yt("b")]}], null, "b", "", "pick").result.target.id, "b");
  assert.strictEqual(run([{active: 9, tabs: [yt("a")]}], null, null, "", "pick").result.target.id, "a");
});

test("the shown tab joins whatever its URL while it holds a player", () => {
  const {result} = run([{active: 2, tabs: [yt("a"), page("blog", {player: true})]}],
                       null, "a", "", "list");
  assert.deepStrictEqual(result.tabs.map((t) => [t.id, t.matched]), [["a", true], ["blog", false]]);
  assert.strictEqual(run([{active: 2, tabs: [yt("a"), page("blog", {player: true})]}],
                         null, "a", "", "pick").result.target.id, "blog");
});

test("a shown tab without a player stays out", () => {
  const {result} = run([{active: 2, tabs: [yt("a"), page("news")]}], null, null, "", "list");
  assert.deepStrictEqual(result.tabs.map((t) => t.id), ["a"]);
});

test("the last controlled tab stays a candidate while hidden, whatever its URL", () => {
  const tabs = [page("news"), page("blog", {player: true})];
  const {result, logged} = run([{active: 1, tabs}], null, "blog", "", "pick");
  assert.strictEqual(result.target.id, "blog");
  assert.deepStrictEqual(logged, ["probe news", "probe blog", "run"]);
});

test("a page that takes no script is left out, not fatal", () => {
  const {result} = run([{active: 1, tabs: [page("settings", {refuses: true}), yt("a")]}],
                       null, null, "", "pick");
  assert.strictEqual(result.target.id, "a");
});

test("off the URL patterns a tab plays only with sound", () => {
  const tabs = [page("gifs", {player: true, playing: true, muted: true}), yt("a", {playing: true, muted: true})];
  const {result, commands} = run([{active: 1, tabs}], null, null, "", "playPause");
  assert.strictEqual(result.id, "a");
  assert.deepStrictEqual(commands, [["a", "playPause"]]);
});

test("a skipped tab off the URL patterns is not checked even while shown", () => {
  const tabs = [page("blog", {player: true, hangs: true}), yt("a")];
  const {result, logged} = run([{active: 1, tabs}], null, null, "blog", "list");
  assert.deepStrictEqual(logged, ["probe a", "run"]);
  assert.deepStrictEqual(result.tabs.map((t) => t.id), ["a"]);
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
  const {result} = run([{active: 1, tabs: [page("n")]}], null, null, "", "status");
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

test("findMediaTab sends an embedded video home while its tab still shows the page", () => {
  const blog = {id: "k", url: "https://blog.example/post#comments", title: "Post"};
  const {app} = fakeBrowser([{active: 1, tabs: [yt("a"), blog]}]);
  globalThis.Application = () => app;
  const url = "https://www.youtube.com/watch?v=n-AfvuV-bYo";
  const found = Navegosa.findMediaTab("Brave", "youtube", url, "k", "https://blog.example/post");
  assert.deepStrictEqual([found.id, found.windowIndex, found.tabIndex, found.url],
                         ["k", 1, 2, "https://blog.example/post"]);
  blog.url = "https://blog.example/another-post";
  assert.strictEqual(Navegosa.findMediaTab("Brave", "youtube", url, "k", "https://blog.example/post"),
                     null);
});

test("findMediaTab refuses a URL no media pattern matches", () => {
  const {app} = fakeBrowser([{active: 1, tabs: []}]);
  globalThis.Application = () => app;
  assert.match(Navegosa.findMediaTab("Brave", "youtube", "https://example.com/v.mp4").error,
               /no navegosa-media-url-patterns entry matches/);
});

// _runOn spins the run loop through ObjC; a fake clock stands in.
function withFakeClock(fn) {
  const spin = Navegosa._spin, now = Date.now;
  let clock = 0;
  Navegosa._spin = (seconds) => { clock += seconds * 1000; };
  Date.now = () => clock;
  try { return fn(); } finally { Navegosa._spin = spin; Date.now = now; }
}

function scriptedTab(answers) {
  const tab = {url: () => "https://blog.example/post", name: () => "Post",
               execute: () => JSON.stringify(answers.length > 1 ? answers.shift() : answers[0])};
  return {windows: [{tabs: {byId: () => tab}}]};
}

test("_runOn waits while an embed reloads and answers, then takes its URL and title", () => {
  const browser = scriptedTab([{pending: true}, {pending: true},
                               {time: 5, paused: false, url: "https://www.youtube.com/watch?v=n-AfvuV-bYo",
                                title: "Fast, Async LaTeX Previews in Org Mode"}]);
  const state = withFakeClock(() => Navegosa._runOn(browser, {id: "k", windowIndex: 1}, "playPause"));
  assert.deepStrictEqual([state.url, state.title, state.id, state.page],
                         ["https://www.youtube.com/watch?v=n-AfvuV-bYo",
                          "Fast, Async LaTeX Previews in Org Mode", "k", "https://blog.example/post"]);
});

test("_runOn gives up on an embed that never answers", () => {
  const browser = scriptedTab([{pending: true}]);
  const state = withFakeClock(() => Navegosa._runOn(browser, {id: "k", windowIndex: 1}, "status"));
  assert.match(state.error, /did not answer/);
});

test("_runOn names a video's state after its tab", () => {
  const browser = scriptedTab([{time: 1, paused: true}]);
  const state = Navegosa._runOn(browser, {id: "k", windowIndex: 1}, "status");
  assert.deepStrictEqual([state.url, state.title, state.page],
                         ["https://blog.example/post", "Post", "https://blog.example/post"]);
});

// --- page side: the program _probeJS and _mediaJS send, run against a fake DOM

const box = (left, top, width, height) => () =>
  ({left, top, width, height, right: left + width, bottom: top + height});

function fakeVideo(props) {
  return Object.assign({readyState: 4, duration: 60, paused: true, muted: false, volume: 1,
                        controls: true, currentTime: 0, playbackRate: 1,
                        getBoundingClientRect: box(0, 0, 640, 360),
                        play() { this.paused = false; }, pause() { this.paused = true; }}, props);
}

function fakeEmbed(src, rect) {
  const f = {src, sent: [], loads: [],
             contentWindow: {postMessage: (data) => f.sent.push(JSON.parse(data))},
             getBoundingClientRect: rect || box(0, 0, 680, 382),
             addEventListener: (type, fn) => { if (type === "load") f.loads.push(fn); },
             scrollIntoView: (opts) => { f.scrolled = opts; },
             requestFullscreen: () => { f.fullscreen = true; }};
  return f;
}

function fakePage({videos = [], iframes = [], activation = false} = {}) {
  const listeners = [];
  const win = {innerWidth: 1200, innerHeight: 800,
               addEventListener: (type, fn) => { if (type === "message") listeners.push(fn); },
               removeEventListener: () => {}};
  const doc = {fullscreenElement: null,
               querySelectorAll: (sel) => (sel === "video" ? videos : sel === "iframe" ? iframes : []),
               querySelector: (sel) => (sel === "video" ? videos[0] || null : null),
               exitFullscreen: () => { doc.fullscreenElement = null; }};
  const nav = {userActivation: {isActive: activation}};
  const exec = (js) => JSON.parse(new Function("window", "document", "navigator", "return " + js)(win, doc, nav));
  return {
    run: (cmd, arg) => exec(Navegosa._mediaJS(cmd, arg)),
    probe: () => exec(Navegosa._probeJS()),
    // what the embed's player sends back to the page
    reply: (f, msg, origin = "https://www.youtube-nocookie.com") =>
      listeners.forEach((fn) => fn({origin, source: f.contentWindow, data: JSON.stringify(msg)})),
  };
}

const EMBED_SRC = "https://www.youtube-nocookie.com/embed/n-AfvuV-bYo?start=10";

// An embed that took the API: it answered the handshake with its state.
function readyEmbed(info, videos = []) {
  const f = fakeEmbed(EMBED_SRC + "&enablejsapi=1");
  const p = fakePage({iframes: [f], videos});
  p.run("status");
  p.reply(f, {event: "initialDelivery", info: Object.assign(
    {playerState: 2, currentTime: 30, duration: 793, playbackRate: 1, volume: 100, muted: false,
     videoData: {video_id: "n-AfvuV-bYo", title: "Fast, Async LaTeX Previews in Org Mode"}}, info)});
  p.reply(f, {event: "onReady"});
  f.sent.length = 0;
  return {f, p};
}

const commandsSent = (f) => f.sent.filter((m) => m.event === "command").map((m) => [m.func, ...m.args]);

test("an embed without the API reloads with enablejsapi=1 and the call waits for it", () => {
  const f = fakeEmbed(EMBED_SRC);
  const p = fakePage({iframes: [f]});
  assert.deepStrictEqual(p.run("playPause"), {pending: true});
  const url = new URL(f.src);
  assert.strictEqual(url.searchParams.get("enablejsapi"), "1");
  assert.strictEqual(url.searchParams.get("start"), "10");
  f.loads.forEach((fn) => fn());
  assert.deepStrictEqual(f.sent.map((m) => m.event), ["listening"]);
});

test("once the reloaded embed answers, play-pause plays it and says it reloaded", () => {
  const f = fakeEmbed(EMBED_SRC);
  const p = fakePage({iframes: [f]});
  p.run("playPause");
  assert.deepStrictEqual(p.run("playPause"), {pending: true});
  p.reply(f, {event: "initialDelivery", info: {playerState: -1, currentTime: 10, duration: 793,
                                                videoData: {video_id: "n-AfvuV-bYo", title: "Fast"}}});
  p.reply(f, {event: "onReady"});
  const state = p.run("playPause");
  assert.deepStrictEqual(commandsSent(f), [["playVideo"]]);
  assert.strictEqual(state.paused, false);
  assert.strictEqual(state.url, "https://www.youtube.com/watch?v=n-AfvuV-bYo");
  assert.strictEqual(state.title, "Fast");
  assert.strictEqual(state.warning, "reloaded the embed to control it");
  assert.strictEqual(p.run("status").warning, undefined);
});

test("messages from another origin do not count as the embed's answer", () => {
  const f = fakeEmbed(EMBED_SRC + "&enablejsapi=1");
  const p = fakePage({iframes: [f]});
  p.reply(f, {event: "onReady"}, "https://evil.example");
  assert.deepStrictEqual(p.run("status"), {pending: true});
});

test("play-pause pauses a playing embed", () => {
  const {f, p} = readyEmbed({playerState: 1});
  assert.strictEqual(p.run("playPause").paused, true);
  assert.deepStrictEqual(commandsSent(f), [["pauseVideo"]]);
});

// The page side reads Date.now for its predicted positions.
function atClock(fn) {
  const now = Date.now;
  const clock = {t: 1e6};
  Date.now = () => clock.t;
  try { return fn(clock); } finally { Date.now = now; }
}

test("play starts from the paused position, not from the time since its last report", () => {
  atClock((clock) => {
    const {f, p} = readyEmbed({});
    clock.t += 20000;
    assert.strictEqual(p.run("playPause").time, 30);
    clock.t += 1000;
    assert.strictEqual(p.run("status").time, 31);
    // once the embed reports, its own reading takes over
    p.reply(f, {event: "infoDelivery", info: {playerState: 1, currentTime: 31}});
    clock.t += 2000;
    assert.strictEqual(p.run("status").time, 33);
  });
});

test("pause pins the position the video reached", () => {
  atClock((clock) => {
    const {p} = readyEmbed({playerState: 1});
    clock.t += 500;
    assert.strictEqual(p.run("pause").time, 30.5);
    clock.t += 1000;
    assert.strictEqual(p.run("status").time, 30.5);
  });
});

test("held seeks chain on the predicted position before the embed reports it", () => {
  const {f, p} = readyEmbed({});
  assert.strictEqual(p.run("seekBy", 5).time, 35);
  p.run("seekBy", 5);
  assert.deepStrictEqual(commandsSent(f), [["seekTo", 35, true], ["seekTo", 40, true]]);
});

test("speed steps through the rates YouTube plays", () => {
  const {f, p} = readyEmbed({});
  assert.strictEqual(p.run("rateMul", 1.1).rate, 1.25);
  assert.strictEqual(p.run("rateMul", 1.1).rate, 1.5);
  assert.strictEqual(p.run("rateMul", 1 / 1.1).rate, 1.25);
  assert.strictEqual(p.run("rateSet", 1.21).rate, 1.25);
  assert.deepStrictEqual(commandsSent(f).map((c) => c[1]), [1.25, 1.5, 1.25, 1.25]);
});

test("volume moves on the player's 0-100 scale and unmutes on the way up", () => {
  const {f, p} = readyEmbed({volume: 50, muted: true});
  const state = p.run("volumeBy", 0.1);
  assert.deepStrictEqual(commandsSent(f), [["setVolume", 60], ["unMute"]]);
  assert.deepStrictEqual([state.volume, state.muted], [0.6, false]);
});

test("playAt seeks, sets the nearest rate and plays", () => {
  const {f, p} = readyEmbed({});
  const state = p.run("playAt", [754.3, 1.5]);
  assert.deepStrictEqual(commandsSent(f), [["seekTo", 754.3, true], ["setPlaybackRate", 1.5], ["playVideo"]]);
  // it plays, so the position runs on while the call returns
  assert.ok(Math.abs(state.time - 754.3) < 0.1, "time " + state.time);
  assert.deepStrictEqual([state.rate, state.paused], [1.5, false]);
});

test("subtitles switch on with a track the embed listed, then off", () => {
  const {f, p} = readyEmbed({});
  const en = {languageCode: "en", languageName: "English", kind: "", vss_id: ".en"};
  p.reply(f, {event: "apiInfoDelivery", info: {namespaces: ["captions"],
                                                captions: {track: {}, tracklist: [en]}}});
  p.run("subsToggle");
  p.run("subsToggle");
  assert.deepStrictEqual(commandsSent(f), [["setOption", "captions", "track", en],
                                           ["setOption", "captions", "track", {}]]);
});

test("subtitles warn when the embed lists no track", () => {
  const {f, p} = readyEmbed({});
  assert.strictEqual(p.run("subsToggle").warning, "no subtitles");
  assert.deepStrictEqual(commandsSent(f), [["loadModule", "captions"]]);
});

test("playAt plays the embed that shows the video, not the player in view", () => {
  const inView = fakeEmbed("https://www.youtube-nocookie.com/embed/u44X_th6_oY?enablejsapi=1",
                           box(0, 0, 900, 500));
  const below = fakeEmbed(EMBED_SRC + "&enablejsapi=1", box(0, 2000, 680, 382));
  const p = fakePage({iframes: [inView, below]});
  p.run("status");
  [inView, below].forEach((f) => {
    p.reply(f, {event: "initialDelivery", info: {playerState: 2, currentTime: 0, duration: 600}});
    p.reply(f, {event: "onReady"});
    f.sent.length = 0;
  });
  const state = p.run("playAt", [120, 1.25, "https://www.youtube.com/watch?v=n-AfvuV-bYo"]);
  assert.deepStrictEqual(commandsSent(below), [["seekTo", 120, true], ["setPlaybackRate", 1.25], ["playVideo"]]);
  assert.deepStrictEqual(commandsSent(inView), []);
  assert.deepStrictEqual(below.scrolled, {block: "nearest"});
  assert.strictEqual(state.url, "https://www.youtube.com/watch?v=n-AfvuV-bYo");
});

test("an embedded player answers theater with a warning, not a click", () => {
  const {f, p} = readyEmbed({});
  assert.match(p.run("theaterToggle").warning, /no theater mode/);
  assert.deepStrictEqual(commandsSent(f), []);
});

test("fullscreen puts the embed's iframe on screen and needs no API", () => {
  const f = fakeEmbed(EMBED_SRC);
  const p = fakePage({iframes: [f], activation: true});
  assert.strictEqual(p.run("fullscreenToggle").fullscreen, true);
  assert.ok(f.fullscreen);
  assert.strictEqual(f.src, EMBED_SRC);
});

test("the player in view beats a larger one off screen", () => {
  const offscreen = fakeVideo({getBoundingClientRect: box(0, -3000, 700, 549)});
  const {p} = readyEmbed({}, [offscreen]);
  assert.strictEqual(p.run("status").url, "https://www.youtube.com/watch?v=n-AfvuV-bYo");
  offscreen.getBoundingClientRect = box(0, 0, 700, 549);
  assert.strictEqual(p.run("status").url, undefined);
});

test("a video playing with sound beats a muted loop", () => {
  const loop = fakeVideo({paused: false, muted: true, controls: false,
                          getBoundingClientRect: box(0, 0, 1000, 700)});
  const talk = fakeVideo({paused: false, getBoundingClientRect: box(0, 0, 300, 200), currentTime: 42});
  assert.strictEqual(fakePage({videos: [loop, talk]}).run("status").time, 42);
});

test("off the URL patterns, a muted loop is no player; controls or an embed are", () => {
  const loop = fakeVideo({paused: false, muted: true, controls: false});
  assert.deepStrictEqual(fakePage({videos: [loop]}).probe(), {player: false, playing: true, audible: false});
  assert.strictEqual(fakePage({videos: [fakeVideo({})]}).probe().player, true);
  assert.strictEqual(fakePage({iframes: [fakeEmbed(EMBED_SRC)]}).probe().player, true);
  assert.strictEqual(fakePage({}).probe().player, false);
});

test("the check never reloads an embed", () => {
  const f = fakeEmbed(EMBED_SRC);
  fakePage({iframes: [f]}).probe();
  assert.strictEqual(f.src, EMBED_SRC);
  assert.deepStrictEqual(f.sent, []);
});
