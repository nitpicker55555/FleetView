// The editor page of FleetView's file window.
//
// One EditorView for the whole window; each tab is an EditorState swapped into it, so a tab costs
// its text and its undo history, not a web content process. Swift owns everything that touches the
// disk or git — versions, conflicts, watching, saving. This page only edits text and draws it, and
// talks to Swift through `fvBridge`: `post(msg)` for messages (a Promise when Swift replies) and
// `fetchText(url)` for file contents, which arrive through the `fvfile:` scheme rather than through
// the message channel, so a 20 MB file is one response and not one serialised argument.

import {EditorState, Compartment, StateEffect, StateField, RangeSetBuilder, Transaction, Text} from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection,
  highlightSpecialChars, Decoration, rectangularSelection, crosshairCursor, dropCursor,
} from "@codemirror/view";
import {defaultKeymap, history, historyKeymap, indentWithTab} from "@codemirror/commands";
import {searchKeymap, highlightSelectionMatches, openSearchPanel, setSearchQuery, SearchQuery, gotoLine} from "@codemirror/search";
import {syntaxHighlighting, HighlightStyle, bracketMatching, indentOnInput, foldGutter, foldKeymap, StreamLanguage} from "@codemirror/language";
import {tags as t, highlightTree} from "@lezer/highlight";
import {Chunk, MergeView, diff as textDiff} from "@codemirror/merge";
import MarkdownIt from "markdown-it";
import {markdown, markdownLanguage} from "@codemirror/lang-markdown";
import {javascript} from "@codemirror/lang-javascript";
import {python} from "@codemirror/lang-python";
import {json} from "@codemirror/lang-json";
import {html} from "@codemirror/lang-html";
import {css} from "@codemirror/lang-css";
import {yaml} from "@codemirror/lang-yaml";
import {xml} from "@codemirror/lang-xml";
import {rust} from "@codemirror/lang-rust";
import {go} from "@codemirror/lang-go";
import {cpp} from "@codemirror/lang-cpp";
import {java} from "@codemirror/lang-java";
import {sql} from "@codemirror/lang-sql";
import {swift} from "@codemirror/legacy-modes/mode/swift";
import {shell} from "@codemirror/legacy-modes/mode/shell";
import {toml} from "@codemirror/legacy-modes/mode/toml";
import {dockerFile} from "@codemirror/legacy-modes/mode/dockerfile";
import {properties} from "@codemirror/legacy-modes/mode/properties";
import {diff as diffMode} from "@codemirror/legacy-modes/mode/diff";
import {ruby} from "@codemirror/legacy-modes/mode/ruby";
import {lua} from "@codemirror/legacy-modes/mode/lua";

// ---------------------------------------------------------------- bridge

const bridge = window.fvBridge || {
  post(msg) {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fv;
    return h ? h.postMessage(msg) : Promise.resolve(null);
  },
  async fetchText(url) {
    const r = await fetch(url, {cache: "no-store"});
    const headers = {};
    r.headers.forEach((v, k) => { headers[k.toLowerCase()] = v; });
    return {ok: r.ok, status: r.status, text: await r.text(), headers};
  },
};
const post = (type, body = {}) => {
  try { return bridge.post({type, ...body}); } catch (e) { return Promise.resolve(null); }
};
const appURL = path => "fvfile://app/" + path;
const rawURL = abs => appURL("raw" + abs.split("/").map(encodeURIComponent).join("/"));

// ---------------------------------------------------------------- words

const WORDS = {
  zh: {
    outline: "大纲", noPreview: "没有内容", imageHint: "点图片在「适应窗口」和「实际大小」之间切换",
    compareTitle: "左边是磁盘上的版本，右边是你的。把需要的改动从左边拿过来，再保存右边。",
    saveMerged: "保存右边的结果", cancel: "取消", loading: "读取中…",
    files: "个文件", copySha: "复制 sha", cmpWT: "与工作区对比", sideBySide: "并排", open: "打开", parent: "父提交",
    rootCommit: "第一个提交", binary: "二进制文件，不显示内容", untrackedDir: "还没被 git 跟踪的文件夹，里面的文件不逐个列出",
    showInTree: "在目录树中显示", tooLong: "还有 $ 行没有显示", seeAll: "并排看全部", truncated: "diff 太大，只显示了开头",
    noChange: "内容没有变化（可能只改了权限）", refresh: "刷新", worktree: "工作区", nothing: "（无）", against: "相对",
    moreFiles: "还有 $ 个文件没有列出", noFiles: "没有改动", filterFiles: "筛选文件…", noMatch: "没有匹配的文件", close: "关闭", failed: "读不出来", newFile: "新文件",
    phrases: {
      "Find": "查找", "Replace": "替换", "next": "下一个", "previous": "上一个", "all": "全部",
      "match case": "区分大小写", "regexp": "正则", "by word": "整词", "replace": "替换",
      "replace all": "全部替换", "close": "关闭", "Go to line": "跳到行", "go": "跳转",
      "current match": "当前匹配", "on line": "在行", "replaced $ matches": "替换了 $ 处",
      "replaced match on line $": "替换了第 $ 行的匹配", "folded code": "已折叠", "unfold": "展开",
      "to": "到", "Control character": "控制字符", "Revert this chunk": "还原这一块",
      "Accept": "接受", "Reject": "拒绝", "Fold line": "折叠", "Unfold line": "展开",
    },
  },
  en: {
    outline: "Outline", noPreview: "Nothing to show", imageHint: "Click the image to switch between fit and actual size",
    compareTitle: "Left is the version on disk, right is yours. Bring over what you need from the left, then save the right.",
    saveMerged: "Save the right side", cancel: "Cancel", loading: "Loading…",
    files: "files", copySha: "Copy SHA", cmpWT: "Compare with working tree", sideBySide: "Side by side", open: "Open",
    parent: "parent", rootCommit: "first commit", binary: "Binary file, not shown",
    untrackedDir: "A folder git does not track yet; its files are not listed one by one", showInTree: "Show in tree",
    tooLong: "$ more lines not shown", seeAll: "See all side by side", truncated: "The diff is large; only its start is shown",
    noChange: "No change in content (perhaps only the mode)", refresh: "Refresh", worktree: "working tree", nothing: "(none)",
    against: "against", moreFiles: "$ more files not listed", noFiles: "No changes", filterFiles: "Filter files…", noMatch: "No matching files", close: "Close", failed: "Could not read it",
    newFile: "new file",
    phrases: {},
  },
};
let words = WORDS.en;

// ---------------------------------------------------------------- languages

const stream = mode => () => StreamLanguage.define(mode);
const LANGS = {
  markdown: () => markdown({base: markdownLanguage, codeLanguages: info => languageFor(info)}),
  javascript: () => javascript(), jsx: () => javascript({jsx: true}),
  typescript: () => javascript({typescript: true}), tsx: () => javascript({typescript: true, jsx: true}),
  python: () => python(), json: () => json(), html: () => html(), css: () => css(), yaml: () => yaml(),
  xml: () => xml(), rust: () => rust(), go: () => go(), cpp: () => cpp(), java: () => java(), sql: () => sql(),
  swift: stream(swift), shell: stream(shell), toml: stream(toml), dockerfile: stream(dockerFile),
  properties: stream(properties), diff: stream(diffMode), ruby: stream(ruby), lua: stream(lua),
};
// Fence names in Markdown, mapped onto the ids above.
const ALIAS = {
  js: "javascript", mjs: "javascript", cjs: "javascript", ts: "typescript", py: "python", sh: "shell",
  bash: "shell", zsh: "shell", console: "shell", yml: "yaml", rs: "rust", golang: "go", c: "cpp",
  "c++": "cpp", h: "cpp", hpp: "cpp", objc: "cpp", ini: "properties", conf: "properties",
  docker: "dockerfile", md: "markdown", patch: "diff", rb: "ruby", htm: "html", svg: "xml", plist: "xml",
};
const supportCache = new Map();
function supportFor(id) {
  id = ALIAS[id] || id;
  if (!LANGS[id]) return null;
  if (!supportCache.has(id)) supportCache.set(id, LANGS[id]());
  return supportCache.get(id);
}
function languageFor(info) {
  const s = supportFor((info || "").trim().toLowerCase().split(/\s/)[0]);
  return s ? (s.language || s) : null;
}

// ---------------------------------------------------------------- look

const highlight = HighlightStyle.define([
  {tag: [t.keyword, t.controlKeyword, t.operatorKeyword, t.definitionKeyword, t.moduleKeyword, t.modifier, t.self], color: "var(--hk)"},
  {tag: [t.string, t.special(t.string), t.regexp, t.character, t.inserted], color: "var(--hs)"},
  {tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--hc)", fontStyle: "italic"},
  {tag: [t.number, t.bool, t.null, t.atom, t.unit], color: "var(--hn)"},
  {tag: [t.typeName, t.className, t.namespace, t.standard(t.typeName)], color: "var(--ht)"},
  {tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: "var(--hf)"},
  {tag: [t.propertyName, t.attributeName, t.labelName], color: "var(--hp)"},
  {tag: [t.meta, t.annotation, t.processingInstruction, t.attributeValue], color: "var(--ha)"},
  {tag: t.tagName, color: "var(--hk)"},
  {tag: t.heading, color: "var(--hk)", fontWeight: "600"},
  {tag: [t.link, t.url], color: "var(--hf)", textDecoration: "underline"},
  {tag: t.strong, fontWeight: "600"},
  {tag: t.emphasis, fontStyle: "italic"},
  {tag: t.strikethrough, textDecoration: "line-through"},
  {tag: [t.invalid, t.deleted], color: "var(--err)"},
]);

const theme = EditorView.theme({
  "&": {height: "100%", color: "var(--text)", backgroundColor: "var(--bg)", fontSize: "var(--fs)"},
  ".cm-scroller": {fontFamily: "var(--mono)", lineHeight: "1.6"},
  ".cm-content": {caretColor: "var(--accent)", padding: "6px 0 40vh"},
  ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--accent)", borderLeftWidth: "2px"},
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {backgroundColor: "var(--sel) !important"},
  ".cm-gutters": {backgroundColor: "var(--bg)", color: "var(--gutter)", border: "none"},
  ".cm-lineNumbers .cm-gutterElement": {padding: "0 12px 0 14px", minWidth: "36px"},
  ".cm-activeLine": {backgroundColor: "var(--activeLine)"},
  ".cm-activeLineGutter": {backgroundColor: "transparent", color: "var(--text)"},
  ".cm-foldGutter .cm-gutterElement": {color: "var(--gutter)"},
  ".cm-panels": {backgroundColor: "var(--panel)", color: "var(--text)", borderColor: "var(--stroke)"},
  ".cm-panels.cm-panels-top": {borderBottom: "1px solid var(--stroke)"},
  ".cm-panel input, .cm-panel button, .cm-textfield": {fontFamily: "inherit", fontSize: "12px"},
  ".cm-textfield": {backgroundColor: "var(--bg)", color: "var(--text)", border: "1px solid var(--stroke)", borderRadius: "6px", padding: "3px 6px"},
  ".cm-button": {backgroundImage: "none", backgroundColor: "var(--high)", color: "var(--text)", border: "none", borderRadius: "6px", padding: "3px 10px"},
  ".cm-searchMatch": {backgroundColor: "var(--match)"},
  ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: "var(--matchCur)", color: "var(--onMatchCur)"},
  ".cm-selectionMatch": {backgroundColor: "var(--selMatch)"},
  ".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {backgroundColor: "var(--selMatch)", outline: "none"},
  ".cm-foldPlaceholder": {backgroundColor: "var(--high)", border: "none", color: "var(--sub)"},
  ".cm-tooltip": {backgroundColor: "var(--panel)", border: "1px solid var(--stroke)", color: "var(--text)"},
  ".cm-fv-changed": {backgroundColor: "var(--tint)"},
  ".cm-fv-added": {backgroundColor: "var(--tintAdd)"},
  ".cm-fv-deletedAbove": {boxShadow: "inset 0 2px 0 var(--del)"},
  ".cm-fv-flash": {animation: "fvflash 6s ease-out"},
  ".cm-fv-goto": {animation: "fvgoto 1.8s ease-out"},
}, {dark: true});

// ---------------------------------------------------------------- per-tab state

/** tab id → {meta, state, savedDoc, dirty, scroll, mode, head, headLen, chunks, ...} */
const docs = new Map();
let active = null;
let view = null;
let previewTimer = 0;
const host = {};

const readOnlyC = new Compartment(), langC = new Compartment(), wrapC = new Compartment(), phraseC = new Compartment();

// Lines changed against HEAD, and lines an outside reload just touched.
const setDiffDeco = StateEffect.define();
const diffField = StateField.define({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) if (e.is(setDiffDeco)) return e.value;
    return deco.map(tr.changes);
  },
  provide: f => EditorView.decorations.from(f),
});
const setFlash = StateEffect.define();
const flashField = StateField.define({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) if (e.is(setFlash)) return e.value;
    return deco.map(tr.changes);
  },
  provide: f => EditorView.decorations.from(f),
});

const changedLine = Decoration.line({class: "cm-fv-changed"});
const addedLine = Decoration.line({class: "cm-fv-added"});
const deletedAbove = Decoration.line({class: "cm-fv-deletedAbove"});
const flashLine = Decoration.line({class: "cm-fv-flash"});
const gotoLineDeco = Decoration.line({class: "cm-fv-goto"});

/** How much work a document of this size may cost per edit. */
function tier(len) {
  if (len <= 2_000_000) return {diff: true, wait: 200, budget: 100};
  if (len <= 20_000_000) return {diff: true, wait: 1000, budget: 200};
  return {diff: false};
}

function lineDecos(doc, ranges, deco) {
  const b = new RangeSetBuilder();
  for (const [from, to] of ranges) {
    let pos = Math.min(from, doc.length);
    // A range ending at a line's start stops on the line before it: an inserted "…\n" must not
    // light up the untouched line that follows.
    let end = Math.min(to, doc.length);
    if (end > pos && doc.lineAt(end).from === end) end -= 1;
    for (;;) {
      const line = doc.lineAt(pos);
      b.add(line.from, line.from, deco);
      if (line.to >= end || line.number >= doc.lines) break;
      pos = line.to + 1;
    }
  }
  return b.finish();
}

function chunkDecos(doc, chunks) {
  const b = new RangeSetBuilder();
  for (const c of chunks) {
    if (c.fromB === c.toB) {
      const line = doc.lineAt(Math.min(c.fromB, doc.length));
      b.add(line.from, line.from, deletedAbove);
      continue;
    }
    const deco = c.fromA === c.toA ? addedLine : changedLine;
    let pos = c.fromB;
    const end = Math.min(c.endB, doc.length);
    for (;;) {
      const line = doc.lineAt(pos);
      b.add(line.from, line.from, deco);
      if (line.to >= end || line.number >= doc.lines) break;
      pos = line.to + 1;
    }
  }
  return b.finish();
}

function chunkStats(d, chunks) {
  let added = 0, changed = 0, deleted = 0;
  for (const c of chunks) {
    const linesB = c.fromB === c.toB ? 0 : d.state.doc.lineAt(Math.min(c.endB, d.state.doc.length)).number - d.state.doc.lineAt(c.fromB).number + 1;
    const linesA = c.fromA === c.toA ? 0 : d.head.lineAt(Math.min(c.endA, d.head.length)).number - d.head.lineAt(c.fromA).number + 1;
    if (!linesA) added += linesB;
    else if (!linesB) deleted += linesA;
    else { changed += Math.min(linesA, linesB); if (linesB > linesA) added += linesB - linesA; else deleted += linesA - linesB; }
  }
  return {added, changed, deleted};
}

function scheduleDiff(d) {
  clearTimeout(d.diffTimer);
  if (!d.head || !d.tier.diff) return;
  d.diffTimer = setTimeout(() => computeDiff(d), d.tier.wait);
}

function computeDiff(d) {
  if (!d.head || !d.state) return;
  const state = d.id === active ? view.state : d.state;
  const chunks = Chunk.build(d.head, state.doc, {scanLimit: 20000, timeout: d.tier.budget});
  d.chunks = chunks;
  const effects = setDiffDeco.of(chunkDecos(state.doc, chunks));
  if (d.id === active) view.dispatch({effects});
  else d.state = d.state.update({effects}).state;
  const s = chunkStats({state, head: d.head}, chunks);
  post("diffStats", {tab: d.id, ...s});
  if (d.id === active && d.mode === "preview") renderPreviewSoon(d, 0);
}

// ---------------------------------------------------------------- editor setup

function baseExtensions(d) {
  const big = d.meta.length > 20_000_000 || d.meta.longLine;
  const support = big ? null : supportFor(d.meta.lang);
  return [
    lineNumbers(), foldGutter(), highlightActiveLineGutter(), highlightSpecialChars(), history(),
    drawSelection(), dropCursor(), indentOnInput(), bracketMatching(), rectangularSelection(),
    crosshairCursor(), highlightActiveLine(), highlightSelectionMatches(),
    syntaxHighlighting(highlight), theme, diffField, flashField,
    langC.of(support || []),
    readOnlyC.of(EditorState.readOnly.of(!!d.meta.readOnly)),
    wrapC.of(d.wrap ? EditorView.lineWrapping : []),
    phraseC.of(EditorState.phrases.of(words.phrases)),
    keymap.of([
      {key: "Mod-s", run: () => { save(d.id); return true; }, preventDefault: true},
      {key: "Mod-p", run: () => { post("key", {name: "quickOpen"}); return true; }, preventDefault: true},
      {key: "Mod-Shift-f", run: () => { post("key", {name: "searchFiles"}); return true; }, preventDefault: true},
      {key: "Mod-w", run: () => { post("key", {name: "closeTab"}); return true; }, preventDefault: true},
      {key: "Mod-Alt-c", run: () => { post("key", {name: "copyPath"}); return true; }, preventDefault: true},
      {key: "Ctrl--", run: () => { post("key", {name: "back"}); return true; }, preventDefault: true},
      {key: "Ctrl-Shift--", run: () => { post("key", {name: "forward"}); return true; }, preventDefault: true},
      {key: "Ctrl-g", run: gotoLine, preventDefault: true},
      ...defaultKeymap, ...historyKeymap, ...searchKeymap, ...foldKeymap, indentWithTab,
    ]),
    EditorView.updateListener.of(u => onUpdate(d, u)),
  ];
}

function onUpdate(d, u) {
  if (d.id !== active) return;
  if (u.docChanged) {
    const doc = u.state.doc;
    const clean = doc === d.savedDoc || (doc.length === d.savedDoc.length && doc.eq(d.savedDoc));
    setDirty(d, !clean);
    scheduleDiff(d);
    if (d.dirty) scheduleSnapshot(d);
  }
  if (u.selectionSet || u.docChanged) reportCursor(d, u.state);
}

let cursorTimer = 0;
function reportCursor(d, state) {
  clearTimeout(cursorTimer);
  cursorTimer = setTimeout(() => {
    const head = state.selection.main.head, line = state.doc.lineAt(head);
    post("cursor", {tab: d.id, line: line.number, col: head - line.from + 1, lines: state.doc.lines});
  }, 120);
}

function setDirty(d, dirty) {
  if (d.dirty === dirty) return;
  d.dirty = dirty;
  post("dirty", {tab: d.id, dirty});
  if (!dirty) { clearTimeout(d.snapTimer); d.snapped = null; }
}

// Unsaved text is mirrored to Swift once typing pauses, so a crashed page or a forced quit loses at
// most the last second. Larger documents wait longer: each mirror is a full copy of the text, through
// the message channel and onto disk.
function scheduleSnapshot(d) {
  clearTimeout(d.snapTimer);
  const len = (d.id === active ? view.state : d.state).doc.length;
  const wait = len <= 2_000_000 ? 1000 : len <= 20_000_000 ? 15_000 : 60_000;
  d.snapTimer = setTimeout(() => {
    const doc = d.id === active ? view.state.doc : d.state.doc;
    if (!d.dirty || doc === d.snapped) return;
    d.snapped = doc;
    post("snapshot", {tab: d.id, text: doc.toString()});
  }, wait);
}

// ---------------------------------------------------------------- loading

// One read at a time per tab: `open`, `show` and `restore` can all ask while the first is on its way,
// and a second state built from a second read would replace whatever was typed into the first.
function load(d) {
  if (!d.loading) d.loading = loadNow(d).finally(() => { d.loading = null; });
  return d.loading;
}

async function loadNow(d) {
  const r = await bridge.fetchText(appURL("doc/" + encodeURIComponent(d.id)));
  if (!r.ok) { d.info = infoFrom(r); return false; }
  adopt(d, r);
  return true;
}

function infoFrom(r) {
  try { return JSON.parse(r.text); } catch (e) { return {kind: "error", title: r.text || String(r.status)}; }
}

/** A fresh editor state for the text in `r`: what the tab now holds, unedited. */
function adopt(d, r) {
  readOnlyFrom(d, r);
  d.meta.length = r.text.length;
  d.meta.longLine = hasLongLine(r.text);
  d.tier = tier(r.text.length);
  d.state = EditorState.create({doc: r.text, extensions: baseExtensions(d)});
  d.savedDoc = d.state.doc;
  d.dirty = false;
  d.info = null;
}

/** Whether the file can be edited is the file's to say, every time it is read: a reload can turn a
 *  clean file into one with mixed line endings. */
function readOnlyFrom(d, r) {
  const reason = r.headers["x-fv-readonly"] || "";
  const was = !!d.meta.readOnly;
  d.meta.readOnly = !!reason;
  d.meta.readOnlyReason = reason;
  if (d.state && was !== d.meta.readOnly) {
    const effects = readOnlyC.reconfigure(EditorState.readOnly.of(d.meta.readOnly));
    if (d.id === active) { view.dispatch({effects}); d.state = view.state; } else d.state = d.state.update({effects}).state;
  }
}

/** Tell Swift the editor now holds this version of the file: only then is it what a save is checked
 *  against. */
function applied(d, r) {
  post("applied", {tab: d.id, version: r.headers["x-fv-version"] || "", readOnly: d.meta.readOnlyReason || ""});
}

function hasLongLine(text) {
  let start = 0;
  for (;;) {
    const nl = text.indexOf("\n", start);
    const end = nl < 0 ? text.length : nl;
    if (end - start > 10000) return true;
    if (nl < 0) return false;
    start = nl + 1;
  }
}

async function loadHead(d) {
  if (!d.tier || !d.tier.diff) return;
  const r = await bridge.fetchText(appURL("head/" + encodeURIComponent(d.id)));
  if (!docs.has(d.id)) return;
  d.head = r.ok ? EditorState.create({doc: r.text}).doc : null;
  if (!d.head) {
    d.chunks = [];
    const effects = setDiffDeco.of(Decoration.none);
    if (d.id === active && d.state) view.dispatch({effects}); else if (d.state) d.state = d.state.update({effects}).state;
    post("diffStats", {tab: d.id, added: 0, changed: 0, deleted: 0, none: true});
    return;
  }
  computeDiff(d);
}

// ---------------------------------------------------------------- showing a tab

function stash() {
  const d = docs.get(active);
  if (d && d.kind === "changes" && d.ch && host.changes.style.display !== "none") {
    d.ch.scroll = host.chBody.scrollTop;
    d.ch.treeScroll = host.chTree.scrollTop;
  }
  if (!d || !d.state) return;
  d.state = view.state;
  // A hidden editor reports 0: keep where it was instead.
  if (host.cm.style.display !== "none") d.scroll = view.scrollDOM.scrollTop;
  if (d.mode === "preview" && host.preview.style.display !== "none") d.previewScroll = host.preview.scrollTop;
}

function display(which) {
  // A view that was hidden measured nothing; line heights and the gutter are only right once it
  // measures again while visible.
  if (which === "cm" && host.cm.style.display === "none") requestAnimationFrame(() => view.requestMeasure());
  host.cm.style.display = which === "cm" ? "" : "none";
  host.preview.style.display = which === "preview" ? "" : "none";
  host.info.style.display = which === "info" ? "" : "none";
  host.changes.style.display = which === "changes" ? "" : "none";
}

function showDoc(d) {
  if (d.info) { renderInfo(d.info); display("info"); return; }
  if (d.kind === "changes") {
    if (!d.ch) { renderInfo({kind: "loading", title: words.loading}); display("info"); return; }
    renderChanges(d);
    display("changes");
    host.chBody.scrollTop = d.ch.scroll || 0;
    host.chTree.scrollTop = d.ch.treeScroll || 0;
    return;
  }
  if (!d.state) { renderInfo({kind: "loading", title: words.loading}); display("info"); return; }
  view.setState(d.state);
  if (d.mode === "preview") {
    display("preview");
    renderPreview(d);
    host.preview.scrollTop = d.previewScroll || 0;
  } else {
    display("cm");
    restoreScroll(d.scroll || 0);
  }
  reportCursor(d, view.state);
}

// Scroll positions are put back a frame later, once the view has measured. A `goto` in between wins:
// it bumps the token, and the late restore would otherwise throw its scroll away.
let scrollToken = 0;
function restoreScroll(top) {
  const token = ++scrollToken;
  requestAnimationFrame(() => { if (token === scrollToken) view.scrollDOM.scrollTop = top; });
}

// Clean tabs out of sight give their editor state back when there are many of them, or they are
// large; switching back reads the file again. Dirty tabs keep everything.
function evict() {
  const idle = [...docs.values()].filter(d => d.id !== active && d.state && !d.dirty && !d.saving && !d.loading && d.kind === "text");
  const size = d => d.state.doc.length + (d.head ? d.head.length : 0);
  let total = idle.reduce((n, d) => n + size(d), 0);
  idle.sort((a, b) => (a.seen || 0) - (b.seen || 0));
  while (idle.length > 8 || (idle.length && total > 50_000_000)) {
    const d = idle.shift();
    total -= size(d);
    d.state = null; d.savedDoc = null; d.head = null; d.chunks = null; d.preview = null;
  }
}

// ---------------------------------------------------------------- Markdown preview

const mdit = new MarkdownIt({html: false, linkify: false, typographer: false});
const escapeHTML = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function highlightCode(code, info) {
  const lang = languageFor(info);
  if (!lang || code.length > 200_000) return escapeHTML(code);
  let out = "", pos = 0;
  try {
    const tree = lang.parser.parse(code);
    highlightTree(tree, highlight, (from, to, cls) => {
      if (from > pos) out += escapeHTML(code.slice(pos, from));
      out += `<span class="${cls}">${escapeHTML(code.slice(from, to))}</span>`;
      pos = to;
    });
  } catch (e) { return escapeHTML(code); }
  return out + escapeHTML(code.slice(pos));
}

// GitHub's anchors: lower case, punctuation dropped except "-" and "_", spaces to "-". The element id
// carries a prefix so a heading called "info" or "toc" cannot take the id of the page's own parts.
const HEADING = "h-";
function slug(text, seen) {
  let s = text.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-") || "section";
  if (seen.has(s)) { let n = 1; while (seen.has(`${s}-${n}`)) n++; s = `${s}-${n}`; }
  seen.add(s);
  return s;
}

/** A link or image path in a document: relative to the document, or — starting with "/" — to the
 *  project, as GitHub reads it. */
function resolvePath(dir, href, root) {
  let p = href;
  try { p = decodeURIComponent(href); } catch (e) {}
  const parts = (p.startsWith("/") ? (root || "") + p : dir + "/" + p).split("/");
  const out = [];
  for (const s of parts) { if (!s || s === ".") continue; if (s === "..") out.pop(); else out.push(s); }
  return "/" + out.join("/");
}

mdit.core.ruler.push("fv_lines", state => {
  for (const tok of state.tokens) {
    if (tok.map && tok.nesting !== -1 && tok.block) {
      tok.attrSet("data-l0", String(tok.map[0] + 1));
      tok.attrSet("data-l1", String(tok.map[1]));
    }
  }
});
mdit.renderer.rules.fence = (tokens, i) => {
  const tok = tokens[i];
  const [l0, l1] = tok.map ? [tok.map[0] + 1, tok.map[1]] : [0, 0];
  return `<pre data-l0="${l0}" data-l1="${l1}"><code>${highlightCode(tok.content, tok.info)}</code></pre>\n`;
};
mdit.renderer.rules.code_block = mdit.renderer.rules.fence;
const defaultLinkOpen = mdit.renderer.rules.link_open || ((tokens, i, opts, env, self) => self.renderToken(tokens, i, opts));
mdit.renderer.rules.link_open = (tokens, i, opts, env, self) => {
  const tok = tokens[i];
  tok.attrSet("data-href", tok.attrGet("href") || "");
  tok.attrSet("href", "#");
  return defaultLinkOpen(tokens, i, opts, env, self);
};
mdit.renderer.rules.image = (tokens, i, opts, env) => {
  const tok = tokens[i];
  let src = tok.attrGet("src") || "";
  if (!/^(https?:|data:)/.test(src)) src = rawURL(resolvePath(env.dir, src.split(/[?#]/)[0], env.root));
  const alt = escapeHTML(tok.content || "");
  return `<img src="${escapeHTML(src)}" alt="${alt}">`;
};
mdit.renderer.rules.heading_open = (tokens, i, opts, env, self) => {
  const tok = tokens[i];
  const text = tokens[i + 1] ? tokens[i + 1].content : "";
  const id = HEADING + slug(text, env.seen);
  tok.attrSet("id", id);
  if (tok.tag <= "h4") env.toc.push({level: Number(tok.tag[1]), text, id, line: tok.map ? tok.map[0] + 1 : 0});
  return self.renderToken(tokens, i, opts);
};

function renderPreviewSoon(d, wait = 300) {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(() => { if (d.id === active && d.mode === "preview") renderPreview(d); }, wait);
}

/** The document rendered, for this exact text. */
function rendered(d) {
  const doc = d.id === active ? view.state.doc : d.state.doc;
  if (!d.preview || d.preview.doc !== doc) {
    const env = {dir: d.meta.path.slice(0, d.meta.path.lastIndexOf("/")) || "/", root: d.meta.root || "", toc: [], seen: new Set()};
    const html = mdit.render(doc.toString(), env);
    d.preview = {doc, html, toc: env.toc};
  }
  return d.preview;
}

function renderPreview(d) {
  rendered(d);
  const keep = host.preview.scrollTop;
  host.article.innerHTML = d.preview.html || `<p class="empty">${words.noPreview}</p>`;
  host.toc.innerHTML = d.preview.toc.length > 1
    ? `<div class="toch">${words.outline}</div>` + d.preview.toc.map(h =>
        `<a class="l${h.level}" data-id="${escapeHTML(h.id)}">${escapeHTML(h.text)}</a>`).join("")
    : "";
  host.toc.style.display = d.preview.toc.length > 1 ? "" : "none";
  host.preview.scrollTop = keep;
  tintPreview(d);
  spy();
}

function tintPreview(d) {
  const changed = [], flashed = [];
  if (d.chunks && d.head) {
    const doc = d.id === active ? view.state.doc : d.state.doc;
    for (const c of d.chunks) {
      if (c.fromB === c.toB) continue;
      changed.push([doc.lineAt(c.fromB).number, doc.lineAt(Math.min(c.endB, doc.length)).number]);
    }
  }
  if (d.flashLines) flashed.push(...d.flashLines);
  for (const el of host.article.querySelectorAll("[data-l0]")) {
    const a = +el.dataset.l0, z = +el.dataset.l1;
    if (el.querySelector("[data-l0]") && el.tagName !== "PRE") continue;   // tint the innermost block
    if (changed.some(([x, y]) => x <= z && y >= a)) el.classList.add("fv-changed");
    if (flashed.some(n => n >= a && n <= z)) el.classList.add("fv-flash");
  }
}

function spy() {
  const links = host.toc.querySelectorAll("a");
  if (!links.length) return;
  const top = host.preview.getBoundingClientRect().top;
  let current = null;
  for (const h of host.article.querySelectorAll("h1[id],h2[id],h3[id],h4[id]")) {
    if (h.getBoundingClientRect().top - top <= 16) current = h.id; else break;
  }
  if (!current) current = links[0].dataset.id;
  for (const a of links) a.classList.toggle("on", a.dataset.id === current);
}

// ---------------------------------------------------------------- info panels and images

function renderInfo(info) {
  host.info.innerHTML = "";
  const box = document.createElement("div");
  if (info.kind === "image") {
    box.className = "imgview fit";
    const img = document.createElement("img");
    img.src = info.url;
    const cap = document.createElement("div");
    cap.className = "imgmeta";
    cap.textContent = info.detail || "";
    img.onload = () => { cap.textContent = `${img.naturalWidth} × ${img.naturalHeight}` + (info.detail ? ` · ${info.detail}` : ""); };
    img.title = words.imageHint;
    img.onclick = () => box.classList.toggle("fit");
    box.append(img, cap);
  } else {
    box.className = "infocard " + (info.kind || "");
    const h = document.createElement("h3");
    h.textContent = info.title || "";
    const p = document.createElement("p");
    p.textContent = info.detail || "";
    box.append(h, p);
    if (info.actions && info.actions.length) {
      const row = document.createElement("div");
      row.className = "actions";
      for (const a of info.actions) {
        const b = document.createElement("button");
        b.textContent = a.label;
        b.onclick = () => post("action", {tab: active, id: a.id});
        row.append(b);
      }
      box.append(row);
    }
  }
  host.info.append(box);
}

// ---------------------------------------------------------------- saving

// One save per tab at a time. ⌘S pressed again while the first is on its way saves again once it is
// back, with the text as it is then — two saves in flight could land in either order.
function save(id) {
  const d = docs.get(id);
  if (!d || !d.state || d.meta.readOnly) return Promise.resolve();
  if (d.saving) { d.saveAgain = true; return d.saving; }
  d.saving = (async () => {
    try {
      do {
        d.saveAgain = false;
        if (!d.dirty || !d.state || d.meta.readOnly) break;
        const doc = (id === active ? view.state : d.state).doc;
        const reply = await post("save", {tab: id, text: doc.toString()});
        if (!(reply && reply.ok)) break;
        markSaved(d, doc);
      } while (d.saveAgain);
    } finally { d.saving = null; }
  })();
  return d.saving;
}

function markSaved(d, doc) {
  d.savedDoc = doc;
  const current = d.id === active ? view.state.doc : d.state.doc;
  setDirty(d, !(current === doc || (current.length === doc.length && current.eq(doc))));
}

// ---------------------------------------------------------------- compare and merge

let merge = null, mergeTab = null;
async function compare(id) {
  const d = docs.get(id);
  if (!d || !d.state) return;
  const r = await bridge.fetchText(appURL("disk/" + encodeURIComponent(id)));
  if (!r.ok || active !== id) return;
  // The version on the left is what the merged result replaces: saved against it, not over whatever
  // is there by the time Save is pressed.
  const base = r.headers["x-fv-version"] || "";
  d.state = view.state;
  closeCompare();
  mergeTab = id;
  host.compare.style.display = "";
  host.compareText.textContent = words.compareTitle;
  host.compareSave.textContent = words.saveMerged;
  host.compareCancel.textContent = words.cancel;
  const support = d.meta.length > 20_000_000 || d.meta.longLine ? null : supportFor(d.meta.lang);
  const ext = [lineNumbers(), syntaxHighlighting(highlight), theme, support || [], EditorState.phrases.of(words.phrases)];
  const saveMerged = async () => {
    if (!merge || mergeTab !== id) return;
    const text = merge.b.state.doc.toString();
    const reply = await post("saveMerged", {tab: id, text, base});
    if (reply && reply.ok) replaceText(d, text, true);
    // A conflict means the disk moved again: the left side is out of date, and Swift's banner says so.
    if (reply && (reply.ok || reply.conflict)) closeCompare();
  };
  merge = new MergeView({
    a: {doc: r.text, extensions: [...ext, EditorState.readOnly.of(true)]},
    b: {doc: d.state.doc.toString(), extensions: [...ext, history(), keymap.of([
      {key: "Mod-s", run: () => { saveMerged(); return true; }, preventDefault: true},
      {key: "Escape", run: () => { closeCompare(); return true; }},
      ...defaultKeymap, ...historyKeymap,
    ])]},
    parent: host.compareBody,
    revertControls: "a-to-b",
    highlightChanges: true,
    gutter: true,
  });
  host.compareSave.onclick = saveMerged;
  host.compareCancel.onclick = closeCompare;
  merge.b.focus();
}

function closeCompare() {
  if (merge) { merge.destroy(); merge = null; }
  if (host.compareSave) host.compareSave.style.display = "";
  mergeTab = null;
  host.compare.style.display = "none";
  host.compareBody.innerHTML = "";
}

/** Replace a tab's whole text: the version on disk after a conflict, or a merged result. */
function replaceText(d, text, clean) {
  if (d.id === active) d.state = view.state;
  const tr = d.state.update({changes: {from: 0, to: d.state.doc.length, insert: text},
                             annotations: [Transaction.userEvent.of("fv.replace"), ...bigReplace(d.state.doc.length + text.length)]});
  d.state = tr.state;
  if (d.id === active) view.setState(d.state);
  if (clean) { d.savedDoc = d.state.doc; setDirty(d, false); }
  else setDirty(d, true);
  d.preview = null;
  scheduleDiff(d);
  if (d.id === active) showDoc(d);
}

// ---------------------------------------------------------------- reloading from disk

/** The file changed on disk and the tab has no unsaved edits: bring the new text in as one undoable
 *  edit, keep the view where it was, and light up the lines that changed.
 *
 *  Read through `disk/`, which does not move the version Swift saves against; `applied` does, once
 *  the text is in. Anything typed while the read was on its way stops the reload — the edits stay, and
 *  Swift shows its banner — rather than being replaced, or kept on top of a version never shown. */
async function reload(id) {
  const d = docs.get(id);
  if (!d) return false;
  if (!d.state) {
    if (id !== active) return false;           // read when it is shown
    d.info = null;
    const ok = await load(d);
    if (active === id) { showDoc(d); if (ok) loadHead(d); }
    return ok;
  }
  if (d.dirty) { post("reloadSkipped", {tab: id}); return false; }
  if (id === active) d.state = view.state;
  const before = d.state.doc;
  const r = await bridge.fetchText(appURL("disk/" + encodeURIComponent(id)));
  if (docs.get(id) !== d || !d.state) return false;
  if (id === active) d.state = view.state;
  if (!r.ok) {
    // No longer text (it became binary): nothing here can show it. Gone: Swift's banner says so.
    if (r.status === 415) { d.info = infoFrom(r); if (id === active) showDoc(d); }
    return false;
  }
  if (d.dirty || d.state.doc !== before) { post("reloadSkipped", {tab: id}); return false; }
  const wasInfo = !!d.info;
  d.info = null;
  readOnlyFrom(d, r);
  const old = before.toString(), text = r.text;
  if (old === text) { d.savedDoc = d.state.doc; setDirty(d, false); applied(d, r); if (wasInfo && id === active) showDoc(d); return true; }
  let changes, flash = [];
  const whole = old.length + text.length > 4_000_000;
  if (!whole) {
    changes = textDiff(old, text, {scanLimit: 20000, timeout: 150}).map(c => ({from: c.fromA, to: c.toA, insert: text.slice(c.fromB, c.toB)}));
  } else {
    changes = [{from: 0, to: old.length, insert: text}];
  }
  const keep = id === active && host.cm.style.display !== "none" ? view.scrollDOM.scrollTop : d.scroll;
  const tr = d.state.update({changes, annotations: [Transaction.userEvent.of("fv.reload"), ...bigReplace(whole ? Infinity : 0)]});
  const doc = tr.state.doc;
  // Which lines to light up comes from a line-aligned diff: the character diff that built the
  // transaction can start an insertion after a line's indentation and so spill into the next line.
  if (!whole) {
    for (const c of Chunk.build(d.state.doc, doc, {scanLimit: 20000, timeout: 100})) {
      if (c.fromB < c.toB) flash.push([c.fromB, Math.min(c.endB, doc.length)]);
    }
  }
  let state = tr.state;
  if (flash.length) {
    state = state.update({effects: setFlash.of(lineDecos(doc, flash, flashLine))}).state;
    d.flashLines = flash.map(([a]) => doc.lineAt(a).number);
    clearTimeout(d.flashTimer);
    d.flashTimer = setTimeout(() => {
      d.flashLines = null;
      const effects = setFlash.of(Decoration.none);
      if (d.id === active && d.state) view.dispatch({effects}); else if (d.state) d.state = d.state.update({effects}).state;
    }, 6500);
  }
  d.state = state;
  d.savedDoc = d.state.doc;
  d.meta.length = text.length;
  d.tier = tier(text.length);
  d.preview = null;
  if (id === active) {
    if (wasInfo) showDoc(d);
    else {
      view.setState(d.state);
      if (d.mode === "preview") renderPreview(d); else restoreScroll(keep);
    }
    reportCursor(d, view.state);         // setState fires no update: the status bar's line count would go stale
  } else {
    d.scroll = keep;
  }
  setDirty(d, false);
  applied(d, r);
  scheduleDiff(d);
  return true;
}

/** A whole-text replacement of a large document is not kept for undo: the history would hold a
 *  second full copy of the old text for as long as the tab is open. */
function bigReplace(chars) {
  return chars > 4_000_000 ? [Transaction.addToHistory.of(false)] : [];
}

/** Jump to a heading by its anchor (`#section`, from a link in another document). */
function anchor(d, name) {
  if (!name || !d.state) return false;
  let key = name;
  try { key = decodeURIComponent(name); } catch (e) {}
  if (d.mode === "preview") {
    const el = document.getElementById(HEADING + key) || document.getElementById(HEADING + key.toLowerCase());
    if (el) { el.scrollIntoView({block: "start"}); return true; }
    return false;
  }
  const h = rendered(d).toc.find(h => h.id === HEADING + key || h.id === HEADING + key.toLowerCase());
  return h && h.line ? api.goto(d.id, h.line) : false;
}

// ---------------------------------------------------------------- changes: a commit, the working tree

// What unfolds by itself when a tab opens: files in order until this many changed lines, or this
// many files. The rest unfold on a click. A file's diff draws at most MAX_ROWS lines.
const DIFF_BUDGET = 1500, DIFF_FILES = 15, MAX_ROWS = 3000;

async function loadChanges(d) {
  const r = await bridge.fetchText(appURL("changes/" + encodeURIComponent(d.id)));
  if (!r.ok) { d.info = infoFrom(r); return false; }
  let data;
  try { data = JSON.parse(r.text); } catch (e) { d.info = {kind: "error", title: words.failed}; return false; }
  d.info = null;
  const before = d.ch;
  d.ch = {data, open: new Set(), patches: new Map(), scroll: before ? before.scroll : 0,
          // The file tree's own state, kept across a refresh: folders folded shut, the filter, the file last picked.
          closed: before ? before.closed : new Set(), filter: before ? before.filter : "", picked: before ? before.picked : null,
          treeScroll: before ? before.treeScroll : 0};
  if (before) {
    // A refresh keeps what was unfolded, by path; the diffs themselves are read again.
    for (const f of data.files) if (before.open.has(f.path)) d.ch.open.add(f.path);
  } else if (data.focus >= 0) {
    // Opened for one file (its history): that file alone. Unfolding the ones above it too would
    // push it down the page as their diffs arrive, out from under the scroll that found it.
  } else {
    let lines = 0;
    for (const f of data.files) {
      if (d.ch.open.size >= DIFF_FILES) break;
      if (f.dir || f.binary) continue;
      const n = (f.add || 0) + (f.del || 0);
      if (d.ch.open.size > 0 && lines + n > DIFF_BUDGET) continue;
      lines += n;
      d.ch.open.add(f.path);
    }
  }
  if (data.focus >= 0) d.ch.open.add(data.files[data.focus].path);
  return true;
}

function renderChanges(d) {
  const data = d.ch.data;
  let h = `<div class="chwrap">${changesHeader(d)}<div class="chlist">`;
  for (const f of data.files) h += fileBlock(d, f);
  if (!data.files.length) h += `<div class="chnote">${words.noFiles}</div>`;
  if (data.more > 0) h += `<div class="chmore">${words.moreFiles.replace("$", data.more)}</div>`;
  host.chBody.innerHTML = h + "</div></div>";
  renderTree(d);
  for (const f of data.files) if (d.ch.open.has(f.path) && !d.ch.patches.has(f.path)) loadPatch(d, f);
}

// ---------------------------------------------------------------- changes: the file tree beside them

/* The changed files as folders, on the left, the way a pull request lists them: a filter on top,
   folders first, a chain of single folders as one row ("Sources/FleetView/Files"), each file
   marked added, changed, removed or renamed. A click unfolds the file's diff and brings it into
   view. One file has nothing to find, so it gets no tree. */
function renderTree(d) {
  const files = d.ch.data.files;
  host.chTree.classList.toggle("none", files.length < 2);
  if (files.length < 2) { host.chTree.innerHTML = ""; return; }
  host.chTree.innerHTML = `<div class="ctf"><input type="search" spellcheck="false" placeholder="${words.filterFiles}"></div><div class="ctl"></div>`;
  const input = host.chTree.querySelector("input");
  input.value = d.ch.filter || "";
  // Typing redraws the list alone, so the field keeps its focus and caret.
  input.addEventListener("input", () => { d.ch.filter = input.value; renderTreeList(d); });
  renderTreeList(d);
}

function treeOf(files) {
  const root = {dirs: new Map(), files: []};
  for (const f of files) {
    const parts = f.path.split("/");
    let node = root;
    for (const p of parts.slice(0, -1)) {
      if (!node.dirs.has(p)) node.dirs.set(p, {dirs: new Map(), files: []});
      node = node.dirs.get(p);
    }
    node.files.push(f);
  }
  return root;
}

function renderTreeList(d) {
  const q = (d.ch.filter || "").trim().toLowerCase();
  const files = q ? d.ch.data.files.filter(f => f.path.toLowerCase().includes(q)) : d.ch.data.files;
  let h = "";
  const walk = (node, prefix, depth) => {
    for (const name of [...node.dirs.keys()].sort((a, b) => a.localeCompare(b))) {
      let label = name, path = prefix + name, sub = node.dirs.get(name);
      // A folder holding one folder and nothing else is one row, as GitHub draws it.
      while (sub.files.length === 0 && sub.dirs.size === 1) {
        const [only, next] = [...sub.dirs.entries()][0];
        label += "/" + only; path += "/" + only; sub = next;
      }
      // A filter opens everything it matched in; folding is for browsing.
      const shut = !q && d.ch.closed.has(path);
      h += `<div class="ctn dir${shut ? " shut" : ""}" data-act="tdir" data-path="${escapeHTML(path)}" style="--depth:${depth}">`
         + `<span class="chev">›</span>${ICON.folder}<span class="nm">${escapeHTML(label)}</span></div>`;
      if (!shut) walk(sub, path + "/", depth + 1);
    }
    for (const f of [...node.files].sort((a, b) => a.path.localeCompare(b.path))) {
      const st = f.status === "?" ? "U" : f.status;
      const name = f.path.split("/").pop();
      h += `<div class="ctn file s${st}${d.ch.picked === f.path ? " on" : ""}" data-act="tfile" data-i="${f.i}" style="--depth:${depth}"`
         + ` title="${escapeHTML(f.path)}">${fileIcon(st)}<span class="nm">${escapeHTML(name)}</span></div>`;
    }
  };
  walk(treeOf(files), "", 0);
  if (!files.length) h = `<div class="ctmore">${words.noMatch}</div>`;
  else if (!q && d.ch.data.more > 0) h += `<div class="ctmore">${words.moreFiles.replace("$", d.ch.data.more)}</div>`;
  host.chTree.querySelector(".ctl").innerHTML = h;
}

const ICON = {
  folder: `<svg class="ic" viewBox="0 0 16 16"><path d="M1.75 3h4.1l1.5 1.5h6.9c.41 0 .75.34.75.75v7.5c0 .41-.34.75-.75.75H1.75A.75.75 0 0 1 1 12.75v-9C1 3.34 1.34 3 1.75 3Z" fill="currentColor" opacity=".55"/></svg>`,
};

/* A page with what happened to it on it: + added, − removed, ± changed, → renamed. */
function fileIcon(st) {
  const mark = st === "A" || st === "U" ? `<path d="M8 6.5v5M5.5 9h5"/>`
             : st === "D" ? `<path d="M5.5 9h5"/>`
             : st === "R" || st === "C" ? `<path d="M5.5 9h5M8.5 7l2 2-2 2"/>`
             : `<path d="M8 5.5v4M6 7.5h4M6 11h4"/>`;
  return `<svg class="ic" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">`
       + `<path d="M3.5 1.75h6l3 3v9.5h-9z"/>${mark}</svg>`;
}

/* Nothing when no file was counted: a list read without counts (a commit the size of a whole tree)
   would otherwise claim +0 −0. */
function totals(files) {
  let a = 0, x = 0, counted = false;
  for (const f of files) { if (f.add != null) counted = true; a += f.add || 0; x += f.del || 0; }
  return counted ? `<span class="a">+${a}</span> <span class="d">−${x}</span>` : "";
}

function changesHeader(d) {
  const data = d.ch.data, c = data.commit;
  // A commit's own counts (git's shortstat) hold when its file list was cut short or read uncounted.
  const n = c && c.files != null ? c.files : data.files.length + (data.more || 0);
  const t = c && c.added != null ? `<span class="a">+${c.added}</span> <span class="d">−${c.deleted || 0}</span>` : totals(data.files);
  const count = `${n} ${words.files}` + (t ? ` · ${t}` : "");
  if (c) {
    const lines = c.message.split("\n");
    const subject = lines.shift(), body = lines.join("\n").trim();
    const when = new Date(c.date * 1000).toLocaleString(words === WORDS.zh ? "zh-CN" : undefined,
      {year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"});
    const parents = c.parents.length
      ? `${words.parent} ` + c.parents.map(p => `<a data-act="commit" data-sha="${p}">${p.slice(0, 7)}</a>`).join(" ")
      : words.rootCommit;
    const agent = c.agent ? `<span class="agent">${c.agent === "claude" ? "Claude" : "Codex"}</span>` : "";
    return `<div class="chhead"><div class="chsub">${escapeHTML(subject)}</div>${body ? `<pre class="chbody">${escapeHTML(body)}</pre>` : ""}
      <div class="chmeta"><span class="sha">${c.short}</span><span>${escapeHTML(c.author)}</span><span>${when}</span>${agent}<span>${parents}</span><span>${count}</span></div>
      <div class="chbtns"><button data-act="copy" data-text="${c.sha}">${words.copySha}</button><button data-act="cmpwt" data-sha="${c.sha}">${words.cmpWT}</button></div></div>`;
  }
  const sides = data.kind === "worktree" ? `${words.worktree} ${words.against} <span class="sha">${escapeHTML(data.a)}</span>`
                                         : `<span class="sha">${escapeHTML(data.a)}</span> → <span class="sha">${escapeHTML(data.b)}</span>`;
  return `<div class="chhead"><div class="chsub">${escapeHTML(data.title)}</div>
    <div class="chmeta"><span>${sides}</span><span>${count}</span></div>
    ${d.meta.live ? `<div class="chbtns"><button data-act="refresh">${words.refresh}</button></div>` : ""}</div>`;
}

function fileBlock(d, f) {
  const open = d.ch.open.has(f.path);
  const name = f.path.split("/").pop(), dir = f.path.slice(0, f.path.length - name.length);
  const st = f.status === "?" ? "U" : f.status;
  const n = f.add != null ? `<span class="n"><span class="a">+${f.add}</span> <span class="d">−${f.del || 0}</span></span>` : "";
  const side = !f.dir && !f.binary ? `<button data-act="side">${words.sideBySide}</button>` : "";
  const openBtn = f.rel != null && f.status !== "D" ? `<button data-act="openfile">${f.dir ? words.showInTree : words.open}</button>` : "";
  return `<div class="chf${open ? " open" : ""}" data-i="${f.i}"><div class="chfh" data-act="toggle"><span class="chev">›</span>`
    // The path ellipsizes at its start (the container is right-to-left) but reads left to right
    // inside: without the isolate, bidi moves a leading "10_23_" to the far end.
    + `<span class="st s${st}">${st}</span><span class="fp"><bdi dir="ltr">${escapeHTML(dir)}<b>${escapeHTML(name)}</b></bdi></span>`
    + (f.old ? `<span class="old">← ${escapeHTML(f.old)}</span>` : "")
    + `<span class="sp"></span>${n}${side}${openBtn}</div>`
    + (open ? `<div class="chfb">${fileBody(d, f)}</div>` : "") + "</div>";
}

function fileBody(d, f) {
  if (f.dir) return `<div class="chnote">${words.untrackedDir}</div>`;
  if (f.binary) return `<div class="chnote">${words.binary}</div>`;
  const p = d.ch.patches.get(f.path);
  if (!p) return `<div class="chnote">${words.loading}</div>`;
  if (p.error) return `<div class="chnote">${words.failed}</div>`;
  if (p.binary) return `<div class="chnote">${words.binary}</div>`;
  if (!p.rows.length) return `<div class="chnote">${words.noChange}</div>`;
  const editable = f.rel != null && f.status !== "D";
  let h = p.truncated ? `<div class="chnote">${words.truncated}</div>` : "";
  const shown = p.rows.length > MAX_ROWS ? p.rows.slice(0, MAX_ROWS) : p.rows;
  for (const r of shown) {
    if (r.t === "h") { h += `<div class="dh">⋯ ${escapeHTML(r.text)}</div>`; continue; }
    const cls = (r.t === "+" ? "add" : r.t === "-" ? "del" : "") + (editable ? " click" : "");
    h += `<div class="dr ${cls}" data-n="${r.n ?? ""}"><span class="ln">${r.o ?? ""}</span><span class="ln">${r.n ?? ""}</span>`
       + `<span class="tx">${r.html ?? escapeHTML(r.text)}</span></div>`;
  }
  if (p.rows.length > MAX_ROWS) {
    h += `<div class="chnote">${words.tooLong.replace("$", p.rows.length - MAX_ROWS)}<button data-act="side">${words.seeAll}</button></div>`;
  }
  return h;
}

async function loadPatch(d, f) {
  d.ch.patches.set(f.path, null);
  const r = await bridge.fetchText(appURL(`patch/${encodeURIComponent(d.id)}/${f.i}`));
  if (!d.ch || !d.ch.data.files.includes(f)) return;
  let p;
  if (!r.ok) p = r.status === 415 ? {binary: true, rows: []} : {error: true, rows: []};
  else {
    p = parsePatch(r.text);
    p.truncated = !!r.headers["x-fv-truncated"];
    if (p.rows.length <= MAX_ROWS) highlightRows(p.rows, f.lang);
  }
  d.ch.patches.set(f.path, p);
  if (active === d.id) {
    const el = host.changes.querySelector(`.chf[data-i="${f.i}"] .chfb`);
    if (el) el.innerHTML = fileBody(d, f);
  }
}

/** Hunks of a unified diff as rows: " " context, "+" added, "-" removed, "h" a hunk's start. */
function parsePatch(text) {
  const rows = [];
  let o = 0, n = 0, inHunk = false, binary = false;
  for (const line of text.split("\n")) {
    if (line.startsWith("@@")) {
      const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@ ?(.*)$/.exec(line);
      if (m) { o = +m[1]; n = +m[2]; rows.push({t: "h", text: m[3]}); inHunk = true; }
      continue;
    }
    if (line.startsWith("diff --git ")) { inHunk = false; continue; }
    if (!inHunk) { if (line.startsWith("Binary files")) binary = true; continue; }
    const c = line[0];
    if (c === "+") rows.push({t: "+", n: n++, text: line.slice(1)});
    else if (c === "-") rows.push({t: "-", o: o++, text: line.slice(1)});
    else if (c === " ") rows.push({t: " ", o: o++, n: n++, text: line.slice(1)});
  }
  return {rows, binary};
}

/** Colours for a diff: the new side (context and added lines) parsed as one text, the removed
 *  lines as another, each split back into lines. A hunk's start can still fall inside a comment. */
function highlightRows(rows, lang) {
  const side = list => {
    const out = highlightLines(list.map(r => r.text).join("\n"), lang);
    list.forEach((r, i) => { r.html = out[i]; });
  };
  side(rows.filter(r => r.t === "+" || r.t === " "));
  side(rows.filter(r => r.t === "-"));
}

function highlightLines(code, lang) {
  const lines = code.split("\n");
  const language = languageFor(lang);
  if (!language || code.length > 300_000) return lines.map(escapeHTML);
  const out = lines.map(() => "");
  const starts = [];
  let p = 0;
  for (const l of lines) { starts.push(p); p += l.length + 1; }
  let li = 0, pos = 0;
  const emit = (from, to, cls) => {
    while (from < to) {
      while (li + 1 < starts.length && starts[li + 1] <= from) li++;
      const lineEnd = starts[li] + lines[li].length;
      const end = Math.min(to, lineEnd);
      if (end > from) {
        const t = escapeHTML(code.slice(from, end));
        out[li] += cls ? `<span class="${cls}">${t}</span>` : t;
      }
      from = end < lineEnd ? end : lineEnd + 1;
    }
  };
  try {
    highlightTree(language.parser.parse(code), highlight, (from, to, cls) => {
      if (from > pos) emit(pos, from, "");
      emit(from, to, cls);
      pos = to;
    });
  } catch (e) { return lines.map(escapeHTML); }
  if (pos < code.length) emit(pos, code.length, "");
  return out;
}

function changeFileAt(d, el) {
  const box = el.closest(".chf");
  return box ? d.ch.data.files[+box.dataset.i] : null;
}

function toggleFile(d, f) {
  if (d.ch.open.has(f.path)) d.ch.open.delete(f.path); else d.ch.open.add(f.path);
  const box = host.changes.querySelector(`.chf[data-i="${f.i}"]`);
  if (box) box.outerHTML = fileBlock(d, f);
  if (d.ch.open.has(f.path) && !d.ch.patches.has(f.path)) loadPatch(d, f);
}

/** Unfold a file and bring it into view. */
function focusFile(d, path) {
  if (!d.ch) return false;
  const f = d.ch.data.files.find(f => f.rel === path || f.path === path || f.old === path);
  if (!f) return false;
  if (!d.ch.open.has(f.path)) toggleFile(d, f);
  const box = host.changes.querySelector(`.chf[data-i="${f.i}"]`);
  if (box) box.scrollIntoView({block: "start"});
  return true;
}

/** One file's two versions side by side, both read-only, in the compare overlay. */
async function sideBySide(d, f) {
  const [a, b] = await Promise.all(["a", "b"].map(s => bridge.fetchText(appURL(`blob/${encodeURIComponent(d.id)}/${f.i}/${s}`))));
  if (!a.ok || !b.ok || active !== d.id) return;
  closeCompare();
  mergeTab = d.id;
  const data = d.ch.data;
  host.compare.style.display = "";
  host.compareText.textContent = `${f.path} · ${data.a || words.nothing} ↔ ${data.b || words.worktree}`;
  host.compareSave.style.display = "none";
  host.compareCancel.textContent = words.close;
  host.compareCancel.onclick = closeCompare;
  const support = supportFor(f.lang);
  const ext = [lineNumbers(), syntaxHighlighting(highlight), theme, support || [], EditorState.readOnly.of(true),
               EditorState.phrases.of(words.phrases), keymap.of([{key: "Escape", run: () => { closeCompare(); return true; }}])];
  merge = new MergeView({
    a: {doc: a.text, extensions: ext}, b: {doc: b.text, extensions: ext}, parent: host.compareBody,
    highlightChanges: true, gutter: true, collapseUnchanged: {margin: 4, minSize: 10},
  });
}

function onChangesClick(e) {
  const d = docs.get(active);
  if (!d || d.kind !== "changes" || !d.ch) return;
  const act = e.target.closest("[data-act]");
  const f = changeFileAt(d, e.target);
  if (act) {
    switch (act.dataset.act) {
      case "toggle": if (f && !e.target.closest("button")) toggleFile(d, f); return;
      case "side": if (f) sideBySide(d, f); return;
      case "openfile": if (f && f.rel != null) post("openFile", {tab: d.id, path: f.rel}); return;
      case "copy": post("copy", {tab: d.id, text: act.dataset.text}); return;
      case "cmpwt": post("compareWorktree", {tab: d.id, sha: act.dataset.sha}); return;
      case "commit": post("openCommit", {tab: d.id, sha: act.dataset.sha}); return;
      case "refresh": refreshChanges(d); return;
      case "tdir": {
        const p = act.dataset.path;
        if (d.ch.closed.has(p)) d.ch.closed.delete(p); else d.ch.closed.add(p);
        renderTreeList(d);
        return;
      }
      case "tfile": {
        const file = d.ch.data.files[+act.dataset.i];
        if (!file) return;
        d.ch.picked = file.path;
        for (const el of host.chTree.querySelectorAll(".ctn.on")) el.classList.remove("on");
        act.classList.add("on");
        focusFile(d, file.path);
        return;
      }
    }
  }
  // A line of a diff: open the file there. Not when the click ended a text selection.
  const row = e.target.closest(".dr.click");
  if (row && f && f.rel != null && window.getSelection().isCollapsed) {
    let n = +row.dataset.n;
    for (let r = row; !n && r; r = r.nextElementSibling) n = +(r.dataset && r.dataset.n);
    post("openFile", {tab: d.id, path: f.rel, line: n || 1});
  }
}

async function refreshChanges(d) {
  stash();
  if (await loadChanges(d) && active === d.id) showDoc(d);
}

// ---------------------------------------------------------------- the API Swift calls

const api = {
  /** First call after the page loads: theme, language, font size. */
  init(opts) {
    words = WORDS[opts.lang] || WORDS.en;
    if (opts.lang === "zh") words.phrases = WORDS.zh.phrases;
    setTheme(opts.colors || {}, opts.fontSize);
    // Tabs opened before this (none, normally) keep the phrases they were made with.
    if (view) view.dispatch({effects: phraseC.reconfigure(EditorState.phrases.of(words.phrases))});
    return true;
  },
  setTheme(colors, fontSize) { setTheme(colors, fontSize); return true; },

  /** A tab: {path, root, lang, kind: text|image|info, wrap, mode, info, line, find, anchor}. */
  async open(id, meta) {
    stash();
    if (mergeTab && mergeTab !== id) closeCompare();
    let d = docs.get(id);
    if (!d) {
      d = {id, meta: {...meta}, kind: meta.kind || "text", mode: meta.mode || "source", wrap: !!meta.wrap, dirty: false};
      docs.set(id, d);
    }
    active = id;
    d.seen = Date.now();
    if (d.kind === "changes") {
      showDoc(d);
      if (!d.ch && await loadChanges(d) && active === id) {
        showDoc(d);
        if (d.ch.data.focus >= 0) focusFile(d, d.ch.data.files[d.ch.data.focus].path);
      } else if (active === id) showDoc(d);
      return {ok: !d.info};
    }
    if (d.kind !== "text") { d.info = meta.info; showDoc(d); return {ok: true}; }
    if (!d.state && !d.info) {
      showDoc(d);
      const loaded = await load(d);
      if (active !== id) return {ok: loaded};
      showDoc(d);
      if (loaded) loadHead(d);
    } else {
      showDoc(d);
    }
    if (active === id) jump(d, meta);
    evict();
    return {ok: !d.info, readOnly: !!d.meta.readOnly, reason: d.meta.readOnlyReason || ""};
  },
  async show(id) {
    if (!docs.has(id)) return {ok: false};
    stash();
    if (mergeTab && mergeTab !== id) closeCompare();
    active = id;
    const d = docs.get(id);
    d.seen = Date.now();
    if (d.kind === "changes") {
      showDoc(d);
      // The working tree moves while nobody looks: read again on the way back to it.
      if (d.meta.live && d.ch) refreshChanges(d);
      return {ok: true};
    }
    if (d.kind === "text" && !d.state && !d.info) {
      showDoc(d);
      const ok = await load(d);
      if (active !== id) return {ok: true};
      showDoc(d);
      if (ok) loadHead(d);
    } else {
      showDoc(d);
    }
    evict();
    return {ok: true};
  },
  close(id) {
    const d = docs.get(id);
    if (d) { clearTimeout(d.diffTimer); clearTimeout(d.snapTimer); clearTimeout(d.flashTimer); }
    if (mergeTab === id) closeCompare();
    docs.delete(id);
    if (active === id) active = null;
    return true;
  },
  setMode(id, mode) {
    const d = docs.get(id);
    if (!d) return false;
    if (id === active) stash();
    d.mode = mode;
    if (id === active) showDoc(d);
    return true;
  },
  setWrap(id, on) {
    const d = docs.get(id);
    if (!d || !d.state) return false;
    d.wrap = on;
    const effects = wrapC.reconfigure(on ? EditorView.lineWrapping : []);
    if (id === active) view.dispatch({effects}); else d.state = d.state.update({effects}).state;
    return true;
  },
  setReadOnly(id, on) {
    const d = docs.get(id);
    if (!d) return false;
    d.meta.readOnly = on;
    if (!d.state) return true;
    const effects = readOnlyC.reconfigure(EditorState.readOnly.of(on));
    if (id === active) view.dispatch({effects}); else d.state = d.state.update({effects}).state;
    return true;
  },
  goto(id, line) {
    const d = docs.get(id);
    if (!d || id !== active || !d.state) return false;
    if (d.mode === "preview") {
      const all = [...host.article.querySelectorAll("[data-l0]")];
      // The innermost block holding the line, or — for a blank line between blocks — the next one.
      const el = all.filter(e => +e.dataset.l0 <= line && +e.dataset.l1 >= line).pop()
        || all.find(e => +e.dataset.l0 >= line);
      if (el) { el.scrollIntoView({block: "center"}); el.classList.remove("fv-goto"); void el.offsetWidth; el.classList.add("fv-goto"); }
      return true;
    }
    const doc = view.state.doc;
    const l = doc.line(Math.max(1, Math.min(line, doc.lines)));
    scrollToken++;                       // a scroll restore still waiting for its frame must not undo this
    view.dispatch({
      selection: {anchor: l.from},
      effects: [EditorView.scrollIntoView(l.from, {y: "center"}), setFlash.of(lineDecos(doc, [[l.from, l.from]], gotoLineDeco))],
    });
    view.focus();
    return true;
  },
  gotoPrompt() { if (active && docs.get(active).mode !== "preview") gotoLine(view); return true; },
  find(query) {
    const d = docs.get(active);
    if (!d || !d.state) return false;
    if (d.mode === "preview") { stash(); d.mode = "source"; showDoc(d); post("mode", {tab: d.id, mode: "source"}); }
    openSearchPanel(view);
    if (query) view.dispatch({effects: setSearchQuery.of(new SearchQuery({search: query, caseSensitive: false}))});
    return true;
  },
  /** Text of the active or a given tab, for saving from Swift (quit, close). */
  text(id) {
    const d = docs.get(id);
    if (!d || !d.state) return null;
    return (id === active ? view.state.doc : d.state.doc).toString();
  },
  /** Every tab with unsaved edits, and its text. */
  dirtyTexts() {
    if (active && docs.get(active) && docs.get(active).state) docs.get(active).state = view.state;
    return [...docs.values()].filter(d => d.dirty && d.state).map(d => ({tab: d.id, text: d.state.doc.toString()}));
  },
  /** Swift saved this exact text for the tab. Typing since then stays unsaved — against the text
   *  that was saved, so undoing back to it reads as clean. */
  markSaved(id, text) {
    const d = docs.get(id);
    if (!d || !d.state) return false;
    markSaved(d, Text.of(text.split("\n")));
    return true;
  },
  /** Throw the edits away and read the file again. */
  async discard(id) {
    const d = docs.get(id);
    if (!d) return false;
    d.state = null; d.savedDoc = null; d.preview = null;
    setDirty(d, false);
    if (id === active) { showDoc(d); await load(d); showDoc(d); loadHead(d); }
    return true;
  },
  reload,
  /** Recovered text from an earlier session, put in as unsaved edits. */
  async restore(id, text) {
    const d = docs.get(id);
    if (!d) return false;
    if (!d.state && !(await load(d))) return false;
    if (d.meta.readOnly) return false;
    replaceText(d, text, false);
    scheduleSnapshot(d);
    return true;
  },
  /** Use the version on disk after a conflict. */
  async useDisk(id) {
    const d = docs.get(id);
    if (!d) return false;
    const r = await bridge.fetchText(appURL("disk/" + encodeURIComponent(id)));
    if (!r.ok || docs.get(id) !== d) return false;
    if (!d.state) { adopt(d, r); setDirty(d, false); if (id === active) { showDoc(d); loadHead(d); } }
    else { readOnlyFrom(d, r); replaceText(d, r.text, true); }
    applied(d, r);
    return true;
  },
  /** Land on a line, a search, or a heading's anchor: {line, find, anchor}. */
  jump(id, where) {
    const d = docs.get(id);
    if (!d || id !== active) return true;
    if (d.kind === "changes") { if (where && where.file) focusFile(d, where.file); return true; }
    jump(d, where || {});
    return true;
  },
  compare,
  /** HEAD moved: fetch the baseline again. */
  headChanged(id) { const d = docs.get(id); if (d && d.state) loadHead(d); return true; },
  focus() { if (view) view.focus(); return true; },
  /** ⌘S from the window when the editor itself does not have focus. */
  saveActive() { if (active) save(active); return true; },
  stats() {
    return [...docs.values()].map(d => ({tab: d.id, path: d.meta.path, chars: d.state ? d.state.doc.length : 0, dirty: d.dirty}));
  },
};
window.fv = api;

/** Where `open`/`show` was asked to land. Find first: in a rendered document it switches to the
 *  source, and the line has to be found there, not in the rendering it just left. */
function jump(d, where) {
  if (!d.state) return;
  if (where.find) api.find(where.find);
  if (where.line) api.goto(d.id, where.line);
  else if (where.anchor) anchor(d, where.anchor);
}

function setTheme(colors, fontSize) {
  const root = document.documentElement.style;
  for (const [k, v] of Object.entries(colors)) {
    if (k === "scheme") { document.documentElement.style.colorScheme = v; continue; }
    root.setProperty("--" + k, v);
  }
  if (fontSize) root.setProperty("--fs", fontSize + "px");
  if (view) view.requestMeasure();
}

// ---------------------------------------------------------------- page wiring

function boot() {
  host.cm = document.getElementById("cm");
  host.preview = document.getElementById("preview");
  host.article = document.getElementById("article");
  host.toc = document.getElementById("toc");
  host.info = document.getElementById("info");
  host.changes = document.getElementById("changes");
  host.chTree = document.getElementById("chtree");
  host.chBody = document.getElementById("chbody");
  host.compare = document.getElementById("compare");
  host.compareBody = document.getElementById("compareBody");
  host.compareText = document.getElementById("compareText");
  host.compareSave = document.getElementById("compareSave");
  host.compareCancel = document.getElementById("compareCancel");
  // The highlight style's CSS is mounted by a state that uses it: from the start, so a commit's diff
  // or a rendered document shown before any file is coloured too.
  view = new EditorView({parent: host.cm, state: EditorState.create({doc: "", extensions: [syntaxHighlighting(highlight), theme]})});
  display("info");

  host.article.addEventListener("click", e => {
    const a = e.target.closest("a[data-href]");
    if (!a) return;
    e.preventDefault();
    const href = a.dataset.href;
    if (href.startsWith("#")) {
      const d = docs.get(active);
      if (d) anchor(d, href.slice(1));
      return;
    }
    const d = docs.get(active);
    post("link", {tab: active, href, from: d ? d.meta.path : ""});
  });
  host.toc.addEventListener("click", e => {
    const a = e.target.closest("a[data-id]");
    if (!a) return;
    const el = document.getElementById(a.dataset.id);
    if (el) el.scrollIntoView({block: "start"});
  });
  host.preview.addEventListener("scroll", () => requestAnimationFrame(spy), {passive: true});
  host.changes.addEventListener("click", onChangesClick);
  // A window that was covered or minimised gets no animation frames; measure again when it shows.
  document.addEventListener("visibilitychange", () => { if (!document.hidden && view) view.requestMeasure(); });

  // Keys that mean something to the window, when the editor itself does not have focus.
  document.addEventListener("keydown", e => {
    if (e.target.closest && e.target.closest(".cm-editor")) return;
    const mod = e.metaKey || e.ctrlKey;
    const k = e.key.toLowerCase();
    let name = null;
    if (mod && !e.shiftKey && k === "p") name = "quickOpen";
    else if (mod && e.shiftKey && k === "f") name = "searchFiles";
    else if (mod && !e.shiftKey && k === "w") name = "closeTab";
    // ⌥ turns "c" into "ç": the physical key, not the character.
    else if (mod && e.altKey && e.code === "KeyC") name = "copyPath";
    else if (mod && !e.shiftKey && k === "s") { e.preventDefault(); if (active) save(active); return; }
    else if (mod && !e.shiftKey && k === "f") { e.preventDefault(); api.find(""); return; }
    if (name) { e.preventDefault(); post("key", {name}); }
  });
  post("ready");
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();
