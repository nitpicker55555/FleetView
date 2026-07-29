import Foundation

/// The single self-contained HTML page served at `/`. It polls `/state` for live data, renders the
/// same projects/terminals/status the desktop shows, lets you drag a card onto an action zone
/// (done / duplicate / rename / leave / remove), add terminals, and open one full-screen in an
/// iframe (ttyd). A native input bar sends text via tmux `send-keys` so CJK/IME input works where
/// xterm.js falls short. No external assets — everything is inline so it works offline on the LAN.
enum WebDashboardPage {
    // A raw string (#"""…"""#) so the inline JS can use backslashes (regex, "\n") verbatim.
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>FleetView</title>
<style>
  :root{
    --bg:#14171c; --panel:#1c1f25; --card:#25282f; --cardHover:#2e3039;
    --stroke:rgba(255,255,255,.08); --text:#ebedf2; --sub:#99a1b0; --accent:#7a9eff;
    --green:#5cd18c; --teal:#4dadc2; --gray:#8c93a3; --amber:#fab852; --red:#d96b73;
    --claude:#e69459; --codex:#66ccd9;
  }
  *{box-sizing:border-box}
  html,body{margin:0;height:100%}
  body{background:var(--bg);color:var(--text);
    font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent}
  #panel{display:none;position:relative;border-bottom:1px solid var(--stroke);background:var(--bg)}
  #panel.show{display:block}
  #panelframe{width:100%;height:240px;border:0;display:block;background:var(--bg)}
  #panel.min #panelframe{height:0}
  /* Collapsing zeroed the iframe, the panel box collapsed with it, and the sticky header (z-index 5)
     painted over the absolutely-positioned toggle — so "hide" could never be undone. */
  #panel.min{min-height:30px}
  #panel .pcollapse{position:absolute;right:8px;top:6px;z-index:6;background:var(--card);color:var(--sub);
    border:1px solid var(--stroke);border-radius:6px;font-size:11px;padding:2px 8px;cursor:pointer}
  header{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:10px;flex-wrap:wrap;
    padding:12px 16px;background:rgba(28,31,37,.92);backdrop-filter:blur(8px);
    border-bottom:1px solid var(--stroke);padding-top:max(12px,env(safe-area-inset-top))}
  .logo{font-weight:600;font-size:15px}.logo b{color:var(--accent)}
  .muted{color:var(--sub);font-size:13px}
  .pill{font-size:11px;font-weight:600;padding:2px 8px;border-radius:999px}
  .spacer{flex:1}
  .dot{width:9px;height:9px;border-radius:50%;flex:none}
  .refresh{font-size:11px;color:var(--sub)}
  main{padding:16px;max-width:1200px;margin:0 auto;padding-bottom:120px}
  .proj{margin-bottom:26px}
  .projhead{display:flex;align-items:center;gap:8px;margin-bottom:10px}
  .projhead .name{font-size:15px;font-weight:600}
  .projhead .count{font-size:11px;font-weight:600;color:var(--sub);background:var(--card);padding:1px 7px;border-radius:999px}
  .projhead .tok{font-size:11px;font-weight:600;color:var(--accent);background:rgba(122,158,255,.12);padding:1px 7px;border-radius:999px}
  .addbtn{margin-left:auto;font-size:12px;font-weight:600;color:var(--accent);background:rgba(122,158,255,.12);
    border:1px solid rgba(122,158,255,.28);border-radius:7px;padding:5px 10px;cursor:pointer}
  .addbtn:active{transform:scale(.96)}
  .grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(280px,1fr))}
  .card{background:var(--card);border:1px solid var(--stroke);border-radius:12px;padding:13px 14px;
    display:flex;flex-direction:column;gap:9px;transition:transform .1s,background .12s;cursor:pointer;
    position:relative;user-select:none;-webkit-user-select:none}
  /* touch-action is NOT inherited: with it only on .card, a finger landing on the card's text hit
     an `auto` element and the browser scrolled instead. pan-y keeps the list scrollable; a press
     and hold claims the gesture for dragging (see onDown). */
  .card, .card *{touch-action:pan-y}
  .card.armed{transform:scale(1.03);box-shadow:0 10px 26px rgba(0,0,0,.5);border-color:var(--accent)}
  .card:hover{background:var(--cardHover)}
  .card.locked{cursor:default;opacity:.6}
  .card.done{background:#101c13;border-color:rgba(92,209,140,.4)}
  .card.dragging{opacity:.35}
  .cardtop{display:flex;align-items:center;gap:9px}
  .cardtop .name{font-weight:600;font-size:14px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .agent{font-size:9px;font-weight:700;padding:1px 5px;border-radius:999px;text-transform:uppercase}
  .status{font-size:11px;font-weight:600}
  .prompt{font-size:12px;color:var(--sub);display:flex;gap:6px;min-height:32px}
  .prompt .sig{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:700;flex:none}
  .prompt .txt{overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
  .ago{font-size:10px;color:var(--sub);opacity:.75;text-align:right;margin-top:-3px}
  .cluster{border:1px solid rgba(122,158,255,.28);background:rgba(122,158,255,.055);border-radius:14px;padding:12px;margin-bottom:12px}
  .cluster .clabel{font-size:9px;font-weight:700;color:var(--accent);background:rgba(122,158,255,.14);padding:2px 6px;border-radius:999px;margin-right:6px}
  .cluster .chead{display:flex;align-items:center;margin-bottom:10px}
  .cluster .cname{font-weight:600;font-size:14px}
  .banner{background:rgba(250,184,82,.13);border:1px solid rgba(250,184,82,.3);color:var(--amber);padding:10px 12px;border-radius:10px;font-size:12px;margin-bottom:16px}
  .empty{color:var(--sub);text-align:center;padding:60px 20px}
  /* drag chip + action dock */
  #chip{position:fixed;z-index:60;pointer-events:none;display:none;background:var(--card);border:1px solid var(--accent);
    border-radius:9px;padding:7px 11px;font-size:13px;font-weight:600;box-shadow:0 8px 24px rgba(0,0,0,.5);transform:translate(-50%,-140%)}
  #dock{position:fixed;left:0;right:0;bottom:0;z-index:55;display:none;justify-content:center;gap:10px;flex-wrap:wrap;
    padding:16px;padding-bottom:max(16px,env(safe-area-inset-bottom));background:linear-gradient(transparent,rgba(0,0,0,.75) 45%)}
  .zone{min-width:88px;text-align:center;padding:14px 12px;border-radius:12px;font-size:13px;font-weight:600;
    background:var(--card);border:1px solid var(--stroke);color:var(--text)}
  .zone.hot{background:var(--accent);color:#0b1020;border-color:var(--accent);transform:scale(1.06)}
  .zone.danger{color:var(--red);border-color:rgba(217,107,115,.4)}
  .zone.danger.hot{background:var(--red);color:#fff}
  /* terminal overlay */
  /* Sizing this to the visible viewport is what left a gap: the value comes from JS, and whenever it
     lagged the browser chrome the overlay was short and you could see — and scroll — the dashboard
     underneath. It now always spans the layout viewport, and syncViewport pads the band the chrome
     and keyboard occupy, so the background covers the screen no matter what the measurement says. */
  #term{position:fixed;inset:0;z-index:50;background:var(--bg);
    display:none;flex-direction:column;overscroll-behavior:none}
  /* The JS height comes from visualViewport; if that is ever stale the overlay is short and the
     page shows through underneath, so paint the same background behind it as well. */
  body.locked{background:var(--bg)}
  #term.show{display:flex}
  /* inset:0 rather than width alone: a body left at its scrolled offset is another way the page
     underneath ends up visible at an edge. overscroll-behavior kills the rubber-band with it. */
  body.locked{overflow:hidden;position:fixed;inset:0;width:100%;overscroll-behavior:none}
  #termbar{display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--panel);
    border-bottom:1px solid var(--stroke);padding-top:max(10px,env(safe-area-inset-top))}
  #termbar button{background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:8px;padding:7px 12px;font-size:13px;font-weight:600;cursor:pointer}
  #termbar .tname{font-weight:600;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #termframe{flex:1;border:0;width:100%;background:#000;display:none}
  #termframe.on{display:block}
  /* view switch */
  #tabs{display:flex;gap:2px;background:var(--card);border:1px solid var(--stroke);border-radius:8px;padding:2px}
  #tabs button{background:transparent;border:0;color:var(--sub);border-radius:6px;padding:5px 11px;font-size:12px;font-weight:600;cursor:pointer}
  #tabs button.on{background:var(--accent);color:#0b1020}
  /* conversation pane — plain scrollable chat, the reliable way to read history on a phone */
  /* pan-y: vertical scrolling stays the browser's, horizontal gestures come to us — which is both
     how the swipe-back below is possible and what stops Safari's own edge swipe leaving the page. */
  #chat{flex:1;min-height:0;position:relative;overflow-y:auto;-webkit-overflow-scrolling:touch;
    background:var(--bg);padding:18px 20px 26px;display:none;overscroll-behavior:contain;
    touch-action:pan-y}
  /* Held halfway, the overlay has to read as a card lifted off the dashboard rather than a broken
     layout — hence the edge shadow, kept through the settle so it fades out with the movement. */
  #term.dragging{transition:none}
  #term.settle{transition:transform .24s cubic-bezier(.22,.8,.3,1)}
  #term.dragging,#term.settle{box-shadow:-22px 0 46px rgba(0,0,0,.55)}
  /* Hold the text to a comfortable measure on a wide screen instead of letting lines run the
     full width of a desktop browser. */
  #chat > *{max-width:760px;margin-left:auto;margin-right:auto}
  #chat.on{display:block}
  .msg{margin:0 0 16px;font-size:13.5px;line-height:1.62}
  /* One floating bar carries the prompt currently being answered. Making each prompt sticky piled
     every past one at the top instead of replacing it, so a single element is kept and its text
     swapped as you scroll. */
  #stickyq{position:absolute;left:0;right:0;z-index:4;display:none;padding:12px 20px 0;
    pointer-events:none}
  #stickyq .sq{max-width:760px;margin:0 auto}
  #stickyq.on{display:block}
  /* It floats over live text, so it needs to read as a separate layer — and on a dark page the
     cleanest way to say "this is on top" is to invert it: white glass, dark text. No tint and no
     coloured edge, so it stays a quotation of the conversation rather than a control. */
  #stickyq .sq{position:relative;padding:13px 16px;border-radius:12px;
    font-size:14px;line-height:1.5;font-weight:500;color:#15181d;
    background:rgba(255,255,255,.86);
    -webkit-backdrop-filter:blur(30px) saturate(140%);backdrop-filter:blur(30px) saturate(140%);
    border:1px solid rgba(255,255,255,.6);
    box-shadow:0 12px 30px rgba(0,0,0,.45);
    display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
  .msg .mtext{white-space:pre-wrap;word-break:break-word}
  .msg.user{margin-top:26px}                 /* a new question needs a visible break before it */
  .msg.user:first-child{margin-top:0}
  /* Same white card as #stickyq: that bar is a quotation of one of these, so they have to read as
     the same object. Inline code and links need their own colours on a light ground. */
  .msg.user .mtext{background:rgba(255,255,255,.86);color:#15181d;
    padding:12px 15px;border-radius:12px;font-size:14px;line-height:1.55;
    border:1px solid rgba(255,255,255,.6);box-shadow:0 6px 16px rgba(0,0,0,.32)}
  .msg.user .mtext code{background:rgba(0,0,0,.07);color:#12151a}
  /* Sending should feel like the card is pushed up out of the composer, so it starts squashed
     against the bottom edge and settles with a slight overshoot. */
  @keyframes extrude{
    0%  {transform:translateY(16px) scaleY(.5) scaleX(.94);opacity:0}
    55% {transform:translateY(0) scaleY(1.05) scaleX(1.01);opacity:1}
    100%{transform:none;opacity:1}
  }
  .msg.user.sending .mtext{transform-origin:bottom center;
    animation:extrude .34s cubic-bezier(.2,.9,.25,1.2) both}
  @media (prefers-reduced-motion:reduce){ .msg.user.sending .mtext{animation:none} }
  .msg.user .mtext a{color:#1b4bd0}
  .msg.asst .mtext{color:var(--text);padding:0 2px}
  .msg.sub{opacity:.72}
  .msg .tag{font-size:9px;font-weight:700;color:var(--accent);text-transform:uppercase;margin-bottom:2px}
  /* typed while the agent was working: the same card, just drawn with a broken edge */
  .msg.user.queued .mtext{background:rgba(255,255,255,.78);
    border-style:dashed;border-color:rgba(21,24,29,.28)}
  .msg.think,.msg.tool{background:var(--card);border:1px solid var(--stroke);border-radius:10px;
    padding:10px 12px;cursor:pointer;margin-left:10px}
  .msg.think{opacity:.7}
  .msg.tool.bad{border-color:rgba(217,107,115,.5)}
  .mhead{display:flex;gap:7px;align-items:baseline;font-size:12px}
  .mhead .sum{color:var(--sub);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
  .msg .mbody{display:none;white-space:pre-wrap;word-break:break-word;margin-top:8px;padding-top:8px;
    border-top:1px solid var(--stroke);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    font-size:11px;color:var(--sub);max-height:340px;overflow:auto}
  .msg.open .mbody{display:block}
  .msg.think .mtext{display:none}
  .msg.think.open .mtext{display:block;margin-top:7px;font-size:12px}
  #chatnote{color:var(--sub);text-align:center;padding:30px 16px;font-size:12px}
  /* Opening a terminal used to leave the previous conversation on screen until the fetch came back,
     which read as the wrong session rather than as loading. A skeleton of the shape that is coming
     says "this is being fetched" without pretending to be content. */
  .skel{max-width:760px;margin:0 auto}
  .skel .sk-user{margin:26px 0 16px}
  .skel .sk-asst{margin:0 0 26px;padding:0 2px}
  .skel .row{height:12px;border-radius:7px;margin-bottom:8px;
    background:linear-gradient(90deg,rgba(255,255,255,.05),rgba(255,255,255,.11),rgba(255,255,255,.05));
    background-size:220% 100%;animation:shim 1.2s linear infinite}
  .skel .sk-user .row{height:44px;border-radius:12px;
    background:linear-gradient(90deg,rgba(255,255,255,.10),rgba(255,255,255,.20),rgba(255,255,255,.10));
    background-size:220% 100%}
  @keyframes shim{0%{background-position:220% 0}100%{background-position:-120% 0}}
  /* The conversation arrives rather than appearing: each card comes up from below with a strong
     ease-out and a small overshoot, staggered, so the eye follows the last few into place. The two
     sides drift in from their own edge, which is what makes it read as flying rather than fading. */
  @keyframes flyR{
    0%  {opacity:0;transform:translate(22px,30px) scale(.955)}
    62% {opacity:1;transform:translate(-3px,-5px) scale(1.008)}
    100%{opacity:1;transform:none}
  }
  @keyframes flyL{
    0%  {opacity:0;transform:translate(-16px,26px) scale(.965)}
    62% {opacity:1;transform:translate(2px,-4px) scale(1.006)}
    100%{opacity:1;transform:none}
  }
  .msg.fly{animation:flyL .5s cubic-bezier(.16,1,.3,1) both}
  .msg.user.fly{animation-name:flyR}
  @media (prefers-reduced-motion:reduce){ .skel .row,.msg.fly{animation:none} }
  @media (max-width:520px){
    #chat{padding:14px 13px 22px}
    #sinfo{padding:6px 13px}
    #stickyq{padding:10px 13px 0}
    #inputbar{padding-left:10px;padding-right:10px}
    .msg.think,.msg.tool{margin-left:0}
  }
  /* a shell terminal's scrollback — wrapped so a phone never scrolls sideways */
  .shellout{margin:0;white-space:pre-wrap;word-break:break-word;font-size:11.5px;line-height:1.5;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text)}
  /* markdown inside a message (block elements handle spacing, so no pre-wrap here) */
  .msg .mtext.md{white-space:normal}
  .md p{margin:0 0 8px}
  .md p:last-child{margin-bottom:0}
  .md h1,.md h2,.md h3{margin:12px 0 6px;font-weight:700;line-height:1.35;font-size:14px}
  .md h1{font-size:16px}
  .md h2{font-size:15px}
  .md ul,.md ol{margin:4px 0 8px;padding-left:20px}
  .md li{margin:2px 0}
  .md blockquote{margin:6px 0;padding:2px 0 2px 10px;border-left:2px solid var(--stroke);color:var(--sub)}
  .md hr{border:0;border-top:1px solid var(--stroke);margin:10px 0}
  .md a{color:var(--accent)}
  .md code{background:rgba(255,255,255,.08);padding:1px 4px;border-radius:4px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px}
  .md pre.code{background:#0e1116;border:1px solid var(--stroke);border-radius:8px;padding:9px 10px;
    margin:8px 0;overflow-x:auto;white-space:pre;position:relative;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;line-height:1.45}
  .md pre.code i.lang{position:absolute;right:8px;top:3px;font-style:normal;font-size:9px;
    color:var(--sub);text-transform:uppercase;letter-spacing:.04em}
  .md table{border-collapse:collapse;margin:8px 0;font-size:12px;display:block;overflow-x:auto}
  .md th,.md td{border:1px solid var(--stroke);padding:4px 8px;text-align:left}
  .md th{background:var(--card);font-weight:600}
  /* code diff (Edit / MultiEdit / Write / codex apply_patch) */
  .diff{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;line-height:1.5;
    overflow-x:auto;border-radius:6px;background:#0e1116;padding:6px 0;margin-top:7px}
  .dl{white-space:pre;padding:0 10px}
  .dl.add{background:rgba(92,209,140,.14);color:#9fe3bd}
  .dl.del{background:rgba(217,107,115,.14);color:#f0a8ad}
  .dl.ctx{color:var(--sub)}
  .dl.ph{color:var(--accent);font-weight:700}
  .dgap{color:var(--sub);opacity:.55;padding:2px 10px;font-size:10px}
  .dhead{color:var(--sub);padding:5px 10px 1px;font-size:10px;text-transform:uppercase;letter-spacing:.04em}
  .dstat{font-size:10px;font-weight:700;white-space:nowrap}
  .dstat .a{color:var(--green)}
  .dstat .d{color:var(--red)}
  /* session info strip: model, permission mode, context-window fill */
  #sinfo{display:flex;gap:7px;align-items:center;flex-wrap:wrap;padding:7px 20px;background:var(--panel);
    border-bottom:1px solid var(--stroke);font-size:10px;color:var(--sub)}
  #sinfo:empty{display:none}
  #sinfo .chip{background:var(--card);border:1px solid var(--stroke);border-radius:999px;padding:2px 8px;font-weight:600}
  #sinfo .chip.warn{color:var(--amber);border-color:rgba(250,184,82,.45)}
  #sinfo .chip.danger{color:var(--red);border-color:rgba(217,107,115,.5)}
  #sinfo .bar{height:4px;width:74px;background:var(--card);border-radius:2px;overflow:hidden}
  #sinfo .bar i{display:block;height:100%;background:var(--accent)}
  #sinfo .bar.warn i{background:var(--amber)}
  #sinfo .bar.danger i{background:var(--red)}
  #sinfo .live{display:flex;align-items:center;gap:5px;font-weight:600}
  #sinfo .live .dot{width:7px;height:7px;border-radius:50%}
  #sinfo .live.run .dot{animation:live 1.1s ease-out infinite}
  @keyframes live{0%{box-shadow:0 0 0 0 rgba(92,209,140,.55)}100%{box-shadow:0 0 0 6px rgba(92,209,140,0)}}
  /* what the agent is doing right now, pinned under the last message */
  .runbar{display:flex;align-items:center;gap:8px;padding:9px 11px;margin:2px 0 10px;
    background:rgba(92,209,140,.09);border:1px solid rgba(92,209,140,.28);border-radius:10px;
    font-size:12px;color:var(--green)}
  .runbar .what{color:var(--sub);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .runbar.wait{background:rgba(250,184,82,.1);border-color:rgba(250,184,82,.32);color:var(--amber)}
  /* a tool still running (no result yet) */
  .msg.tool.run{border-color:rgba(122,158,255,.5)}
  .spin{display:inline-block;width:9px;height:9px;border:1.5px solid var(--accent);border-right-color:transparent;
    border-radius:50%;animation:sp .7s linear infinite;flex:none}
  @keyframes sp{to{transform:rotate(360deg)}}
  .msg .when{font-size:9px;color:var(--sub);opacity:.55;margin-left:6px;font-weight:400}
  .msg .cp{font-size:9px;color:var(--sub);opacity:.45;cursor:pointer;padding:0 5px;float:right}
  .msg .cp:active{opacity:1;color:var(--accent)}
  /* permission / question card */
  #perm{display:none;background:rgba(250,184,82,.1);border-top:1px solid rgba(250,184,82,.4);padding:10px 12px}
  #perm.on{display:block}
  #perm .q{font-size:12px;font-weight:600;color:var(--amber);margin-bottom:8px}
  #perm .what{font-size:11px;color:var(--sub);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    margin-bottom:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #perm .opts{display:flex;flex-direction:column;gap:6px}
  #perm button{text-align:left;background:var(--card);color:var(--text);border:1px solid var(--stroke);
    border-radius:8px;padding:9px 11px;font-size:13px;cursor:pointer}
  #perm button:active{background:var(--accent);color:#0b1020}
  /* todo / plan / question tool views */
  .todo{margin-top:7px}
  .todo div{padding:2px 0;font-size:12px;line-height:1.45}
  .todo .d{color:var(--sub);text-decoration:line-through}
  .todo .p{color:var(--accent);font-weight:600}
  .qopts{margin-top:6px}
  .qopts .qq{font-size:12px;font-weight:600;margin:6px 0 3px}
  .qopts .qo{font-size:12px;color:var(--sub);padding:1px 0 1px 14px}
  /* jump to latest */
  #jump{position:absolute;right:14px;bottom:96px;z-index:6;background:var(--accent);color:#0b1020;border:0;
    border-radius:999px;width:34px;height:34px;font-size:16px;line-height:1;cursor:pointer;display:none;
    box-shadow:0 4px 14px rgba(0,0,0,.45)}
  #jump.on{display:block}
  /* flex:none + the safe-area pad keeps the composer pinned to the true bottom; without it the
     bar floated and the page showed through underneath on a phone. */
  #inputbar{flex:none;background:var(--panel);border-top:1px solid var(--stroke);
    padding:10px 14px;padding-bottom:max(10px,env(safe-area-inset-bottom))}
  #inputbar > *{max-width:760px;margin-left:auto;margin-right:auto}
  #prow{display:flex;gap:6px;align-items:center;margin-bottom:8px}
  #pfind{flex:none;width:82px;background:var(--card);color:var(--text);border:1px solid var(--stroke);
    border-radius:7px;padding:5px 8px;font-size:12px;font-family:inherit}
  #presets{flex:1;display:flex;gap:6px;overflow-x:auto;min-width:0}
  #presets button{flex:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:7px;
    padding:6px 10px;font-size:12px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap;cursor:pointer}
  #presets button:active{background:var(--accent);color:#0b1020}
  #presets button.meta{color:var(--accent);font-family:inherit;font-weight:600}
  #presets button.del{color:var(--red);border-color:rgba(217,107,115,.4);font-family:inherit}
  #keys{display:flex;gap:6px;overflow-x:auto;margin-bottom:8px}
  #keys button{flex:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:7px;padding:6px 10px;font-size:12px;font-weight:600;cursor:pointer}
  #keys button:active{background:var(--accent);color:#0b1020}
  /* The key row exists to drive a TUI: scrolling a pane, arrowing through a menu, ^C, backspace.
     Chat has none of that — it scrolls natively, answers prompts with real buttons, and stops the
     agent with the Send/Stop button — so the whole row goes away there. */
  #keys.chatview{display:none}
  #sendrow{display:flex;gap:8px;align-items:flex-end}
  #inputtext{flex:1;resize:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:10px;
    padding:10px 12px;font:14px/1.35 inherit;max-height:120px}
  #sendbtn{flex:none;background:var(--accent);color:#0b1020;border:0;border-radius:10px;padding:11px 16px;font-size:14px;font-weight:700;cursor:pointer}
</style>
</head>
<body>
<div id="panel"><button class="pcollapse" onclick="togglePanel()">▾ hide</button>
  <iframe id="panelframe" sandbox="allow-scripts allow-same-origin allow-popups allow-forms" src="about:blank"></iframe></div>
<header>
  <span class="logo"><b>▉</b> FleetView</span>
  <span class="muted" id="counts">…</span>
  <span id="pills"></span>
  <span class="spacer"></span>
  <span class="refresh" id="refresh"></span>
</header>
<main id="root"><div class="empty">Loading…</div></main>

<div id="chip"></div>
<div id="dock"></div>

<div id="term">
  <div id="termbar">
    <button onclick="closeTerm()">‹</button>
    <span class="tname" id="termname"></span>
    <div id="tabs">
      <button id="tabChat" class="on" onclick="setView('chat')">Chat</button>
      <button id="tabTerm" onclick="setView('term')">Terminal</button>
    </div>
    <button onclick="popTerm()">↗</button>
  </div>
  <div id="sinfo"></div>
  <div id="chat" class="on"><div id="chatnote">Loading…</div></div>
  <div id="stickyq"><div class="sq"></div></div>
  <button id="jump" onclick="jumpLatest()">↓</button>
  <iframe id="termframe" src="about:blank" allow="clipboard-read; clipboard-write"></iframe>
  <div id="perm"></div>
  <div id="inputbar">
    <div id="prow"><input id="pfind" placeholder="filter" oninput="renderPresets()"><div id="presets"></div></div>
    <div id="keys">
      <button class="skey" onclick="scrollTerm('up')">⇞</button>
      <button class="skey" onclick="scrollTerm('down')">⇟</button>
      <button onclick="key('Escape')">Esc</button>
      <button onclick="key('Enter')">⏎</button>
      <button onclick="key('Up')">↑</button>
      <button onclick="key('Down')">↓</button>
      <button onclick="key('Tab')">Tab</button>
      <button onclick="key('C-c')">^C</button>
      <button onclick="key('BSpace')">⌫</button>
    </div>
    <div id="sendrow">
      <textarea id="inputtext" rows="1" placeholder="Type here (中文 OK) — Enter to send, Shift+Enter for newline"></textarea>
      <button id="sendbtn">Send</button>
    </div>
  </div>
</div>

<script>
const COLORS={working:'var(--green)',shell:'var(--teal)',idle:'var(--gray)',
  needsYou:'var(--amber)',exited:'var(--red)',closed:'rgba(255,255,255,.22)'};
let curUrl='',curId='',state=null,dragging=false,curView='chat',chatTimer=null,termLoaded=false,curInfo={},sentAt=0,stickBottom=false,flyNext=false;

function short(n){if(n<1000)return ''+n;if(n<1000000)return (n/1000).toFixed(n<10000?1:0)+'k';return (n/1000000).toFixed(1)+'M';}
function ago(sec){if(sec<0)return '';if(sec<5)return 'just now';if(sec<60)return sec+'s ago';
  const m=Math.floor(sec/60);if(m<60)return m+'m ago';const h=Math.floor(m/60);if(h<24)return h+'h ago';return Math.floor(h/24)+'d ago';}
function esc(s){const d=document.createElement('div');d.textContent=s||'';return d.innerHTML;}
function termOpen(){return document.getElementById('term').classList.contains('show');}

// ---------- terminal open / input ----------
/* Ask the device where it is, rather than guessing from its address.
   navigator.geolocation is gated on a secure context, so over plain http://<lan-ip> the browser
   refuses before it even prompts — that fact is reported once so the log explains its own gap
   instead of just lacking a coordinate. Serve the dashboard over HTTPS (tailscale serve) and the
   same code starts returning a real fix. */
let geoDone=false;
function reportLocation(state){
  if(geoDone||!state||!state.askGeo) return;
  const prior=localStorage.getItem('fv_geo');
  const secure=window.isSecureContext&&navigator.geolocation;
  if(!secure){
    if(prior!=='insecure'){ localStorage.setItem('fv_geo','insecure');
      fetch('/geo?consent=unavailable&reason=insecure_context',{cache:'no-store'}).catch(()=>{}); }
    return;                       // nothing to ask for until the page is served over HTTPS
  }
  if(prior==='denied') return;    // asked and refused once — do not nag on every reload
  geoDone=true;
  navigator.geolocation.getCurrentPosition(
    p=>{ localStorage.setItem('fv_geo','granted');
         fetch('/geo?consent=granted&lat='+p.coords.latitude+'&lon='+p.coords.longitude
               +'&acc='+Math.round(p.coords.accuracy||0),{cache:'no-store'}).catch(()=>{}); },
    e=>{ localStorage.setItem('fv_geo','denied');
         fetch('/geo?consent=denied&reason='+encodeURIComponent((e&&e.message)||'denied'),
               {cache:'no-store'}).catch(()=>{}); },
    {enableHighAccuracy:false,timeout:10000,maximumAge:600000});
}

/* Tell the server which terminal is on screen. Opening one is pure client-side state, so without
   this beacon "what was being watched, and for how long" would have to be inferred from a polling
   endpoint — whose meaning would drift the moment the poll interval changed. */
function beaconSelect(id,view){
  try{ fetch('/select?id='+encodeURIComponent(id||'')+'&view='+encodeURIComponent(view||''),
             {cache:'no-store',keepalive:true}); }catch(e){}
}
function skeletonHTML(){
  const row=w=>'<div class="row" style="width:'+w+'"></div>';
  let h='<div class="skel">';
  for(let i=0;i<3;i++) h+='<div class="sk-user">'+row('62%')+'</div>'+
    '<div class="sk-asst">'+row('95%')+row('88%')+row('54%')+'</div>';
  return h+'</div>';
}
function showSkeleton(){
  const el=document.getElementById('chat');
  el.dataset.sig='';                  // nothing on screen belongs to the new terminal
  el.innerHTML=skeletonHTML();
  el.scrollTop=0;
  stickBottom=true;                   // the skeleton is tall; land at the latest, not at the top
  document.getElementById('sinfo').innerHTML='';
  document.getElementById('stickyq').classList.remove('on');
  document.getElementById('perm').classList.remove('on');
  sentGhost=null; curInfo={}; flyNext=true;
}
/* Conversations are re-read from disk on every open, which is a visible wait on a phone. Keep the
   last few on the device and put one straight on screen, then let the poll bring it up to date —
   the skeleton is then only for terminals this device has never opened. */
const CACHE_MAX=8, CACHE_BYTES=300000;
const ckey=id=>'fv_conv_'+id;
function cacheIndex(){ try{ return JSON.parse(localStorage.getItem('fv_conv_ix')||'[]'); }catch(e){ return []; } }
function cacheTouch(id){
  const ix=cacheIndex().filter(x=>x!==id); ix.unshift(id);
  while(ix.length>CACHE_MAX){ try{ localStorage.removeItem(ckey(ix.pop())); }catch(e){} }
  try{ localStorage.setItem('fv_conv_ix',JSON.stringify(ix)); }catch(e){}
}
function cacheGet(id){
  try{ const s=localStorage.getItem(ckey(id)); return s?JSON.parse(s):null; }catch(e){ return null; }
}
function cachePut(id,j){
  const body=JSON.stringify({t:Date.now(),messages:j.messages||[],info:j.info||{},note:j.note||''});
  if(body.length>CACHE_BYTES) return;          // a huge transcript is not worth the quota
  try{ localStorage.setItem(ckey(id),body); cacheTouch(id); }
  catch(e){                                    // out of quota: drop the coldest one and try once more
    const ix=cacheIndex();
    if(!ix.length) return;
    try{ localStorage.removeItem(ckey(ix[ix.length-1]));
         localStorage.setItem(ckey(id),body); cacheTouch(id); }catch(e2){}
  }
}
/* What is cached is the conversation, not what the agent is doing right now — status comes back on
   the first live payload rather than being restored stale. */
function showCached(c){
  const el=document.getElementById('chat');
  el.dataset.sig=''; el.scrollTop=0;
  sentGhost=null; stickBottom=true; flyNext=true;
  curInfo=Object.assign({},c.info,{status:'',pendingTool:'',pendingText:''});
  document.getElementById('stickyq').classList.remove('on');
  document.getElementById('perm').classList.remove('on');
  renderChat(c.messages,c.note);
  renderInfo(curInfo);
}
function openTerm(id,name){
  curId=id;curUrl='';termLoaded=false;
  const cached=cacheGet(id);
  if(cached&&cached.messages&&cached.messages.length) showCached(cached); else showSkeleton();
  document.getElementById('termname').textContent=name;
  document.getElementById('termframe').src='about:blank';
  document.getElementById('term').classList.add('show');
  document.body.classList.add('locked');   // stop the page scrolling behind the overlay
  syncViewport();
  requestAnimationFrame(syncViewport);     // re-measure once the lock has taken effect
  renderPresets();          // latest Notes as quick-commands
  beaconSelect(id,'chat');
  setView('chat');          // reading history is the common remote case
}
/* Swipe right to go back, the way the phone's own apps do. The overlay follows your finger with
   resistance, then either settles back or carries on out to the right. */
(function(){
  const t=document.getElementById('term'), chat=document.getElementById('chat');
  let x0=0,y0=0,dx=0,t0=0,armed=false,active=false,vx=0,lastX=0,lastT=0;
  const reset=()=>{ armed=false; active=false; vx=0;
    t.classList.remove('dragging'); t.classList.remove('settle'); t.style.transform=''; };
  // places where a horizontal drag means something else
  const busy=el=>!!(el&&el.closest&&el.closest('pre.code,.mbody,#presets,#keys,#inputbar,#tabs'));
  chat.addEventListener('touchstart',e=>{
    if(e.touches.length!==1||busy(e.target)){armed=false;return;}
    const p=e.touches[0]; x0=lastX=p.clientX; y0=p.clientY; dx=0; vx=0;
    t0=lastT=performance.now(); armed=true; active=false;
  },{passive:true});
  chat.addEventListener('touchmove',e=>{
    if(!armed)return;
    const p=e.touches[0], ax=p.clientX-x0, ay=p.clientY-y0;
    if(!active){
      // decide once: mostly vertical is a scroll and we never take it back
      if(Math.abs(ay)>10&&Math.abs(ay)>=Math.abs(ax)){armed=false;return;}
      if(ax>14&&Math.abs(ax)>Math.abs(ay)*1.6){ active=true; t.classList.remove('settle'); t.classList.add('dragging'); }
      else return;
    }
    dx=Math.max(0,ax);
    // Speed is tracked as it goes, smoothed, so a pause mid-swipe is a pause and not a flick.
    const now=performance.now(), dt=Math.max(1,now-lastT);
    vx=.65*vx+.35*((p.clientX-lastX)/dt);
    lastX=p.clientX; lastT=now;
    const shown=dx*(1-Math.min(.45,dx/1400));      // resistance, so the far end feels heavy
    t.style.transform='translate3d('+shown+'px,0,0) scale('+(1-Math.min(.02,dx/6000))+')';
    e.preventDefault();
  },{passive:false});
  const settle=()=>{
    if(!active){armed=false;return;}
    // A flick counts short of the distance, but only a real one — and only if the finger was still
    // moving when it lifted. Stopping halfway and letting go is a decision to stay.
    const stalled=performance.now()-lastT>100;
    const flick=!stalled&&vx>.9;
    t.classList.remove('dragging'); t.classList.add('settle');
    if(dx>90||(flick&&dx>50)){
      t.style.transform='translate3d(100%,0,0)';
      setTimeout(()=>{ t.classList.remove('settle'); t.style.transform=''; closeTerm(); },210);
    }else{
      t.style.transform='';
      setTimeout(()=>t.classList.remove('settle'),260);
    }
    armed=false; active=false; vx=0;
  };
  chat.addEventListener('touchend',settle);
  chat.addEventListener('touchcancel',settle);
  // A gesture that never gets its touchend — the tab going away mid-swipe — must not leave the
  // overlay parked half off the screen.
  document.addEventListener('visibilitychange',()=>{ if(document.hidden&&active) reset(); });
})();
function closeTerm(){
  document.getElementById('stickyq').classList.remove('on');
  document.getElementById('term').classList.remove('show');
  document.body.classList.remove('locked');
  window.scrollTo(0,0);
  syncViewport();                          // drop the keyboard-era height/offset
  document.getElementById('termframe').src='about:blank';
  curId='';termLoaded=false;stopChatPoll();
  beaconSelect('','');
}
/* Chat = structured transcript (native scrolling, works on touch).
   Terminal = the live ttyd mirror, loaded lazily so just reading costs nothing. */
function setView(v){
  curView=v;
  document.getElementById('tabChat').classList.toggle('on',v==='chat');
  document.getElementById('tabTerm').classList.toggle('on',v==='term');
  document.getElementById('chat').classList.toggle('on',v==='chat');
  document.getElementById('termframe').classList.toggle('on',v==='term');
  document.getElementById('keys').classList.toggle('chatview',v==='chat');
  updateStickyPrompt();          // it belongs to the chat pane — never leave it over the terminal
  if(v==='term'){stopChatPoll();ensureTerm();}
  else{loadChat();startChatPoll();}
}
async function ensureTerm(){
  if(termLoaded||!curId)return;
  termLoaded=true;
  try{
    const j=await(await fetch('/open?id='+encodeURIComponent(curId))).json();
    if(!j.port){termLoaded=false;toast('This terminal is not open on the Mac right now');return;}
    curUrl=location.protocol+'//'+location.hostname+':'+j.port+'/';
    document.getElementById('termframe').src=curUrl;
  }catch(e){termLoaded=false;}
}
async function popTerm(){await ensureTerm();if(curUrl)window.open(curUrl,'_blank');}

/* ---------- conversation view ---------- */
const TOOLICON={terminal:'$',edit:'✎',read:'▤',search:'⌕',web:'⬡',task:'⚙',other:'•'};
function startChatPoll(){stopChatPoll();chatTimer=setInterval(loadChat,3000);}
function stopChatPoll(){if(chatTimer){clearInterval(chatTimer);chatTimer=null;}}
async function loadChat(){
  if(!curId)return;
  const want=curId;
  try{
    const j=await(await fetch('/conversation?id='+encodeURIComponent(want)+'&limit=150',{cache:'no-store'})).json();
    if(want!==curId)return;           // you switched terminals while this was in flight
    curInfo=j.info||{};
    if(sentAt){                       // hold 'running' until the hook catches up, then let go
      if(performance.now()-sentAt>4000||curInfo.status!=='idle') sentAt=0;
      else curInfo.status='working';
    }
    // A plain shell has no conversation — show its scrollback instead, which is the thing you
    // actually want to read remotely (and unlike the terminal mirror, this scrolls on touch).
    if(curInfo.shell) await renderShell();
    else { renderChat(j.messages||[],j.note); cachePut(want,j); }
    renderInfo(curInfo);
    renderPerm(curInfo);
    syncSendBtn();
  }catch(e){}
}
/* iOS/iPadOS scrolls the whole document to reveal a focused field and doesn't undo it when the
   keyboard goes away, which left the overlay shifted up with a gap beneath. Track the visual
   viewport instead: the overlay is sized and offset to exactly the area the keyboard leaves,
   so the composer rides above it and everything lands back when it closes. */
let lastBand='';
function syncViewport(){
  const t=document.getElementById('term'), vv=window.visualViewport;
  if(!t.classList.contains('show')){
    if(lastBand===''){ return; }
    t.style.paddingTop=t.style.paddingBottom=t.style.height=t.style.transform='';
    document.getElementById('jump').style.bottom=''; lastBand=''; return;
  }
  if(!vv) return;
  // The keyboard shortens the band, which shortens the chat — and a scroll box that keeps its
  // scrollTop while it shrinks pushes whatever you were reading below the fold. Measure the
  // distance from the bottom first and restore it after, so the line above the composer stays
  // above the composer and the conversation rides up with the input.
  const H=t.offsetHeight||window.innerHeight;    // border-box, so this is the full layout viewport
  // Only a keyboard gets padded off. visualViewport is not trustworthy on its own here: iPadOS can
  // leave its height at the keyboard-era value after the keyboard is gone, and that stale number
  // was the strip of dead space under the composer that never went away. So the measurement has to
  // agree with two other things — that a field is actually focused, and that the shortfall is big
  // enough to be a keyboard rather than browser chrome (which inset:0 already accounts for).
  const a=document.activeElement, ta=document.getElementById('inputtext');
  const typing=a===ta||a===document.getElementById('pfind');
  const short=Math.max(0,Math.round(H-vv.height-vv.offsetTop));
  const bottom=(typing&&short>=120)?short:0;
  const top=bottom?Math.max(0,Math.round(vv.offsetTop)):0;
  // Nothing moved: leave the styles and, above all, the scroll position alone. Without this the
  // poll below would fight a flick-scroll every time it ran.
  if(top+':'+bottom===lastBand) return;
  lastBand=top+':'+bottom;
  const chat=document.getElementById('chat');
  const gap=Math.max(0,chat.scrollHeight-chat.scrollTop-chat.clientHeight);
  t.style.height='';
  if(!t.classList.contains('dragging')) t.style.transform='';   // never fight a swipe in progress
  t.style.paddingTop=top+'px';
  t.style.paddingBottom=bottom+'px';
  document.getElementById('jump').style.bottom=(96+bottom)+'px';   // it sits above the composer
  chat.scrollTop=Math.max(0,chat.scrollHeight-chat.clientHeight-gap);
  updateStickyPrompt();                          // the pane moved; the floating bar follows it
}
if(window.visualViewport){
  visualViewport.addEventListener('resize',syncViewport);
  visualViewport.addEventListener('scroll',syncViewport);
}
/* Rotation and browser-chrome changes don't always emit a visualViewport event, and the value read
   during openTerm can predate the lock, so re-measure on the next frame too. */
window.addEventListener('resize',syncViewport);
window.addEventListener('orientationchange',()=>setTimeout(syncViewport,120));
/* Dismissing the keyboard doesn't always end with a visualViewport event — iPadOS can leave the
   last one from mid-animation, and the band stays keyboard-sized: a strip of empty page under the
   composer that never goes away. Re-measure on a slow tick; it's a no-op unless the band moved. */
setInterval(syncViewport,400);
/* Both fields, not just the composer: the preset filter opens the same keyboard, and while it had
   no handlers at all its band was only ever cleared by the slow poll — and not at all if the
   measurement below stayed stale. */
for(const id of ['inputtext','pfind']){
  const el=document.getElementById(id);
  if(!el) continue;
  el.addEventListener('focusout',()=>{
    lastBand='';                   // force the next measurement through, focus has changed
    syncViewport(); setTimeout(syncViewport,60); setTimeout(syncViewport,400);
  });
  el.addEventListener('focus',()=>{ lastBand=''; });
  /* Belt and braces: if the document itself got scrolled while a field had focus, put it back. */
  el.addEventListener('blur',()=>{
    window.scrollTo(0,0);
    setTimeout(syncViewport,50);
  });
}
/* Dismissing the keyboard with the field still focused (iPadOS' hide-keyboard key, iOS' Done)
   emits no blur and no focusout, so the two guards on the measurement — "a field is focused" and
   "the shortfall is keyboard-sized" — can both still hold against a stale visualViewport height.
   The band then stays keyboard-sized with no keyboard, which is the offset that never came back.
   Tapping the transcript is the gesture people actually use to put the keyboard away, so make it
   blur explicitly: that puts the dismissal back on the handlers above instead of on a measurement
   that may never change again. */
document.getElementById('chat').addEventListener('pointerdown',()=>{
  const a=document.activeElement;
  if(a&&(a.id==='inputtext'||a.id==='pfind')) a.blur();
},{passive:true});
/* Coming back from another app is the other way to return to a keyboard-sized band with no
   keyboard: the events that would have cleared it fired while the tab was hidden. */
document.addEventListener('visibilitychange',()=>{
  if(document.hidden) return;
  lastBand=''; syncViewport(); setTimeout(syncViewport,200);
});

/* Shell terminal: the pane's scrollback, wrapped and natively scrollable. */
async function renderShell(){
  const el=document.getElementById('chat');
  const want=curId;
  let txt='';
  try{ txt=await(await fetch('/capture?id='+encodeURIComponent(want)+'&lines=1500',{cache:'no-store'})).text(); }catch(e){ return; }
  if(want!==curId)return;
  txt=txt.replace(/\s+$/,'');
  const sig='sh'+txt.length+':'+txt.slice(-80);
  if(el.dataset.sig===sig)return;
  const nearBottom=el.scrollHeight-el.scrollTop-el.clientHeight<120;
  el.dataset.sig=sig;
  el.innerHTML=txt?'<pre class="shellout">'+esc(txt)+'</pre>'
                  :'<div id="chatnote">Nothing on screen yet.</div>';
  if(nearBottom)el.scrollTop=el.scrollHeight;
  updateStickyPrompt();
}
/* model / permission-mode / context-window strip */
const STATUS_TEXT={working:'running',idle:'idle',needsYou:'needs you',shell:'shell',
  exited:'exited',closed:'closed'};
function renderInfo(i){
  const el=document.getElementById('sinfo');
  document.getElementById('tabChat').textContent=(i&&i.shell)?'Output':'Chat';   // shell has no chat
  if(!i||(!i.model&&!i.contextTokens&&!i.status)){el.innerHTML='';return;}
  let h='';
  // Chat had no sign of whether the agent was actually working — the transcript just stopped growing.
  if(i.status){
    const c=COLORS[i.status]||COLORS.closed;
    h+='<span class="live'+(i.status==='working'?' run':'')+'" style="color:'+c+'">'+
       '<span class="dot" style="background:'+c+'"></span>'+(STATUS_TEXT[i.status]||i.status)+'</span>';
  }
  if(i.model) h+='<span class="chip">'+esc(i.model.replace(/^claude-/,''))+'</span>';
  if(i.permissionMode&&i.permissionMode!=='default'){
    const risky=/bypass|yolo|accept/i.test(i.permissionMode);
    h+='<span class="chip'+(risky?' danger':'')+'">'+esc(i.permissionMode)+'</span>';
  }
  // Several terminals can be attached to one agent session — then the chat is identical for all of
  // them by definition. Say so, rather than letting it look like the wrong conversation.
  if(i.shared>1) h+='<span class="chip warn" title="This conversation belongs to one session that '+
    i.shared+' terminals share — use the Terminal tab to see this pane on its own">⇉ shared by '+i.shared+' terminals</span>';
  if(i.session) h+='<span class="chip" title="session '+esc(i.session)+'">'+esc(i.session.slice(0,8))+'</span>';
  // The session is a tree; only the live branch is shown. Say when earlier attempts exist.
  if(i.branches>0) h+='<span class="chip" title="This session has '+i.branches+
    ' branch point(s) from rewinds/edits — only the active branch is shown">⑂ '+i.branches+'</span>';
  if(i.contextWindow>0&&i.contextTokens>0){
    const pct=Math.min(100,Math.round(i.contextTokens*100/i.contextWindow));
    const lvl=pct>=95?'danger':(pct>=90?'warn':'');
    h+='<span class="bar '+lvl+'"><i style="width:'+pct+'%"></i></span>'+
       '<span class="chip '+lvl+'">'+pct+'% ctx · '+short(i.contextTokens)+'</span>';
  }
  el.innerHTML=h;
}
/* the agent is blocked on a decision → real buttons instead of guessing a digit */
function renderPerm(i){
  const el=document.getElementById('perm');
  if(!i||!i.options||!i.options.length){ el.classList.remove('on'); el.innerHTML=''; return; }
  el.innerHTML='<div class="q">'+esc(i.question||'Waiting for your decision')+'</div>'+
    (i.pendingTool?'<div class="what">'+esc(i.pendingTool)+(i.pendingText?' · '+esc(i.pendingText):'')+'</div>':'')+
    '<div class="opts">'+i.options.map(o=>'<button data-n="'+esc(o.n)+'">'+esc(o.n)+'. '+esc(o.label)+'</button>').join('')+'</div>';
  el.classList.add('on');
}
document.getElementById('perm').addEventListener('click',e=>{
  const b=e.target.closest?e.target.closest('button[data-n]'):null;
  if(!b||!curId)return;
  fetch('/type?id='+encodeURIComponent(curId)+'&enter=1&text='+encodeURIComponent(b.dataset.n));
  document.getElementById('perm').classList.remove('on');
  setTimeout(loadChat,700);
});
/* empty box while the agent works → Stop; typed text → Send (queues, doesn't interrupt) */
function syncSendBtn(){
  const btn=document.getElementById('sendbtn'), ta=document.getElementById('inputtext');
  const stop=!ta.value.trim() && curInfo && curInfo.status==='working';
  btn.textContent=stop?'Stop':'Send';
  btn.style.background=stop?'var(--red)':'var(--accent)';
  btn.dataset.stop=stop?'1':'';
}
function jumpLatest(){ const el=document.getElementById('chat'); el.scrollTop=el.scrollHeight; }
document.getElementById('chat').addEventListener('scroll',()=>{
  const el=document.getElementById('chat');
  document.getElementById('jump').classList.toggle('on', el.scrollHeight-el.scrollTop-el.clientHeight>300);
  updateStickyPrompt();
});
/* Which question do the replies on screen belong to? The last prompt that has scrolled past the
   top — shown until you scroll back to it, then it goes back to being an ordinary message. */
function updateStickyPrompt(){
  const chat=document.getElementById('chat'), bar=document.getElementById('stickyq');
  if(!chat.classList.contains('on')||(curInfo&&curInfo.shell)){bar.classList.remove('on');return;}
  let cur=null;
  const users=chat.querySelectorAll('.msg.user');
  for(let i=0;i<users.length;i++){
    if(users[i].offsetTop < chat.scrollTop+6) cur=users[i]; else break;
  }
  if(!cur){bar.classList.remove('on');return;}
  const t=cur.querySelector('.mtext');
  bar.firstElementChild.textContent=t?(t.innerText||t.textContent||''):'';
  bar.style.top=chat.offsetTop+'px';
  bar.classList.add('on');
}
/* clipboard needs a secure context; plain-HTTP over Tailscale isn't one, so fall back */
function copyText(t){
  try{ if(navigator.clipboard&&window.isSecureContext){ navigator.clipboard.writeText(t); toast('Copied'); return; } }catch(e){}
  const ta=document.createElement('textarea');
  ta.value=t; ta.style.position='fixed'; ta.style.opacity='0';
  document.body.appendChild(ta); ta.select();
  try{ document.execCommand('copy'); toast('Copied'); }catch(e){ toast('Copy failed'); }
  document.body.removeChild(ta);
}
function hhmm(ts){
  if(!ts)return '';
  const d=new Date(ts); if(isNaN(d))return '';
  return d.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
}
function since(ts){
  if(!ts)return '';
  const s=Math.max(0,Math.round((Date.now()-new Date(ts).getTime())/1000));
  return isNaN(s)?'':(s<60?s+'s':Math.floor(s/60)+'m');
}
/* ---------- markdown ----------
   Small on-purpose subset: fenced code, headings, lists, tables, quotes, rules, and inline
   code/bold/italic/strike/links. Everything is HTML-escaped FIRST, then marked up, so agent output
   (which contains arbitrary text) can never inject markup. */
function md(src){
  if(!src) return '';
  const parts=String(src).split('```');
  let out='';
  for(let i=0;i<parts.length;i++){
    if(i%2===1){                                  // inside a fence
      const seg=parts[i], nl=seg.indexOf('\n');
      const lang=nl>=0?seg.slice(0,nl).trim():'';
      const code=nl>=0?seg.slice(nl+1):seg;
      out+='<pre class="code">'+(lang?'<i class="lang">'+esc(lang)+'</i>':'')+
           esc(code.replace(/\n+$/,''))+'</pre>';
    } else out+=mdBlocks(parts[i]);
  }
  return out;
}
function mdBlocks(t){
  const lines=String(t).split('\n');
  let html='', para=[], list=null, tbl=[];
  const flushPara=()=>{ if(para.length){ html+='<p>'+mdSpans(esc(para.join('\n'))).replace(/\n/g,'<br>')+'</p>'; para=[]; } };
  const closeList=()=>{ if(list){ html+='</'+list+'>'; list=null; } };
  const flushTable=()=>{
    if(!tbl.length) return;
    const rows=tbl.filter(r=>!/^[\s|:-]+$/.test(r));   // drop the |---|---| separator
    html+='<table>';
    rows.forEach((r,ri)=>{
      const cells=r.replace(/^\||\|$/g,'').split('|').map(c=>mdSpans(esc(c.trim())));
      const tag=ri===0?'th':'td';
      html+='<tr>'+cells.map(c=>'<'+tag+'>'+c+'</'+tag+'>').join('')+'</tr>';
    });
    html+='</table>'; tbl=[];
  };
  for(const line of lines){
    const s=line.trim();
    if(s.startsWith('|')&&s.endsWith('|')&&s.length>2){ flushPara(); closeList(); tbl.push(s); continue; }
    flushTable();
    if(!s){ flushPara(); closeList(); continue; }
    let m;
    if(m=s.match(/^(#{1,6})\s+(.*)$/)){ flushPara(); closeList();
      const lv=Math.min(3,m[1].length); html+='<h'+lv+'>'+mdSpans(esc(m[2]))+'</h'+lv+'>'; continue; }
    if(/^([-*_])\1{2,}$/.test(s)){ flushPara(); closeList(); html+='<hr>'; continue; }
    if(m=s.match(/^>\s?(.*)$/)){ flushPara(); closeList(); html+='<blockquote>'+mdSpans(esc(m[1]))+'</blockquote>'; continue; }
    if(m=s.match(/^[-*+]\s+(.*)$/)){ flushPara();
      if(list!=='ul'){ closeList(); html+='<ul>'; list='ul'; }
      html+='<li>'+mdSpans(esc(m[1]))+'</li>'; continue; }
    if(m=s.match(/^\d+[.)]\s+(.*)$/)){ flushPara();
      if(list!=='ol'){ closeList(); html+='<ol>'; list='ol'; }
      html+='<li>'+mdSpans(esc(m[1]))+'</li>'; continue; }
    closeList(); para.push(line);
  }
  flushTable(); flushPara(); closeList();
  return html;
}
/* Inline spans. Input is already escaped; inline code is pulled out first so its contents
   are never re-interpreted as markdown. */
function mdSpans(s){
  const code=[];
  s=s.replace(/`([^`]+)`/g,(m,c)=>{ code.push(c); return '\u0001'+(code.length-1)+'\u0001'; });
  s=s.replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>');
  s=s.replace(/(^|[^*\w])\*([^*\n]+)\*/g,'$1<i>$2</i>');
  s=s.replace(/~~([^~\n]+)~~/g,'<s>$1</s>');
  s=s.replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s.replace(/\u0001(\d+)\u0001/g,(m,i)=>'<code>'+code[i]+'</code>');
}

/* ---------- code diff ----------
   LCS line diff (same idea as Happy's calculateDiff, minus the npm dep), rendered unified with
   long unchanged runs collapsed. */
function lcsDiff(a,b){
  const n=a.length,m=b.length;
  if(n*m>200000) return null;                        // too large — caller falls back
  const dp=[]; for(let i=0;i<=n;i++) dp.push(new Uint16Array(m+1));
  for(let i=n-1;i>=0;i--) for(let j=m-1;j>=0;j--)
    dp[i][j]= a[i]===b[j] ? dp[i+1][j+1]+1 : Math.max(dp[i+1][j],dp[i][j+1]);
  const out=[]; let i=0,j=0;
  while(i<n&&j<m){
    if(a[i]===b[j]){ out.push([' ',a[i]]); i++; j++; }
    else if(dp[i+1][j]>=dp[i][j+1]){ out.push(['-',a[i]]); i++; }
    else { out.push(['+',b[j]]); j++; }
  }
  while(i<n) out.push(['-',a[i++]]);
  while(j<m) out.push(['+',b[j++]]);
  return out;
}
function diffRows(rows){
  const keep=new Array(rows.length).fill(false);
  rows.forEach((r,i)=>{ if(r[0]!==' ') for(let k=Math.max(0,i-2);k<=Math.min(rows.length-1,i+2);k++) keep[k]=true; });
  let html='',add=0,del=0,gap=0;
  rows.forEach((r,i)=>{
    if(r[0]==='+') add++; else if(r[0]==='-') del++;
    if(!keep[i]){ gap++; return; }
    if(gap){ html+='<div class="dgap">⋯ '+gap+' unchanged</div>'; gap=0; }
    const cls=r[0]==='+'?'add':(r[0]==='-'?'del':'ctx');
    html+='<div class="dl '+cls+'">'+esc(r[0]+' '+r[1])+'</div>';
  });
  if(gap) html+='<div class="dgap">⋯ '+gap+' unchanged</div>';
  return {html:html,add:add,del:del};
}
function diffHTML(edits){
  let body='',add=0,del=0;
  edits.forEach((e,idx)=>{
    const a=e.old?e.old.split('\n'):[], b=e.new?e.new.split('\n'):[];
    let rows=lcsDiff(a,b);
    if(!rows) rows=a.map(l=>['-',l]).concat(b.map(l=>['+',l]));
    const r=diffRows(rows); add+=r.add; del+=r.del;
    body+=(edits.length>1?'<div class="dhead">edit '+(idx+1)+'</div>':'')+r.html;
  });
  return {html:'<div class="diff">'+body+'</div>',add:add,del:del};
}
/* codex apply_patch already ships a patch — just colourise it */
function patchHTML(p){
  let html='',add=0,del=0;
  String(p).split('\n').forEach(l=>{
    let cls='ctx';
    if(l.startsWith('***')||l.startsWith('@@')) cls='ph';
    else if(l.startsWith('+')){ cls='add'; add++; }
    else if(l.startsWith('-')){ cls='del'; del++; }
    html+='<div class="dl '+cls+'">'+esc(l||' ')+'</div>';
  });
  return {html:'<div class="diff">'+html+'</div>',add:add,del:del};
}
function statHTML(d){
  return '<span class="dstat">'+(d.add?'<span class="a">+'+d.add+'</span> ':'')+
         (d.del?'<span class="d">-'+d.del+'</span>':'')+'</span>';
}

// Tool/thinking cards expand on tap — one delegated listener, so re-rendering can't lose handlers.
document.getElementById('chat').addEventListener('click',e=>{
  if(e.target.dataset&&e.target.dataset.copy){          // "copy" on a message
    const msg=e.target.closest('.msg'), t=msg?msg.querySelector('.mtext'):null;
    if(t)copyText(t.innerText||t.textContent||'');
    return;
  }
  const card=e.target.closest?e.target.closest('.msg.tool,.msg.think'):null;
  if(card)card.classList.toggle('open');
});
/* Purpose-built views for the tools that carry a decision or a plan — these are exactly the
   moments the agent is waiting on you, and raw JSON is useless on a phone. */
function toolView(m){
  if(!m.detail) return null;
  let d; try{ d=JSON.parse(m.detail); }catch(e){ return null; }
  if(m.tool==='TodoWrite'&&Array.isArray(d.todos)){
    return '<div class="todo">'+d.todos.map(t=>{
      const s=t.status||'';
      const cls=s==='completed'?'d':(s==='in_progress'?'p':'');
      const box=s==='completed'?'☑':(s==='in_progress'?'▸':'☐');
      return '<div class="'+cls+'">'+box+' '+esc(t.activeForm&&s==='in_progress'?t.activeForm:(t.content||''))+'</div>';
    }).join('')+'</div>';
  }
  if(m.tool==='ExitPlanMode'&&d.plan) return '<div class="mtext md">'+md(d.plan)+'</div>';
  if(m.tool==='AskUserQuestion'&&Array.isArray(d.questions)){
    return '<div class="qopts">'+d.questions.map(q=>
      '<div class="qq">'+esc(q.question||q.header||'')+'</div>'+
      (Array.isArray(q.options)?q.options.map(o=>'<div class="qo">• '+esc(o.label||o)+'</div>').join(''):'')
    ).join('')+'</div>';
  }
  if(m.tool==='Task'&&d.prompt)
    return '<b>subagent</b><div>'+esc(d.description||'')+'</div><div class="mtext md">'+md(d.prompt)+'</div>';
  return null;
}
/* Stable-ish identity for a message, so an expanded card stays expanded across refreshes. */
function msgKey(m){
  const s=(m.kind||'')+'|'+(m.tool||'')+'|'+(m.ts||'')+'|'+(m.text||'').slice(0,40);
  let h=0; for(let i=0;i<s.length;i++){ h=(h*31+s.charCodeAt(i))|0; }
  return 'k'+(h>>>0).toString(36);
}
function msgHTML(m){
  if(m.kind==='thinking')
    return '<div class="msg think" data-k="'+msgKey(m)+'">'+
      '<div class="mhead">💭<span class="sum">thinking</span></div><div class="mtext">'+esc(m.text)+'</div></div>';
  if(m.kind==='tool'){
    // Tools whose payload IS the content get a purpose-built view; edits get a diff;
    // everything else falls back to input/output.
    let d=null, special=toolView(m);
    if(!special){
      if(m.edits&&m.edits.length) d=diffHTML(m.edits);
      else if(m.patch) d=patchHTML(m.patch);
    }
    const det=special ? special : (d ? d.html
      : (m.detail?'<b>input</b><div>'+esc(m.detail)+'</div>':'')+
        (m.output?'<b>output</b><div>'+esc(m.output)+'</div>':''));
    return '<div class="msg tool'+(m.ok===false?' bad':'')+(m.pending?' run':'')+'" data-k="'+msgKey(m)+'">'+
      '<div class="mhead">'+(m.pending?'<span class="spin"></span>':'<span>'+(TOOLICON[m.cat]||'•')+'</span>')+
      '<b>'+esc(m.tool||'')+'</b><span class="sum">'+esc(m.text)+'</span>'+(d?statHTML(d):'')+
      (m.pending?'<span class="when">'+since(m.ts)+'</span>':'')+
      (m.ok===false?'<span style="color:var(--red)">✕</span>':'')+'</div>'+
      (det?'<div class="mbody">'+det+'</div>':'')+'</div>';
  }
  return '<div class="msg '+(m.role==='user'?'user':'asst')+(m.sub?' sub':'')+(m.queued?' queued':'')+'">'+
    '<span class="cp" data-copy="1">copy</span>'+
    (m.sub?'<div class="tag">subagent</div>':'')+
    (m.ts?'<span class="when">'+hhmm(m.ts)+'</span>':'')+
    '<div class="mtext md">'+md(m.text)+'</div></div>';
}
/* The tail of the conversation says what the agent is doing right now — a chat that simply stops
   updating looks identical whether it is thinking, blocked, or finished. */
function runBarHTML(){
  const i=curInfo||{};
  if(i.status==='working')
    return '<div class="runbar"><span class="spin"></span><b>running</b>'+
           (i.pendingTool?'<span class="what">'+esc(i.pendingTool)+
             (i.pendingText?' · '+esc(i.pendingText):'')+'</span>':'')+'</div>';
  if(i.status==='needsYou' && !(i.options&&i.options.length))
    return '<div class="runbar wait"><b>waiting for you</b>'+
           '<span class="what">switch to Terminal to answer</span></div>';
  return '';
}
function renderChat(msgs,note){
  const el=document.getElementById('chat');
  if(!msgs.length){el.innerHTML='<div id="chatnote">'+esc(note||'No conversation yet — send a prompt to start.')+'</div>';return;}
  const last=msgs[msgs.length-1]||{};
  const st=curInfo||{};
  const sig=msgs.length+':'+(last.text||'').length+':'+(last.output||'').length+
            ':'+(st.status||'')+':'+(st.pendingText||'');
  if(el.dataset.sig===sig)return;      // unchanged → don't rebuild at all
  const nearBottom=stickBottom||el.scrollHeight-el.scrollTop-el.clientHeight<120;
  // Remember which cards the user expanded and restore them after the rebuild — otherwise reading a
  // long tool output is impossible. Keyed by content, not position: messages get appended and old
  // ones drop off the front, so any index-based anchor drifts.
  const open=new Set();
  Array.prototype.forEach.call(el.querySelectorAll('.msg.open'),n=>{ if(n.dataset.k) open.add(n.dataset.k); });
  el.dataset.sig=sig;
  el.innerHTML=msgs.map(msgHTML).join('')+runBarHTML();
  if(open.size) Array.prototype.forEach.call(el.querySelectorAll('.msg'),n=>{
    if(n.dataset.k&&open.has(n.dataset.k)) n.classList.add('open');
  });
  reconcileSent(el);
  if(flyNext){                       // only when the conversation is first put on screen
    flyNext=false;
    const all=el.querySelectorAll('.msg'), n=all.length, from=Math.max(0,n-8);
    for(let i=from;i<n;i++){ all[i].classList.add('fly');
      all[i].style.animationDelay=((i-from)*46)+'ms'; }
  }
  if(nearBottom){el.scrollTop=el.scrollHeight;stickBottom=false;}
  updateStickyPrompt();
}
async function key(k){if(!curId)return;try{await fetch('/key?id='+curId+'&k='+encodeURIComponent(k));}catch(e){}}
async function scrollTerm(dir){if(!curId)return;try{await fetch('/scroll?id='+curId+'&dir='+dir);}catch(e){}}

// ---------- quick-command list — synced from the desktop Notes ----------
let presetEdit=false;
async function refreshState(){try{const r=await fetch('/state',{cache:'no-store'});state=await r.json();}catch(e){}}
function renderPresets(){
  const all=(state&&state.notes)||[];
  // Substring filter — the Notes list doubles as a command palette and gets long.
  const q=(document.getElementById('pfind').value||'').trim().toLowerCase();
  const notes=q?all.filter(n=>(n.text||'').toLowerCase().includes(q)):all;
  let html=notes.map((n,i)=>presetEdit
    ?`<button class="del" onclick="delNote('${n.id}')">✕ ${esc(n.text)}</button>`
    :`<button onclick="usePreset('${n.id}')" title="${esc(n.text)}">${esc(n.text)}</button>`).join('');
  if(!notes.length) html+='<span style="color:var(--sub);font-size:12px;align-self:center;white-space:nowrap">'+
    (q?'no match':'No commands — tap ＋, or add Notes on the Mac')+'</span>';
  html+=`<button class="meta" onclick="addNote()">＋</button>`
      +`<button class="meta" onclick="toggleEditPresets()">${presetEdit?'Done':'✎'}</button>`;
  document.getElementById('presets').innerHTML=html;
}
function usePreset(id){
  const n=((state&&state.notes)||[]).find(x=>x.id===id); if(!n)return;
  const ta=document.getElementById('inputtext');ta.value=n.text;
  ta.style.height='auto';ta.style.height=Math.min(120,ta.scrollHeight)+'px';ta.focus();
  syncSendBtn();
}
async function addNote(){const c=prompt('Add a quick command (saved to Notes on the Mac)');
  if(c&&c.trim()){await fetch('/note?add='+encodeURIComponent(c.trim()));await refreshState();renderPresets();}}
async function delNote(id){await fetch('/note?del='+encodeURIComponent(id));await refreshState();renderPresets();}
function toggleEditPresets(){presetEdit=!presetEdit;renderPresets();}
renderPresets();
async function sendText(){
  if(!curId)return;
  const ta=document.getElementById('inputtext');const t=ta.value;
  /* An empty box while the agent works means Stop; anything you typed is a message, always. The
     button label can be a poll behind the terminal, and letting it decide here meant a typed
     message interrupted the turn instead of sending — so it took two taps. */
  if(!t){ key(document.getElementById('sendbtn').dataset.stop?'Escape':'Enter'); return; }
  ta.value='';ta.style.height='auto';
  showSent(t);                       // don't wait a round trip to acknowledge the send
  stickBottom=true; jumpLatest();    // follow your own message down, wherever you were reading
  markSent();                       // the hook is a beat behind; don't sit on 'idle' meanwhile
  try{ await fetch('/type?id='+encodeURIComponent(curId)+'&enter=1&text='+encodeURIComponent(t)); }
  catch(e){ ta.value=t; sentAt=0; renderInfo(curInfo);
            if(sentGhost){ sentGhost.node.remove(); sentGhost=null; } }
  setTimeout(loadChat,400);
}
/* The message needs a beat or two to reach the transcript, and a send that shows nothing reads as a
   send that failed. Put the card on screen immediately and keep it until the real one turns up. */
let sentGhost=null;
const flatText=s=>s.replace(/\s+/g,' ').trim();
function showSent(text){
  const el=document.getElementById('chat');
  if(!el.classList.contains('on'))return;
  const d=document.createElement('div');
  d.className='msg user sending';
  d.innerHTML='<div class="mtext md">'+md(text)+'</div>';
  const bar=el.querySelector('.runbar');
  bar?el.insertBefore(d,bar):el.appendChild(d);
  sentGhost={text:flatText(text),node:d};
}
/* Called after every rebuild: hand the animation over to the real card once it exists, and keep the
   stand-in on screen until then. */
function reconcileSent(el){
  if(!sentGhost)return;
  const users=el.querySelectorAll('.msg.user .mtext');
  const last=users.length?users[users.length-1]:null;
  if(last&&flatText(last.innerText||last.textContent||'')===sentGhost.text){
    last.parentNode.classList.add('sending');
    sentGhost=null;
    return;
  }
  const bar=el.querySelector('.runbar');
  bar?el.insertBefore(sentGhost.node,bar):el.appendChild(sentGhost.node);
}
/* Show 'running' the moment a prompt goes out, and hold it briefly: the status comes from a hook
   that fires a little after the keystrokes land, so an immediate poll still reports idle. */
function markSent(){ sentAt=performance.now(); curInfo.status='working'; renderInfo(curInfo); syncSendBtn(); }
/* Tapping Send blurs the textarea; the keyboard collapses, the bar moves out from under the finger
   and the tap lands on nothing. Fire on the press instead, and swallow the click that follows. */
(function(){
  const sb=document.getElementById('sendbtn');
  /* Swallow the one click paired with a press we already handled — a time window would let a long
     press through, since its click arrives whenever the finger lifts. Expires so a press that never
     produces a click (dragged off the button) can't eat a later one. */
  let armed=0;
  sb.addEventListener('pointerdown',e=>{ if(e.button&&e.button!==0) return;
    e.preventDefault(); armed=performance.now(); sendText(); });
  sb.addEventListener('click',e=>{ e.preventDefault();
    if(armed&&performance.now()-armed<4000){ armed=0; return; }
    sendText(); });
})();
document.getElementById('inputtext').addEventListener('keydown',e=>{
  if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();sendText();}
});
document.getElementById('inputtext').addEventListener('input',e=>{e.target.style.height='auto';e.target.style.height=Math.min(120,e.target.scrollHeight)+'px';syncSendBtn();});

// ---------- create / actions ----------
async function newTerm(pid){try{await fetch('/new?projectId='+encodeURIComponent(pid));setTimeout(tick,300);}catch(e){}}
async function doAction(id,act,extra){
  let u='/action?id='+encodeURIComponent(id)+'&do='+act;
  if(extra)u+='&name='+encodeURIComponent(extra);
  try{await fetch(u);setTimeout(tick,200);}catch(e){}
}

// ---------- drag-to-act ----------
let drag={id:null,name:null,cluster:false,x:0,y:0,sx:0,sy:0,active:false,
          touch:false,armed:false,holdTimer:0};
function endDrag(){
  clearTimeout(drag.holdTimer);
  window.removeEventListener('pointermove',onMove);
  window.removeEventListener('pointerup',onUp);
  if(drag.card)drag.card.classList.remove('armed');
  drag.active=false;drag.armed=false;dragging=false;
  document.getElementById('chip').style.display='none';
  document.getElementById('dock').style.display='none';
}
function zonesFor(cluster,done){
  const z=[{k:'done',t:done?'Unmark':'✓ Mark'},{k:'duplicate',t:'⧉ Duplicate'},{k:'rename',t:'✎ Rename'}];
  if(cluster)z.push({k:'leaveCluster',t:'⇤ Leave'});
  z.push({k:'remove',t:'🗑 Remove',danger:true});
  return z;
}
function buildDock(cluster,done){
  const dock=document.getElementById('dock');
  dock.innerHTML=zonesFor(cluster,done).map(z=>`<div class="zone${z.danger?' danger':''}" data-zone="${z.k}">${z.t}</div>`).join('');
}
function zoneAt(x,y){
  for(const el of document.querySelectorAll('#dock .zone')){
    const r=el.getBoundingClientRect();
    if(x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom)return el;
  }return null;
}
function onDown(e){
  const card=e.target.closest('.card');if(!card)return;
  drag.id=card.dataset.id;drag.name=card.dataset.name;drag.cluster=card.dataset.cluster==='1';
  drag.done=card.dataset.done==='1';drag.canopen=card.dataset.canopen==='1';drag.card=card;
  drag.sx=e.clientX;drag.sy=e.clientY;drag.active=false;
  // A finger can't both scroll the list and drag a card, so touch has to say which it means:
  // hold still for a moment and the card arms for dragging, otherwise the swipe stays a scroll.
  drag.touch=e.pointerType==='touch';
  drag.armed=!drag.touch;
  clearTimeout(drag.holdTimer);
  if(drag.touch){
    drag.holdTimer=setTimeout(()=>{
      drag.armed=true;
      if(drag.card)drag.card.classList.add('armed');
      if(navigator.vibrate)navigator.vibrate(8);
    },220);
  }
  window.addEventListener('pointermove',onMove);
  window.addEventListener('pointerup',onUp);
}
function onMove(e){
  const dx=e.clientX-drag.sx,dy=e.clientY-drag.sy;
  // Moved before the hold completed → the user is scrolling; let the browser have the gesture.
  if(!drag.armed){
    if(Math.hypot(dx,dy)>12){ clearTimeout(drag.holdTimer); endDrag(); }
    return;
  }
  if(!drag.active&&Math.hypot(dx,dy)<9)return;
  if(!drag.active){
    drag.active=true;dragging=true;drag.card.classList.add('dragging');
    buildDock(drag.cluster,drag.done);
    document.getElementById('dock').style.display='flex';
    const chip=document.getElementById('chip');chip.textContent=drag.name;chip.style.display='block';
  }
  const chip=document.getElementById('chip');chip.style.left=e.clientX+'px';chip.style.top=e.clientY+'px';
  document.querySelectorAll('#dock .zone').forEach(z=>z.classList.remove('hot'));
  const hot=zoneAt(e.clientX,e.clientY);
  drag.hotAct=hot?hot.dataset.zone:null;   // remember target NOW; the dock is hidden before onUp reads it
  if(hot)hot.classList.add('hot');
}
function onUp(e){
  clearTimeout(drag.holdTimer);
  window.removeEventListener('pointermove',onMove);
  window.removeEventListener('pointerup',onUp);
  if(drag.card)drag.card.classList.remove('armed');
  const wasActive=drag.active;
  const act=wasActive?drag.hotAct:null;   // captured during onMove, while zones still had layout
  document.getElementById('chip').style.display='none';
  document.getElementById('dock').style.display='none';
  if(drag.card)drag.card.classList.remove('dragging');
  dragging=false;
  if(!wasActive){ // a tap, not a drag
    if(drag.canopen)openTerm(drag.id,drag.name);else toast('Open this terminal on the Mac first');
    return;
  }
  if(!act)return;
  if(act==='rename'){const n=prompt('Rename terminal',drag.name);if(n)doAction(drag.id,'rename',n);}
  else doAction(drag.id,act);
}
document.getElementById('root').addEventListener('pointerdown',onDown);
// Non-passive: touch-action is evaluated when the gesture begins, so the only way to stop a scroll
// that a long press has turned into a drag is to cancel the touch moves themselves.
document.addEventListener('touchmove',e=>{ if(drag.armed&&drag.active)e.preventDefault(); },
                          {passive:false});

let toastT=null;
function toast(msg){
  let t=document.getElementById('toast');
  if(!t){t=document.createElement('div');t.id='toast';
    t.style.cssText='position:fixed;left:50%;bottom:70px;transform:translateX(-50%);z-index:70;background:var(--card);border:1px solid var(--stroke);color:var(--text);padding:9px 14px;border-radius:10px;font-size:13px;box-shadow:0 6px 20px rgba(0,0,0,.5)';
    document.body.appendChild(t);}
  t.textContent=msg;t.style.opacity='1';
  clearTimeout(toastT);toastT=setTimeout(()=>{t.style.opacity='0';},1600);
}

// ---------- render ----------
function card(t){
  const locked=!t.canOpen;
  const sig=t.status==='shell'?'$':'›';
  const agent=t.agent?`<span class="agent" style="color:${t.agent==='codex'?'var(--codex)':'var(--claude)'};background:${t.agent==='codex'?'rgba(102,204,217,.16)':'rgba(230,148,89,.16)'}">${t.agent}</span>`:'';
  const tok=t.tokens>0?`<span style="font-size:10px;color:var(--accent);margin-left:5px">${short(t.tokens)} tok</span>`:'';
  const dn=t.done?'✓ ':'';
  return `<div class="card ${locked?'locked':''} ${t.done?'done':''}" data-id="${t.id}" data-name="${esc(t.name)}" data-cluster="${t.clusterId?'1':'0'}" data-canopen="${t.canOpen?'1':'0'}" data-done="${t.done?'1':'0'}">
    <div class="cardtop">
      <span class="dot" style="background:${COLORS[t.status]||COLORS.closed}"></span>
      <span class="name">${dn}${esc(t.name)}</span>${agent}
      <span class="status" style="color:${COLORS[t.status]||COLORS.closed}">${esc(t.statusLabel)}${tok}</span>
    </div>
    <div class="prompt"><span class="sig">${sig}</span><span class="txt">${t.prompt?esc(t.prompt):'—'}</span></div>
    ${t.idle>=0?`<div class="ago">${ago(t.idle)}</div>`:''}
  </div>`;
}
function render(s){
  const cnt=document.getElementById('counts');
  const cntText=`${s.projects.length} project${s.projects.length===1?'':'s'} · ${s.terminals.length} terminal${s.terminals.length===1?'':'s'}`;
  if(cnt.textContent!==cntText) cnt.textContent=cntText;
  let pills='';
  if(s.working>0)pills+=`<span class="pill" style="color:var(--green);background:rgba(92,209,140,.18)">${s.working} working</span> `;
  if(s.needs>0)pills+=`<span class="pill" style="color:var(--amber);background:rgba(250,184,82,.18)">${s.needs} needs you</span>`;
  const pillEl=document.getElementById('pills');
  if(pillEl.innerHTML!==pills) pillEl.innerHTML=pills;
  let html='';
  if(!s.remoteOK)html+=`<div class="banner">Web terminals are disabled — run <b>${esc(s.remoteHint)}</b> and relaunch FleetView. Status is still shown.</div>`;
  for(const p of s.projects){
    const terms=s.terminals.filter(t=>t.projectId===p.id);
    const tot=terms.reduce((a,t)=>a+t.tokens,0);
    html+=`<div class="proj"><div class="projhead"><span class="name">${esc(p.name)}</span>`+
      `<span class="count">${terms.length}</span>`+(tot>0?`<span class="tok">Σ ${short(tot)}</span>`:'')+
      `<button class="addbtn" onclick="newTerm('${p.id}')">+ Terminal</button></div>`;
    const cids=[...new Set(terms.filter(t=>t.clusterId).map(t=>t.clusterId))];
    for(const cid of cids){
      const c=s.clusters.find(x=>x.id===cid);const mem=terms.filter(t=>t.clusterId===cid);
      html+=`<div class="cluster"><div class="chead"><span class="clabel">CLUSTER</span><span class="cname">${esc(c?c.name:'')}</span><span class="muted" style="margin-left:8px">· ${mem.length}</span></div><div class="grid">${mem.map(card).join('')}</div></div>`;
    }
    const solo=terms.filter(t=>!t.clusterId);
    if(solo.length)html+=`<div class="grid">${solo.map(card).join('')}</div>`;
    html+='</div>';
  }
  // Every 1.5s this used to replace the whole board, which forces a layout in the middle of a
  // flick and shows up as a stall at the end of a scroll. Almost every tick is identical, so the
  // rebuild only happens when the markup actually differs.
  const out=html||'<div class="empty">No projects yet. Add one on the Mac.</div>';
  const root=document.getElementById('root');
  if(out!==lastBoard){ lastBoard=out; root.innerHTML=out; }
}
let lastBoard='';

async function tick(){
  if(dragging||termOpen())return;
  try{
    const r=await fetch('/state',{cache:'no-store'});state=await r.json();render(state);
    reportLocation(state);   // once per browser; no-op until the page is served over HTTPS
    document.getElementById('refresh').textContent='updated '+new Date().toLocaleTimeString();
  }catch(e){document.getElementById('refresh').textContent='offline — retrying…';}
}
tick();setInterval(tick,1500);

// ---------- agent-authored dynamic panel (top region) ----------
let panelMtime=-1;
function togglePanel(){
  const el=document.getElementById('panel');el.classList.toggle('min');
  el.querySelector('.pcollapse').textContent=el.classList.contains('min')?'▸ show':'▾ hide';
}
async function pollPanel(){
  try{
    const m=await (await fetch('/panel-meta',{cache:'no-store'})).json();
    const el=document.getElementById('panel');
    if(m.exists){
      el.classList.add('show');
      /* Reload on the archived version's uuid, not on mtime: touching the file is not a new panel. */
      const token=m.uuid||m.mtime;
      if(token!==panelMtime){panelMtime=token;document.getElementById('panelframe').src='/panel?t='+encodeURIComponent(token);}
    }else{el.classList.remove('show');panelMtime=-1;}
  }catch(e){}
}
pollPanel();setInterval(pollPanel,1500);
</script>
</body>
</html>
"""#
}
