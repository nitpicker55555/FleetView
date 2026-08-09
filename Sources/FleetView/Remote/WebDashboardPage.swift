import Foundation

/// The single self-contained HTML page served at `/`. It polls `/state` for live data, renders the
/// same projects/terminals/status the desktop shows, lets you drag a card onto an action zone
/// (done / duplicate / rename / leave / remove), add terminals, open one full-screen in an iframe
/// (ttyd), and walk a project's own directory (`/browse`, `/read`). A native input bar sends text via
/// tmux `send-keys` so CJK/IME input works where xterm.js falls short; it pulls up into a full editor
/// when a prompt deserves one. No external assets — everything is inline so it works offline on the LAN.
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
  /* Dark is the default, and these are the same values the desktop app's Theme uses, so the two
     palettes can be compared line by line. `html.light` below is the other appearance; which one is
     applied follows the Mac (state.dark) until this browser says otherwise — see `applyScheme`. */
  :root{
    --bg:#14171c; --panel:#1c1f25; --card:#25282f; --cardHover:#2e3039;
    --stroke:rgba(255,255,255,.08); --text:#ebedf2; --sub:#99a1b0; --accent:#7a9eff;
    --green:#5cd18c; --teal:#4dadc2; --gray:#8c93a3; --amber:#fab852; --red:#d96b73;
    --claude:#e69459; --codex:#66ccd9;
    /* Foreground for anything sitting ON --accent. Was #0b1020 in ten places, which meant the
       light theme's darker blue would have carried near-black text. */
    --onAccent:#0b1020;
    /* Your own words are a raised layer over the conversation — inverted glass, so on a dark page
       that is white with dark text, and on a light page the reverse. */
    --quoteBg:rgba(255,255,255,.86); --quoteFg:#15181d; --quoteEdge:rgba(255,255,255,.6);
    --markBg:#241d33; --markTint:#b58fe6;
    --quoteBgSoft:rgba(255,255,255,.78);
    --codeBg:#0e1116;
    /* An opaque surface, so it cannot be a wash of anything — it has to be stated per appearance or
       it stays whatever it was hard-coded to. This one is why the header stayed black. */
    --headerBg:rgba(28,31,37,.92);
    /* Tints and edges. Each is a wash of a palette hue, and the hue itself differs per appearance:
       the dark blue is #7a9eff and the light one #0969da, so a literal rgba() of the dark one is
       washed out on a light page even though it is "the same" colour. */
    --accentSoft:rgba(122,158,255,.13); --accentFaint:rgba(122,158,255,.055);
    --accentEdge:rgba(122,158,255,.28); --accentEdgeOn:rgba(122,158,255,.5);
    --amberSoft:rgba(250,184,82,.12);   --amberEdge:rgba(250,184,82,.34);
    --greenSoft:rgba(92,209,140,.12);   --greenEdge:rgba(92,209,140,.28); --greenFg:#9fe3bd;
    --redSoft:rgba(217,107,115,.14);    --redEdge:rgba(217,107,115,.45);  --redFg:#f0a8ad;
    /* Inline code outside the quote card, and the loading shimmer: both are a film of the opposite
       end, so both invert. */
    --codeInline:rgba(255,255,255,.08);
    --skel1:rgba(255,255,255,.05); --skel2:rgba(255,255,255,.11);
    --skelU1:rgba(255,255,255,.10); --skelU2:rgba(255,255,255,.20);
    /* Inside the quote card, which is itself inverted — light glass here, dark glass there — so its
       contents invert with it rather than with the page. */
    --quoteCode:rgba(0,0,0,.07); --quoteCodeFg:#12151a; --quoteLink:#1b4bd0;
    --quoteEdgeSoft:rgba(21,24,29,.28);
    --scheme:dark;
  }
  /* Light: GitHub Primer, which is built for dense text-heavy tool UI and whose semantic colours
     land on the status dots already in use — fg.default #1f2328, fg.muted #59636e,
     border.default #d1d9e0, accent.fg #0969da, success #1a7f37, attention #9a6700, danger #d1242f.
     The surface stack inverts rather than the hues: a grey board, near-white panels, white cards. */
  html.light{
    --bg:#eef1f5; --panel:#f7f8fa; --card:#ffffff; --cardHover:#f1f3f6;
    --stroke:#d1d9e0; --text:#1f2328; --sub:#59636e; --accent:#0969da;
    --green:#1a7f37; --teal:#0e7490; --gray:#6e7781; --amber:#9a6700; --red:#d1242f;
    --claude:#bc4c00; --codex:#0e7490;
    --onAccent:#ffffff;
    --quoteBg:rgba(28,32,38,.92); --quoteFg:#f2f4f7; --quoteEdge:rgba(255,255,255,.10);
    --markBg:#f7f0ff; --markTint:#8250df;
    --quoteBgSoft:rgba(28,32,38,.82);
    --codeBg:#f6f8fa;
    --headerBg:rgba(247,248,250,.92);
    /* Dark-on-light reads stronger than light-on-dark at the same alpha, so the washes are lighter
       and the edges heavier — matching weight, not matching numbers. */
    --accentSoft:rgba(9,105,218,.10);   --accentFaint:rgba(9,105,218,.045);
    --accentEdge:rgba(9,105,218,.32);   --accentEdgeOn:rgba(9,105,218,.55);
    --amberSoft:rgba(154,103,0,.10);    --amberEdge:rgba(154,103,0,.38);
    --greenSoft:rgba(26,127,55,.10);    --greenEdge:rgba(26,127,55,.32);  --greenFg:#116329;
    --redSoft:rgba(209,36,47,.10);      --redEdge:rgba(209,36,47,.42);    --redFg:#a40e26;
    --codeInline:rgba(31,35,40,.07);
    --skel1:rgba(31,35,40,.05); --skel2:rgba(31,35,40,.11);
    --skelU1:rgba(255,255,255,.10); --skelU2:rgba(255,255,255,.20);
    --quoteCode:rgba(255,255,255,.10); --quoteCodeFg:#f2f4f7; --quoteLink:#9fc4ff;
    --quoteEdgeSoft:rgba(255,255,255,.22);
    --scheme:light;
  }
  /* Tells the browser to render form controls, scrollbars and the like to match. */
  :root{color-scheme:dark}
  html.light{color-scheme:light}
  *{box-sizing:border-box}
  html,body{margin:0;height:100%}
  /* Stops the rubber-band at the root, so a flick that the overlay did not consume cannot drag the
     page itself — the same class of movement the overlay's own overflow now prevents. */
  html{overscroll-behavior:none}
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
    padding:12px 16px;background:var(--headerBg);backdrop-filter:blur(8px);
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
  .projhead .tok{font-size:11px;font-weight:600;color:var(--accent);background:var(--accentSoft);padding:1px 7px;border-radius:999px}
  .addbtn{margin-left:auto;font-size:12px;font-weight:600;color:var(--accent);background:var(--accentSoft);
    border:1px solid var(--accentEdge);border-radius:7px;padding:5px 10px;cursor:pointer}
  .addbtn:active{transform:scale(.96)}
  .grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(280px,1fr))}
  /* "running now" — the same cards, tinted with the running colour so the strip reads as a state
     rather than as another project. */
  .runbox{padding:12px;border-radius:14px;background:rgba(92,209,140,.055);
    border:1px solid rgba(92,209,140,.22)}
  html.light .runbox{background:rgba(26,127,55,.06);border-color:rgba(26,127,55,.22)}
  .runbox .projhead{margin-bottom:10px}
  .rlabel{font-size:10px;font-weight:700;color:var(--green);letter-spacing:.04em}
  .rtag{font-size:10px;font-weight:500;color:var(--sub);opacity:.85;margin:0 0 4px 2px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
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
  /* Violet, and never a hard-coded near-black: this was #101c13, which stayed black on a light
     page. Matches the desktop card exactly. */
  .card.done{background:var(--markBg);border-color:var(--markTint)}
  .card.dragging{opacity:.35}
  .cardtop{display:flex;align-items:center;gap:9px}
  .cardtop .name{font-weight:600;font-size:14px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .agent{font-size:9px;font-weight:700;padding:1px 5px;border-radius:999px;text-transform:uppercase}
  .status{font-size:11px;font-weight:600}
  .prompt{font-size:12px;color:var(--sub);display:flex;gap:6px;min-height:32px}
  .prompt .sig{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:700;flex:none}
  .prompt .txt{overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
  .ago{font-size:10px;color:var(--sub);opacity:.75;text-align:right;margin-top:-3px}
  /* tabular-nums so a ticking clock doesn't shuffle the card's right edge every second */
  .run{color:var(--green);font-weight:600;font-variant-numeric:tabular-nums}
  /* The run is over: same figure, no longer green — the status label already says how it ended. */
  .run.done{color:var(--sub);opacity:.9}
  .cluster{border:1px solid var(--accentEdge);background:var(--accentFaint);border-radius:14px;padding:12px;margin-bottom:12px}
  .cluster .clabel{font-size:9px;font-weight:700;color:var(--accent);background:var(--accentSoft);padding:2px 6px;border-radius:999px;margin-right:6px}
  .cluster .chead{display:flex;align-items:center;margin-bottom:10px}
  .cluster .cname{font-weight:600;font-size:14px}
  .banner{background:var(--amberSoft);border:1px solid var(--amberEdge);color:var(--amber);padding:10px 12px;border-radius:10px;font-size:12px;margin-bottom:16px}
  .empty{color:var(--sub);text-align:center;padding:60px 20px}
  /* drag chip + action dock */
  #chip{position:fixed;z-index:60;pointer-events:none;display:none;background:var(--card);border:1px solid var(--accent);
    border-radius:9px;padding:7px 11px;font-size:13px;font-weight:600;box-shadow:0 8px 24px rgba(0,0,0,.5);transform:translate(-50%,-140%)}
  #dock{position:fixed;left:0;right:0;bottom:0;z-index:55;display:none;justify-content:center;gap:10px;flex-wrap:wrap;
    padding:16px;padding-bottom:max(16px,env(safe-area-inset-bottom));background:linear-gradient(transparent,rgba(0,0,0,.75) 45%)}
  .zone{min-width:88px;text-align:center;padding:14px 12px;border-radius:12px;font-size:13px;font-weight:600;
    background:var(--card);border:1px solid var(--stroke);color:var(--text)}
  .zone.hot{background:var(--accent);color:var(--onAccent);border-color:var(--accent);transform:scale(1.06)}
  .zone.danger{color:var(--red);border-color:var(--redEdge)}
  .zone.danger.hot{background:var(--red);color:#fff}
  /* terminal overlay */
  /* The height has been wrong in both directions, so it is worth saying what it is now.
     Measuring the visible viewport in JS left a gap: whenever the value lagged the browser chrome
     the overlay came up short and the dashboard showed through — and could be scrolled — underneath.
     Spanning the layout viewport with `inset:0` fixed that and introduced the opposite fault: on iOS
     Safari the layout viewport is TALLER than the screen for as long as the URL bar is showing, so
     the overlay hung off the bottom and that strip could be panned to. Dragging the composer
     scrolled a "full screen" page, and dismissing the keyboard left it parked mid-pan.
     `dvh` is the visible height with browser chrome already deducted, worked out by the browser
     rather than by us: exactly the screen, nothing to pan to, and no measurement to lag. The plain
     `height:100%` before it is the fallback for a browser without `dvh` (the layout-viewport
     behaviour). The keyboard is a separate axis and is still syncViewport's padding — `dvh` does not
     react to it. */
  /* `overflow:hidden` is the other half of the height, and its absence is why the overlay could
     still be dragged around after `dvh` made it the right size. This is a flex column whose
     siblings do not all shrink: #sinfo wraps to a second row as chips come and go, and #inputbar
     stacks presets, keys and the composer. When their combined height passes the viewport the box
     overflows, and an overflowing fixed element is pannable on iOS — which showed up as the title
     bar scrolling off the top and a gap opening underneath. Only #chat should ever give, and it
     already does (flex:1 with min-height:0); everything past that is clipped rather than reachable. */
  #term{position:fixed;top:0;left:0;right:0;height:100%;height:100dvh;
    z-index:50;background:var(--bg);
    display:none;flex-direction:column;overflow:hidden;overscroll-behavior:none}
  /* Belt and braces for the fallback path, where the overlay can still be shorter than the screen. */
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
  /* Shown instead of the blank iframe when its port doesn't answer. A white rectangle is the one
     thing this must never be: it says nothing, and it looks identical to a page still loading. */
  #termerr{display:none;flex:1;align-items:center;justify-content:center;padding:24px;background:var(--bg)}
  #termerr.on{display:flex}
  #termerr .te{max-width:420px;text-align:center;display:flex;flex-direction:column;gap:10px}
  #termerr .te b{font-size:14px;color:var(--text)}
  #termerr .te span{font-size:12px;color:var(--sub);line-height:1.5}
  #termerr .te button{align-self:center;background:var(--accent);color:var(--onAccent);border:0;
    border-radius:9px;padding:9px 18px;font-size:13px;font-weight:700;cursor:pointer}
  /* view switch */
  #tabs{display:flex;gap:2px;background:var(--card);border:1px solid var(--stroke);border-radius:8px;padding:2px}
  #tabs button{background:transparent;border:0;color:var(--sub);border-radius:6px;padding:5px 11px;font-size:12px;font-weight:600;cursor:pointer}
  #tabs button.on{background:var(--accent);color:var(--onAccent)}
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
    font-size:14px;line-height:1.5;font-weight:500;color:var(--quoteFg);
    background:var(--quoteBg);
    -webkit-backdrop-filter:blur(30px) saturate(140%);backdrop-filter:blur(30px) saturate(140%);
    border:1px solid var(--quoteEdge);
    box-shadow:0 12px 30px rgba(0,0,0,.45);
    display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
  .msg .mtext{white-space:pre-wrap;word-break:break-word}
  .msg.user{margin-top:26px}                 /* a new question needs a visible break before it */
  .msg.user:first-child{margin-top:0}
  /* Same white card as #stickyq: that bar is a quotation of one of these, so they have to read as
     the same object. Inline code and links need their own colours on a light ground. */
  .msg.user .mtext{background:var(--quoteBg);color:var(--quoteFg);
    padding:12px 15px;border-radius:12px;font-size:14px;line-height:1.55;
    border:1px solid var(--quoteEdge);box-shadow:0 6px 16px rgba(0,0,0,.32)}
  .msg.user .mtext code{background:var(--quoteCode);color:var(--quoteCodeFg)}
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
  .msg.user .mtext a{color:var(--quoteLink)}
  .msg.asst .mtext{color:var(--text);padding:0 2px}
  .msg.sub{opacity:.72}
  .msg .tag{font-size:9px;font-weight:700;color:var(--accent);text-transform:uppercase;margin-bottom:2px}
  /* typed while the agent was working: the same card, just drawn with a broken edge */
  .msg.user.queued .mtext{background:var(--quoteBgSoft);
    border-style:dashed;border-color:var(--quoteEdgeSoft)}
  .msg.think,.msg.tool{background:var(--card);border:1px solid var(--stroke);border-radius:10px;
    padding:10px 12px;cursor:pointer;margin-left:10px}
  .msg.think{opacity:.7}
  .msg.tool.bad{border-color:var(--redEdge)}
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
    background:linear-gradient(90deg,var(--skel1),var(--skel2),var(--skel1));
    background-size:220% 100%;animation:shim 1.2s linear infinite}
  .skel .sk-user .row{height:44px;border-radius:12px;
    background:linear-gradient(90deg,var(--skelU1),var(--skelU2),var(--skelU1));
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
  .md code{background:var(--codeInline);padding:1px 4px;border-radius:4px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px}
  .md pre.code{background:var(--codeBg);border:1px solid var(--stroke);border-radius:8px;padding:9px 10px;
    margin:8px 0;overflow-x:auto;white-space:pre;position:relative;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;line-height:1.45}
  .md pre.code i.lang{position:absolute;right:8px;top:3px;font-style:normal;font-size:9px;
    color:var(--sub);text-transform:uppercase;letter-spacing:.04em}
  .md table{border-collapse:collapse;margin:8px 0;font-size:12px;display:block;overflow-x:auto}
  .md th,.md td{border:1px solid var(--stroke);padding:4px 8px;text-align:left}
  .md th{background:var(--card);font-weight:600}
  /* code diff (Edit / MultiEdit / Write / codex apply_patch) */
  .diff{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;line-height:1.5;
    overflow-x:auto;border-radius:6px;background:var(--codeBg);padding:6px 0;margin-top:7px}
  .dl{white-space:pre;padding:0 10px}
  .dl.add{background:var(--greenSoft);color:var(--greenFg)}
  .dl.del{background:var(--redSoft);color:var(--redFg)}
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
  #sinfo .chip.warn{color:var(--amber);border-color:var(--amberEdge)}
  #sinfo .chip.danger{color:var(--red);border-color:var(--redEdge)}
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
    background:var(--greenSoft);border:1px solid var(--greenEdge);border-radius:10px;
    font-size:12px;color:var(--green)}
  .runbar .what{color:var(--sub);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .runbar.wait{background:var(--amberSoft);border-color:var(--amberEdge);color:var(--amber)}
  /* a tool still running (no result yet) */
  .msg.tool.run{border-color:var(--accentEdgeOn)}
  .spin{display:inline-block;width:9px;height:9px;border:1.5px solid var(--accent);border-right-color:transparent;
    border-radius:50%;animation:sp .7s linear infinite;flex:none}
  @keyframes sp{to{transform:rotate(360deg)}}
  .msg .when{font-size:9px;color:var(--sub);opacity:.55;margin-left:6px;font-weight:400}
  .msg .cp{font-size:9px;color:var(--sub);opacity:.45;cursor:pointer;padding:0 5px;float:right}
  .msg .cp:active{opacity:1;color:var(--accent)}
  /* permission / question card */
  #perm{display:none;background:var(--amberSoft);border-top:1px solid rgba(250,184,82,.4);padding:10px 12px}
  #perm.on{display:block}
  #perm .q{font-size:12px;font-weight:600;color:var(--amber);margin-bottom:8px}
  #perm .what{font-size:11px;color:var(--sub);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    margin-bottom:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #perm .opts{display:flex;flex-direction:column;gap:6px}
  #perm button{text-align:left;background:var(--card);color:var(--text);border:1px solid var(--stroke);
    border-radius:8px;padding:9px 11px;font-size:13px;cursor:pointer}
  #perm button:active{background:var(--accent);color:var(--onAccent)}
  /* todo / plan / question tool views */
  .todo{margin-top:7px}
  .todo div{padding:2px 0;font-size:12px;line-height:1.45}
  .todo .d{color:var(--sub);text-decoration:line-through}
  .todo .p{color:var(--accent);font-weight:600}
  .qopts{margin-top:6px}
  .qopts .qq{font-size:12px;font-weight:600;margin:6px 0 3px}
  .qopts .qo{font-size:12px;color:var(--sub);padding:1px 0 1px 14px}
  /* jump to latest */
  #jump{position:absolute;right:14px;bottom:96px;z-index:6;background:var(--accent);color:var(--onAccent);border:0;
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
  #presets button:active{background:var(--accent);color:var(--onAccent)}
  #presets button.meta{color:var(--accent);font-family:inherit;font-weight:600}
  #presets button.del{color:var(--red);border-color:var(--redEdge);font-family:inherit}
  #keys{display:flex;gap:6px;overflow-x:auto;margin-bottom:8px}
  #keys button{flex:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:7px;padding:6px 10px;font-size:12px;font-weight:600;cursor:pointer}
  #keys button:active{background:var(--accent);color:var(--onAccent)}
  /* The key row exists to drive a TUI: scrolling a pane, arrowing through a menu, ^C, backspace.
     Chat has none of that — it scrolls natively, answers prompts with real buttons, and stops the
     agent with the Send/Stop button — so the whole row goes away there. */
  #keys.chatview{display:none}
  #sendrow{display:flex;gap:8px;align-items:flex-end}
  #inputtext{flex:1;resize:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:10px;
    padding:10px 12px;font:14px/1.35 inherit;max-height:120px}
  #sendbtn{flex:none;background:var(--accent);color:var(--onAccent);border:0;border-radius:10px;padding:11px 16px;font-size:14px;font-weight:700;cursor:pointer}
  #imgbtn{flex:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:10px;
    padding:10px 12px;font-size:16px;line-height:1;cursor:pointer}
  #imgbtn:active{background:var(--accent);color:var(--onAccent)}
  #imgbtn[disabled]{opacity:.5}
  /* The composer can be pulled up into a proper editor. Writing anything longer than a sentence
     through a three-line slot means never seeing what you wrote, which is the whole reason the
     phone loses to the Mac for a considered prompt. */
  #grip{position:relative;height:16px;display:flex;align-items:center;justify-content:center;
    margin-bottom:2px;cursor:ns-resize;touch-action:none}
  #grip .gbar{width:46px;height:4px;border-radius:999px;background:var(--stroke)}
  #grip .gtools{position:absolute;right:0;top:-1px;display:flex;gap:5px}
  #grip .gtools button{background:var(--card);color:var(--sub);border:1px solid var(--stroke);
    border-radius:6px;font-size:11px;font-weight:700;line-height:1;padding:3px 7px;cursor:pointer;
    font-family:inherit}
  /* Type size is only worth adjusting once there is a box big enough for it to matter. */
  #inputbar:not(.big) #grip .fsz{display:none}
  /* Expanded. The presets move to a column beside the box because that is the only place left for
     them: a horizontal strip of chips above a half-screen textarea is a row you cannot read, and
     the list is long enough that scrolling it is the point. Truncated on purpose — the full text is
     in the tooltip, and a wrapped chip list would push the box back out of the way. */
  #inputbar.big{display:grid;gap:8px;grid-template-columns:minmax(0,1fr) 172px;
    grid-template-rows:auto minmax(0,1fr) auto;
    grid-template-areas:"grip grip" "send notes" "keys keys";min-height:0}
  #inputbar.big > *{max-width:none;margin-left:0;margin-right:0}
  #inputbar.big #grip{grid-area:grip;margin-bottom:0}
  #inputbar.big #keys{grid-area:keys;margin-bottom:0}
  #inputbar.big #prow{grid-area:notes;flex-direction:column;align-items:stretch;gap:6px;
    min-height:0;margin-bottom:0}
  #inputbar.big #pfind{width:auto}
  #inputbar.big #presets{flex-direction:column;overflow-y:auto;overflow-x:hidden;min-height:0}
  #inputbar.big #presets button{width:100%;text-align:left;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis}
  /* The box takes the whole column and the two buttons drop underneath it. Left in a row, the attach
     and Send buttons ate a third of the width and the "expanded" editor wrapped every three words —
     narrower than the bar it replaced. */
  #inputbar.big #sendrow{grid-area:send;min-height:0;
    display:grid;gap:8px;grid-template-columns:auto minmax(0,1fr);
    grid-template-rows:minmax(0,1fr) auto;grid-template-areas:"box box" "att send"}
  #inputbar.big #inputtext{max-height:none;height:100%;grid-area:box}
  #inputbar.big #imgbtn{grid-area:att}
  #inputbar.big #sendbtn{grid-area:send}
  /* ＋ and ✎ are controls, not entries — full-width they read as two more quick commands. */
  #inputbar.big #presets button.meta{width:auto;align-self:flex-start;padding:6px 14px}
  @media (max-width:520px){ #inputbar.big{grid-template-columns:minmax(0,1fr) 140px} }
  /* Dropping a file anywhere on the conversation should work, so the whole overlay is the target. */
  #term.dropping{outline:2px dashed var(--accent);outline-offset:-6px}
  /* Files an agent handed over. Lives in the header rather than inside a conversation: it is the
     one thing you want to reach without first knowing which terminal produced it. */
  #traybtn,#markbtn,#schemebtn{position:relative;background:var(--card);color:var(--text);border:1px solid var(--stroke);
    border-radius:8px;padding:5px 9px;font-size:14px;line-height:1;cursor:pointer}
  #traybtn.has{border-color:var(--accent)}
  /* Filled tint while it is filtering: a board hiding most of itself has to say so somewhere that
     is always on screen, or you go looking for terminals that are simply not being drawn. */
  #markbtn.on{background:var(--markBg);border-color:var(--markTint)}
  #markcount{font-size:11px;font-weight:700;color:var(--sub);margin-left:4px;vertical-align:1px}
  #markbtn.on #markcount{color:var(--markTint)}
  #traybadge:not(:empty){position:absolute;top:-6px;right:-6px;min-width:16px;height:16px;
    border-radius:999px;background:var(--accent);color:var(--onAccent);font-size:10px;font-weight:700;
    line-height:16px;text-align:center;padding:0 3px}
  #tray{display:none;position:sticky;top:0;z-index:6;background:var(--panel);
    border-bottom:1px solid var(--stroke);max-height:min(60vh,420px);overflow-y:auto;
    padding:8px 12px}
  #tray.on{display:block}
  #tray .f{display:flex;align-items:center;gap:10px;padding:9px 10px;margin-bottom:6px;
    background:var(--card);border:1px solid var(--stroke);border-radius:10px;
    color:var(--text);text-decoration:none}
  #tray .f:active{background:var(--accent);color:var(--onAccent)}
  #tray .f .fi{flex:none;font-size:17px;line-height:1}
  #tray .f .fb{flex:1;min-width:0}
  #tray .f .fn{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #tray .f .fm{font-size:11px;color:var(--sub);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #tray .tnone{color:var(--sub);font-size:12px;padding:10px 4px}
  /* project file browser — the project's own directory, walkable from the phone. An agent says "see
     Sources/FleetView/Remote/WebServer.swift:120" and until now there was no way to look. */
  .fbbtn{font-size:12px;font-weight:600;color:var(--sub);background:var(--card);
    border:1px solid var(--stroke);border-radius:7px;padding:5px 9px;cursor:pointer}
  .fbbtn:active{transform:scale(.96)}
  #fb{position:fixed;top:0;left:0;right:0;height:100%;height:100dvh;z-index:56;background:var(--bg);
    display:none;flex-direction:column;overflow:hidden;overscroll-behavior:none}
  #fb.show{display:flex}
  /* Same swipe-back treatment as #term — one gesture, so one look (see swipeBack). */
  #fb.dragging{transition:none}
  #fb.settle{transition:transform .24s cubic-bezier(.22,.8,.3,1)}
  #fb.dragging,#fb.settle{box-shadow:-22px 0 46px rgba(0,0,0,.55)}
  #fbbar{display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--panel);
    border-bottom:1px solid var(--stroke);padding-top:max(10px,env(safe-area-inset-top))}
  #fbbar button{flex:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);
    border-radius:8px;padding:7px 12px;font-size:13px;font-weight:600;cursor:pointer}
  #fbbar button[disabled]{opacity:.35}
  #fbbar .fbname{font-weight:600;flex:1;min-width:0;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis}
  /* The absolute path in full, wrapped rather than clipped: knowing exactly where you are is the
     point, and an ellipsis through the middle of a path defeats it. Selectable, because
     long-press-to-select is the fallback when the clipboard API is missing (plain http is not a
     secure context, so on the LAN it usually is). */
  #fbpath{display:flex;align-items:flex-start;gap:8px;padding:8px 14px;background:var(--panel);
    border-bottom:1px solid var(--stroke);font-size:11px;color:var(--sub);
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  #fbcrumbs{flex:1;min-width:0;word-break:break-all;user-select:text;-webkit-user-select:text}
  #fbcrumbs b{color:var(--accent);font-weight:600;cursor:pointer}
  .fbcopy{flex:none;background:var(--card);color:var(--sub);border:1px solid var(--stroke);
    border-radius:6px;font-size:11px;padding:3px 7px;cursor:pointer;font-family:inherit}
  .fbcopy:active{background:var(--accent);color:var(--onAccent)}
  #fbbody{flex:1;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;padding:10px 12px}
  #fbbody > *{max-width:900px;margin-left:auto;margin-right:auto}
  .fbrow{display:flex;align-items:center;gap:10px;padding:9px 10px;margin-bottom:6px;
    background:var(--card);border:1px solid var(--stroke);border-radius:10px;cursor:pointer}
  .fbrow:active{background:var(--cardHover)}
  .fbrow .fbi{flex:none;font-size:15px;line-height:1}
  .fbrow .fbn{flex:1;min-width:0;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .fbrow .fbs{flex:none;font-size:11px;color:var(--sub)}
  .fbrow .fbc{flex:none;background:transparent;color:var(--sub);border:1px solid var(--stroke);
    border-radius:6px;font-size:11px;padding:3px 6px;cursor:pointer}
  .fbnote{color:var(--sub);font-size:12px;padding:14px 4px;text-align:center}
  .fbnote a{color:var(--accent)}
  pre.fbtext{margin:0;white-space:pre-wrap;word-break:break-word;font-size:11.5px;line-height:1.55;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text);
    background:var(--codeBg);border:1px solid var(--stroke);border-radius:10px;padding:12px 13px}
  img.fbimg{max-width:100%;display:block;margin:0 auto;border-radius:10px;background:var(--card)}
  iframe.fbpdf{width:100%;height:78vh;border:1px solid var(--stroke);border-radius:10px;background:#fff}
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
  <button id="markbtn" onclick="toggleOnlyMarked()" title="Only show marked terminals">🔖<span id="markcount"></span></button>
  <button id="schemebtn" onclick="cycleScheme()">🖥</button>
  <button id="traybtn" onclick="toggleTray()" title="Files agents have sent you">📥<span id="traybadge"></span></button>
  <span class="refresh" id="refresh"></span>
</header>
<div id="tray"><div id="traylist"></div></div>
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
  <div id="termerr"></div>
  <div id="perm"></div>
  <div id="inputbar">
    <div id="grip"><span class="gbar"></span><span class="gtools">
      <button class="fsz" onclick="taFont(-1)" title="Smaller text">A−</button>
      <button class="fsz" onclick="taFont(1)" title="Bigger text">A+</button>
      <button id="expand" onclick="toggleBig()" title="Expand the composer">⤢</button>
    </span></div>
    <div id="prow"><input id="pfind" placeholder="filter" oninput="renderPresets()"><div id="presets"></div></div>
    <div id="keys">
      <button class="skey" onclick="scrollTerm('up')">⇞</button>
      <button class="skey" onclick="scrollTerm('down')">⇟</button>
      <button onclick="key('Escape')">Esc</button>
      <button onclick="key('Enter')">⏎</button>
      <button onclick="key('Up')">↑</button>
      <button onclick="key('Down')">↓</button>
      <button onclick="key('Left')">←</button>
      <button onclick="key('Right')">→</button>
      <button onclick="typeRaw('/')" title="Open the agent's slash-command menu">/</button>
      <button onclick="key('Tab')">Tab</button>
      <button onclick="key('C-c')">^C</button>
      <button onclick="key('BSpace')">⌫</button>
    </div>
    <div id="sendrow">
      <input id="imgfile" type="file" multiple hidden>
      <button id="imgbtn" title="Attach a file — it uploads to the Mac and its path goes in the prompt">📎</button>
      <textarea id="inputtext" rows="1" placeholder="Type here (中文 OK) — Enter to send, Shift+Enter for newline"></textarea>
      <button id="sendbtn">Send</button>
    </div>
  </div>
</div>

<div id="fb">
  <div id="fbbar">
    <button onclick="fbClose()">‹</button>
    <span class="fbname" id="fbname"></span>
    <button id="fbup" onclick="fbUp()" title="Up one level">↑</button>
  </div>
  <div id="fbpath"><span id="fbcrumbs"></span><button class="fbcopy" onclick="fbCopyHere()">⧉ path</button></div>
  <div id="fbbody"></div>
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
/* Where the board was when you opened a terminal, so closing one puts you back there instead of at
   the top of the list — on a phone, three projects up.
   The offset has to be taken *before* the lock: `body.locked` is `position:fixed`, which collapses
   the document's scroll to 0 the moment it applies. Parking the locked body at -offset is what
   makes the board behind a swipe-back the part you were reading rather than the top of the page. */
let boardY=0;
function lockBoard(){
  // Only the first lock records: openTerm can run again with the overlay already up, and the
  // reading then would be the fixed body's 0.
  if(!document.body.classList.contains('locked')) boardY=window.scrollY||document.documentElement.scrollTop||0;
  document.body.style.top=(-boardY)+'px';
  document.body.classList.add('locked');
}
/* The offset alone is not enough to be right: the board can rebuild while you are away — a terminal
   removed, a cluster formed, a card grown a second line — and then the number points at something
   else. So the card you came out of has the last word. It is not "restore a scroll position", it is
   "keep looking at that terminal"; the offset is just the cheapest way to hold still when nothing
   moved, and scrolling is only forced when the card would otherwise be off screen. */
function unlockBoard(id){
  document.body.classList.remove('locked');
  document.body.style.top='';
  window.scrollTo(0,boardY);
  // The last one: a running terminal is drawn twice now (once in the strip at the top, once in its
  // project), and "the card you came out of" means the one in the board, not the summary copy.
  const all=id?document.querySelectorAll('.card[data-id="'+id+'"]'):[];
  const card=all.length?all[all.length-1]:null;
  if(!card) return;
  const r=card.getBoundingClientRect();
  if(r.top<8||r.bottom>window.innerHeight-8) card.scrollIntoView({block:'center'});
}
function openTerm(id,name){
  curId=id;curUrl='';termLoaded=false;chatFails=0;termGone=false;
  const cached=cacheGet(id);
  if(cached&&cached.messages&&cached.messages.length) showCached(cached); else showSkeleton();
  document.getElementById('termname').textContent=name;
  document.getElementById('termframe').src='about:blank';
  document.getElementById('term').classList.add('show');
  lockBoard();                              // stop the page scrolling behind the overlay
  syncViewport();
  requestAnimationFrame(syncViewport);     // re-measure once the lock has taken effect
  renderPresets();          // latest Notes as quick-commands
  beaconSelect(id,'chat');
  setView('chat');          // reading history is the common remote case
  // Next frame, so the panes have their real heights and the ceiling is measured against those.
  if(barH) requestAnimationFrame(applyBar);
}
/* Swipe right to go back, the way the phone's own apps do. The overlay follows your finger with
   resistance, then either settles back or carries on out to the right.
   Parameterised rather than written twice: the terminal overlay and the file browser are the same
   gesture, and the half of it that is not obvious — the resistance curve, telling a flick from a
   finger that stopped, and unwinding a swipe whose touchend never arrives because the tab went
   away — is exactly the half a second copy would get subtly wrong. */
function swipeBack(overlayId,scrollId,busySel,onClose){
  const t=document.getElementById(overlayId), chat=document.getElementById(scrollId);
  if(!t||!chat)return;
  let x0=0,y0=0,dx=0,t0=0,armed=false,active=false,vx=0,lastX=0,lastT=0;
  const reset=()=>{ armed=false; active=false; vx=0;
    t.classList.remove('dragging'); t.classList.remove('settle'); t.style.transform=''; };
  // places where a horizontal drag means something else
  const busy=el=>!!(el&&el.closest&&el.closest(busySel));
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
      setTimeout(()=>{ t.classList.remove('settle'); t.style.transform=''; onClose(); },210);
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
}
swipeBack('term','chat','pre.code,.mbody,#presets,#keys,#inputbar,#tabs',()=>closeTerm());
/* The file browser is the other full-screen overlay, and it was the one place on the phone with no
   way back but the ‹ button. Its exclusions are its own: the crumb bar is selectable text you
   long-press to copy, a code preview scrolls sideways, and a PDF is an iframe that pans itself. */
swipeBack('fb','fbbody','#fbpath,#fbcrumbs,pre,iframe',()=>fbClose());
function closeTerm(){
  document.getElementById('stickyq').classList.remove('on');
  document.getElementById('term').classList.remove('show');
  unlockBoard(curId);                      // back to the card you came from, not to the top
  syncViewport();                          // drop the keyboard-era height/offset
  document.getElementById('termframe').src='about:blank';
  document.getElementById('termerr').classList.remove('on');
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
  // The failure panel belongs to the Terminal tab; left up it would sit on top of the conversation.
  if(v!=='term') document.getElementById('termerr').classList.remove('on');
  document.getElementById('keys').classList.toggle('chatview',v==='chat');
  updateStickyPrompt();          // it belongs to the chat pane — never leave it over the terminal
  if(v==='term'){stopChatPoll();ensureTerm();}
  else{loadChat();startChatPoll();}
}
/* Is ttyd actually answering on that port, from THIS device? An iframe cannot tell us: a failed
   load fires no error we can hook and leaves a blank white rectangle, which is what "the terminal
   doesn't open" looked like. no-cors means we can't read the response, but resolve-vs-reject is
   exactly the question — is the port reachable — and that is all we need. */
async function termReachable(url,tries=5){
  for(let i=0;i<tries;i++){
    try{ await fetch(url,{mode:'no-cors',cache:'no-store'}); return true; }
    catch(e){ await new Promise(r=>setTimeout(r,150*(i+1))); }
  }
  return false;
}
function termError(msg,hint){
  const el=document.getElementById('termerr');
  el.innerHTML='<div class="te"><b>'+esc(msg)+'</b>'+(hint?'<span>'+esc(hint)+'</span>':'')
              +'<button onclick="retryTerm()">Retry</button></div>';
  el.classList.add('on');
}
function retryTerm(){
  document.getElementById('termerr').classList.remove('on');
  termLoaded=false; curUrl=''; termGone=false;
  document.getElementById('termframe').src='about:blank';
  ensureTerm();
}
/* The session behind an already-loaded iframe can disappear — the terminal is closed on the Mac,
   or its shell exits — and from that moment ttyd owns a frame it can do nothing useful with. Its
   own message is "Press ⏎ to Reconnect", which is a dead end twice over: there is no session left
   to attach to, and the ⏎ it is waiting for is an xterm.js key event inside the iframe, while the
   Enter you actually have on a phone is FleetView's key row — that one goes to tmux over /key and
   never reaches the closed socket. So the page reads it as "pressing Enter does nothing".
   `canOpen` already says whether the session is alive; this is the only place that was not
   listening, because tick() stops rendering while a terminal is open. */
let termGone=false;
function watchTermAlive(s){
  if(!curId)return;
  const t=(s.terminals||[]).find(x=>x.id===curId);
  if(t&&t.canOpen){
    /* Back. A reopened terminal comes back under the SAME tmux session name — it is derived from
       the terminal's id — so this is the conversation you were already looking at, not a new one.
       Pick it up instead of leaving a stale "closed" panel over a terminal that works again. */
    if(termGone){termGone=false;document.getElementById('termerr').classList.remove('on');ensureTerm();}
    return;
  }
  // `termLoaded` gates only this half: nothing was ever shown, so there is nothing to explain.
  if(!termLoaded||termGone)return;           // already said so; don't rewrite it every 1.5s
  termGone=true; termLoaded=false; curUrl='';
  document.getElementById('termframe').src='about:blank';
  termError('这个终端已经关闭',
            '它的会话已经不在了，所以 ttyd 的“按 ⏎ 重连”接不上任何东西。回到看板点这张卡片可以重新打开，并接着原来的对话。');
}
async function ensureTerm(){
  if(termLoaded||!curId)return;
  termLoaded=true;
  const want=curId;
  document.getElementById('termerr').classList.remove('on');
  let j;
  try{ j=await(await fetch('/open?id='+encodeURIComponent(curId))).json(); }
  catch(e){ termLoaded=false; termError('Could not reach the Mac','The dashboard itself answered, so this is usually a moment of network trouble.'); return; }
  if(want!==curId) return;                 // you moved on while it was starting
  if(!j.port){termLoaded=false;toast('This terminal is not open on the Mac right now');return;}
  curUrl=location.protocol+'//'+location.hostname+':'+j.port+'/';
  /* Each terminal is served by its OWN ttyd on its own port, so the Chat tab working says nothing
     about whether this one is reachable — different port, and possibly a different address family
     or a route your phone doesn't have. Check before handing the URL to the iframe. */
  if(!await termReachable(curUrl)){
    if(want!==curId) return;
    termLoaded=false;
    termError('The terminal port is not answering',
              'Chat talks to FleetView on :'+location.port+'; a terminal is a separate server on :'
              +j.port+'. If this keeps happening, that port is being blocked between here and the Mac.');
    return;
  }
  if(want!==curId) return;
  document.getElementById('termframe').src=curUrl;
}
async function popTerm(){await ensureTerm();if(curUrl)window.open(curUrl,'_blank');}

/* ---------- conversation view ---------- */
const TOOLICON={terminal:'$',edit:'✎',read:'▤',search:'⌕',web:'⬡',task:'⚙',other:'•'};
function startChatPoll(){stopChatPoll();chatTimer=setInterval(loadChat,3000);}
function stopChatPoll(){if(chatTimer){clearInterval(chatTimer);chatTimer=null;}}
/* Consecutive failures, so a persistent one can be told apart from a slow one. It used to be
   neither: renderChat lives inside the try and the catch was empty, so the skeleton was only ever
   replaced on success — a request that kept failing left an animation shimmering forever, identical
   to still-loading and with nothing said. The poll itself was never the problem: it is a plain
   setInterval and keeps retrying regardless, which is why this recovers on its own. */
let chatFails=0;
function showChatError(msg){
  const el=document.getElementById('chat');
  // Only take over the skeleton. If cached messages are on screen they are still worth reading,
  // and replacing them with an error would lose the one useful thing there.
  if(!el.querySelector('.skel'))return;
  el.dataset.sig='';
  el.innerHTML='<div id="chatnote">'+esc(msg)+'<br><span style="opacity:.6">重试中…</span></div>';
}
async function loadChat(){
  if(!curId)return;
  const want=curId;
  try{
    const r=await fetch('/conversation?id='+encodeURIComponent(want)+'&limit=150',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const j=await r.json();
    if(want!==curId)return;           // you switched terminals while this was in flight
    chatFails=0;
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
  }catch(e){
    if(want!==curId)return;
    // One miss is a blip and not worth a message; two in a row (≈6s) is a state you should be told
    // about. Polling continues either way, so this clears itself the moment a request succeeds.
    if(++chatFails>=2) showChatError('读取会话失败：'+(e.message||e));
  }
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
  // The overlay's own height — `dvh`, so the screen with browser chrome already deducted. It used to
  // be the layout viewport, which meant this measurement carried the chrome height around with it
  // and the threshold below existed largely to subtract it back out again.
  const H=t.offsetHeight||window.innerHeight;
  // Only a keyboard gets padded off. visualViewport is not trustworthy on its own here: iPadOS can
  // leave its height at the keyboard-era value after the keyboard is gone, and that stale number
  // was the strip of dead space under the composer that never went away. So the measurement has to
  // agree with two other things — that a field is actually focused, and that the shortfall is big
  // enough to be a keyboard rather than rounding between `dvh` and visualViewport.
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
  // The band just changed size; an expanded composer drawn against the old one can be taller than
  // what is left, and #term clips rather than scrolls — the conversation would simply be gone.
  if(barH) applyBar();
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
  /* Belt and braces: if the document itself got scrolled while a field had focus, put it back.
     Only while the overlay is up — this fires on the way out too (tapping ‹ blurs the composer
     first), and out there the document's offset is the board's place in the list, not a stray
     keyboard scroll to undo. */
  el.addEventListener('blur',()=>{
    if(termOpen()) window.scrollTo(0,0);
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
/* That top is computed, not inherited, so it goes stale the moment anything above the pane changes
   height — and #sinfo does that on its own: its chips wrap to a second line as they come and go (a
   longer token count, a permission mode, a branch count), and it is display:none while empty, so it
   jumps from nothing to a row or two just after a conversation opens. None of that is a scroll, so
   nothing recomputed the offset and the bar stayed where the previous layout had put it.
   Watch the pane instead: every one of those ends up resizing it. */
if(window.ResizeObserver){
  new ResizeObserver(()=>updateStickyPrompt()).observe(document.getElementById('chat'));
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
/* A literal character rather than a key name — tmux `send-keys -l` takes text, and "/" is not in the
   named-key allowlist anyway. It gets its own button because a slash is what opens an agent's
   command menu and phone keyboards bury it a layer down. No Enter: the menu opens on the character
   and you pick from it. */
async function typeRaw(s){if(!curId)return;
  try{await fetch('/type?id='+encodeURIComponent(curId)+'&text='+encodeURIComponent(s));}catch(e){}}
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
/* Append, never replace. A quick command is a fragment you stack onto what you are already writing
   — "run the tests" then "and fix what fails" — and replacing threw away a half-typed prompt with
   no way back. */
function usePreset(id){
  const n=((state&&state.notes)||[]).find(x=>x.id===id); if(!n)return;
  const ta=document.getElementById('inputtext');
  const cur=ta.value, pad=(cur&&!/\s$/.test(cur))?' ':'';
  ta.value=cur+pad+n.text;
  const at=ta.value.length; ta.setSelectionRange(at,at);
  autoGrow(ta); ta.focus();
  syncSendBtn();
}
async function addNote(){const c=prompt('Add a quick command (saved to Notes on the Mac)');
  if(c&&c.trim()){await fetch('/note?add='+encodeURIComponent(c.trim()));await refreshState();renderPresets();}}
async function delNote(id){await fetch('/note?del='+encodeURIComponent(id));await refreshState();renderPresets();}
function toggleEditPresets(){presetEdit=!presetEdit;renderPresets();}
renderPresets();

/* ---------- composer size ----------
   Two states, one number: 0 is the auto-growing three-line bar, anything else is an explicit height
   in pixels and turns the bar into the expanded editor (see #inputbar.big). The grip drags between
   them, the ⤢ button jumps. Both are remembered per device — how tall a box you want to write in is
   a property of the thing you are typing on, not of the fleet. */
const BAR_MIN=170;
let barH=parseInt(localStorage.getItem('fv_barh')||'',10)||0;
let taFontPx=parseInt(localStorage.getItem('fv_tafont')||'',10)||14;
/* The ceiling is measured off the pane above rather than off the overlay: with the keyboard up, the
   overlay is still a full screen tall and only the pane has actually shrunk, so sizing against the
   overlay is how the composer ends up taller than the space left for it. */
function barMax(){
  const bar=document.getElementById('inputbar');
  const chat=document.getElementById('chat');
  const pane=chat.classList.contains('on')?chat:document.getElementById('termframe');
  const avail=(pane.clientHeight||0)+bar.offsetHeight;
  return Math.max(BAR_MIN,Math.round(avail*0.8));
}
/* Draw the bar at the height that was asked for, clamped to what there is room for *now*. Kept apart
   from setBarHeight so the keyboard can squeeze the box without overwriting the number: it used to
   share one variable, and a composer shrunk to fit the keyboard stayed shrunk after it closed. */
function applyBar(){
  const bar=document.getElementById('inputbar');
  if(!barH){ bar.style.height=''; bar.classList.remove('big'); }
  else{
    bar.classList.add('big');
    bar.style.height=Math.min(barMax(),Math.max(BAR_MIN,barH))+'px';
  }
  document.getElementById('expand').textContent=barH?'⤡':'⤢';
  autoGrow(document.getElementById('inputtext'));
}
/* A new wanted height. Clamped to the ceiling here — a drag that runs off the top of the screen
   otherwise banks height you then have to drag back down through before anything moves. */
function setBarHeight(h){
  barH=h?Math.min(barMax(),Math.max(BAR_MIN,Math.round(h))):0;
  applyBar();
}
function toggleBig(){
  if(barH){ setBarHeight(0); }
  else{
    const chat=document.getElementById('chat');
    const pane=chat.classList.contains('on')?chat:document.getElementById('termframe');
    setBarHeight(((pane.clientHeight||0)+document.getElementById('inputbar').offsetHeight)*0.55);
  }
  localStorage.setItem('fv_barh',String(barH));
}
/* The box is sized in one of two ways and three places used to each decide for themselves, which is
   how an inline height left over from the collapsed bar ended up overriding `height:100%` and
   pinning the expanded editor to three lines. */
function autoGrow(ta){
  if(document.getElementById('inputbar').classList.contains('big')){ ta.style.height='100%'; return; }
  ta.style.height='auto'; ta.style.height=Math.min(120,ta.scrollHeight)+'px';
}
function applyTaFont(){
  const ta=document.getElementById('inputtext');
  ta.style.fontSize=taFontPx+'px';
  autoGrow(ta);
}
function taFont(d){
  taFontPx=Math.min(30,Math.max(11,taFontPx+d));
  localStorage.setItem('fv_tafont',String(taFontPx));
  applyTaFont(); toast(taFontPx+'px');
}
applyTaFont();
(function(){
  const g=document.getElementById('grip');
  let y0=0,h0=0,live=false;
  g.addEventListener('pointerdown',e=>{
    if(e.target.closest('button'))return;
    live=true; y0=e.clientY; h0=document.getElementById('inputbar').offsetHeight;
    g.setPointerCapture(e.pointerId); e.preventDefault();
  });
  g.addEventListener('pointermove',e=>{ if(live) setBarHeight(h0+(y0-e.clientY)); });
  const end=()=>{
    if(!live)return;
    live=false;
    // Dragged back down onto the floor: that is a request to collapse, not to sit at the minimum.
    if(barH&&barH<=BAR_MIN+8) setBarHeight(0);
    localStorage.setItem('fv_barh',String(barH));
  };
  g.addEventListener('pointerup',end);
  g.addEventListener('pointercancel',end);
})();
async function sendText(){
  if(!curId)return;
  const ta=document.getElementById('inputtext');const t=ta.value;
  /* An empty box while the agent works means Stop; anything you typed is a message, always. The
     button label can be a poll behind the terminal, and letting it decide here meant a typed
     message interrupted the turn instead of sending — so it took two taps. */
  if(!t){ key(document.getElementById('sendbtn').dataset.stop?'Escape':'Enter'); return; }
  ta.value='';autoGrow(ta);
  showSent(t);                       // don't wait a round trip to acknowledge the send
  stickBottom=true; jumpLatest();    // follow your own message down, wherever you were reading
  markSent();                       // the hook is a beat behind; don't sit on 'idle' meanwhile
  try{ await fetch('/type?id='+encodeURIComponent(curId)+'&enter=1&text='+encodeURIComponent(t)); }
  catch(e){ ta.value=t; autoGrow(ta); sentAt=0; renderInfo(curInfo);
            if(sentGhost){ sentGhost.node.remove(); sentGhost=null; } }
  setTimeout(loadChat,400);
}
/* ---------- files an agent sent (the outbox) ----------
   The mirror of the attach button: `fleetview-send` drops a file in ~/.fleetview/outbox and it
   turns up here, one tap from opening on the phone. Polled with the rest of the dashboard, so a
   file that lands while you are looking appears on its own. */
let trayFiles=[];
function fileIcon(ext){
  if(['png','jpg','jpeg','gif','webp','heic','avif','svg'].includes(ext))return '🖼';
  if(ext==='pdf')return '📄';
  if(['csv','xlsx','xls'].includes(ext))return '📊';
  if(['zip','tar','gz','tgz'].includes(ext))return '🗜';
  if(['mp4','mov','mp3','wav','m4a'].includes(ext))return '🎬';
  if(['txt','log','md','json','yml','yaml'].includes(ext))return '📝';
  return '📎';
}
const kb=n=>n<1024?n+'B':(n<1048576?(n/1024).toFixed(0)+'KB':(n/1048576).toFixed(1)+'MB');
async function loadFiles(){
  try{
    const r=await fetch('/files');
    const list=await r.json();
    if(!Array.isArray(list))return;
    trayFiles.length=0; trayFiles.push(...list);
  }catch(e){ return; }
  const btn=document.getElementById('traybtn'), badge=document.getElementById('traybadge');
  badge.textContent=trayFiles.length?String(trayFiles.length):'';
  btn.classList.toggle('has',trayFiles.length>0);
  if(document.getElementById('tray').classList.contains('on')) renderTray();
}
function renderTray(){
  const el=document.getElementById('traylist');
  if(!trayFiles.length){ el.innerHTML='<div class="tnone">nothing yet</div>'; return; }
  /* `from` is a terminal id — the server deliberately leaves naming to us, since the dashboard
     already knows every terminal from /state. */
  const names={};
  for(const t of (state?.terminals||[])) names[t.id]=t.name;
  el.innerHTML=trayFiles.map(f=>{
    const who=names[f.from]||'';
    const bits=[kb(f.bytes||0), who, f.note||''].filter(Boolean).join(' · ');
    return '<a class="f" href="/file?id='+encodeURIComponent(f.id)+'" target="_blank" rel="noopener">'
      +'<span class="fi">'+fileIcon((f.ext||'').toLowerCase())+'</span>'
      +'<span class="fb"><span class="fn">'+esc(f.name||f.id)+'</span>'
      +'<span class="fm">'+esc(bits)+'</span></span></a>';
  }).join('');
}
function toggleTray(){
  const t=document.getElementById('tray');
  t.classList.toggle('on');
  if(t.classList.contains('on')){ renderTray(); loadFiles(); }
}

/* Files: an agent reads a file by opening it, so getting one out of a phone and into a prompt means
   putting the bytes on the Mac and typing the path. The upload answers with the absolute path it
   wrote, which is inserted at the cursor — the same thing you would do by hand after AirDropping
   the file, minus the AirDrop. */
async function attachFiles(files){
  const list=[...files];
  if(!list.length)return;
  const btn=document.getElementById('imgbtn');
  const was=btn.textContent; btn.disabled=true; btn.textContent='…';
  const paths=[];
  for(const f of list){
    try{
      /* The name rides along in the query so the server can keep the extension — an agent keys off
         .csv or .pdf, and the basename it writes is still its own uuid. */
      const r=await fetch('/upload?name='+encodeURIComponent(f.name||''),
        {method:'POST',headers:{'Content-Type':f.type||'application/octet-stream'},body:f});
      const j=await r.json();
      if(j.path) paths.push(j.path); else throw new Error(j.error||('HTTP '+r.status));
    }catch(e){
      btn.textContent='✕';
      setTimeout(()=>{btn.textContent=was;},1400);
      toast('upload failed: '+e.message);
    }
  }
  btn.disabled=false;
  if(btn.textContent==='…') btn.textContent=was;
  if(paths.length) insertAtCursor(document.getElementById('inputtext'), paths.join(' ')+' ');
}
/* Land the path where the cursor is, so a caption typed around it survives. */
function insertAtCursor(ta,text){
  const s=ta.selectionStart??ta.value.length, e=ta.selectionEnd??ta.value.length;
  const before=ta.value.slice(0,s), after=ta.value.slice(e);
  const pad=(before&&!/\s$/.test(before))?' ':'';
  ta.value=before+pad+text+after;
  const at=(before+pad+text).length;
  ta.setSelectionRange(at,at);
  autoGrow(ta);
  ta.focus();
  syncSendBtn();
}
document.getElementById('imgbtn').addEventListener('click',()=>document.getElementById('imgfile').click());
document.getElementById('imgfile').addEventListener('change',e=>{
  attachFiles(e.target.files);
  e.target.value='';                 // same file twice in a row still fires
});
/* Paste a screenshot straight into the box — the desktop path, where there is no file picker worth
   using. `kind==='file'` is the whole test: a pasted file of any type is an attachment, and pasted
   text is not a file, so ordinary paste is untouched. */
document.getElementById('inputtext').addEventListener('paste',e=>{
  const items=[...(e.clipboardData?.items||[])].filter(i=>i.kind==='file');
  if(!items.length)return;
  e.preventDefault();
  attachFiles(items.map(i=>i.getAsFile()).filter(Boolean));
});
/* Drag a file onto the conversation. The counter guards against dragleave firing as the pointer
   crosses a child element, which would otherwise clear the highlight mid-drag. */
(function(){
  const t=document.getElementById('term'); let depth=0;
  t.addEventListener('dragenter',e=>{ e.preventDefault(); if(++depth===1) t.classList.add('dropping'); });
  t.addEventListener('dragover',e=>e.preventDefault());
  t.addEventListener('dragleave',()=>{ if(--depth<=0){ depth=0; t.classList.remove('dropping'); } });
  t.addEventListener('drop',e=>{
    e.preventDefault(); depth=0; t.classList.remove('dropping');
    if(e.dataTransfer?.files?.length) attachFiles(e.dataTransfer.files);
  });
})();

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
document.getElementById('inputtext').addEventListener('input',e=>{autoGrow(e.target);syncSendBtn();});

/* ---------- project file browser ----------
   The project's own directory, walked from the phone. What it is for: an agent cites a file, and
   until now the only way to look at it was to be at the Mac. Read-only by construction — the server
   confines every path to a project root (see WebServer.confine). */
let fbDir='',fbRoot='',fbFile='';
const extOf=s=>{const i=s.lastIndexOf('.');return i>0?s.slice(i+1).toLowerCase():'';};
const IMGEXT=['png','jpg','jpeg','gif','webp','avif','svg','heic'];
/* Attribute-safe: esc() escapes &<> but leaves quotes alone, and a filename may legally contain
   one — which would end the attribute and put the rest of the name into the markup. */
const att=s=>esc(s).replace(/"/g,'&quot;');
const fbJoin=(d,n)=>(d.endsWith('/')?d:d+'/')+n;
const fbBase=p=>p.replace(/\/+$/,'').split('/').pop()||p;

/* Copying a path is the point of half the visits: it goes into a prompt on the Mac, or into the
   composer here. navigator.clipboard only exists in a secure context and the dashboard is plain
   http on the LAN, so the old selection trick is not a fallback — it is the normal path. */
async function copyText(s){
  try{
    if(navigator.clipboard&&window.isSecureContext){ await navigator.clipboard.writeText(s); toast('copied'); return; }
  }catch(e){}
  try{
    const ta=document.createElement('textarea');
    ta.value=s;
    // Not display:none and not off-screen: iOS refuses to select either, and an unselected field
    // copies nothing. One transparent pixel in view is what actually works.
    ta.style.cssText='position:fixed;top:50%;left:0;width:1px;height:1px;padding:0;border:0;opacity:0';
    document.body.appendChild(ta);
    ta.focus(); ta.setSelectionRange(0,s.length);
    const ok=document.execCommand('copy');
    document.body.removeChild(ta);
    toast(ok?'copied':'copy failed — long-press the path to select it');
  }catch(e){ toast('copy failed — long-press the path to select it'); }
}
function fbOpen(path){
  document.getElementById('fb').classList.add('show');
  lockBoard();
  fbList(path);
}
function fbClose(){
  document.getElementById('fb').classList.remove('show');
  unlockBoard('');
  fbDir=fbRoot=fbFile='';
}
/* Up: out of a preview back to its directory first, then one level towards the project root —
   which is where it stops, because that is where the server's confinement stops too. */
function fbUp(){
  if(fbFile){ fbList(fbDir); return; }
  if(!fbDir||fbDir===fbRoot) return;
  fbList(fbDir.replace(/\/+$/,'').split('/').slice(0,-1).join('/')||'/');
}
function fbCopyHere(){ copyText(fbFile||fbDir); }
function fbHead(){
  const full=fbFile||fbDir;
  document.getElementById('fbname').textContent=fbBase(full);
  document.getElementById('fbup').disabled=!fbFile&&(!fbDir||fbDir===fbRoot);
  // Every ancestor inside the project is a link back to it; the part above the root is context and
  // is deliberately dead — you cannot go there, so it must not look like you can.
  let acc='',html='';
  for(const part of full.split('/').filter(Boolean)){
    acc+='/'+part;
    const inside=acc===fbRoot||acc.startsWith(fbRoot+'/');
    html+='/'+((inside&&acc!==full)
      ?'<b data-p="'+att(acc)+'">'+esc(part)+'</b>'
      :esc(part));
  }
  document.getElementById('fbcrumbs').innerHTML=html;
}
async function fbList(dir){
  const body=document.getElementById('fbbody');
  body.innerHTML='<div class="fbnote">Loading…</div>';
  let j;
  try{
    const r=await fetch('/browse?path='+encodeURIComponent(dir),{cache:'no-store'});
    j=await r.json();
    if(!r.ok) throw new Error(j.error||('HTTP '+r.status));
  }catch(e){ body.innerHTML='<div class="fbnote">'+esc(e.message||'could not list that folder')+'</div>'; return; }
  fbFile=''; fbDir=j.path; fbRoot=j.root;
  fbHead();
  let html='';
  if(j.truncated) html+='<div class="fbnote">showing the first '+j.entries.length+' entries of this folder</div>';
  for(const e of j.entries){
    html+='<div class="fbrow" data-p="'+att(fbJoin(j.path,e.name))+'" data-d="'+(e.dir?1:0)+'">'
        + '<span class="fbi">'+(e.dir?'📁':fileIcon(extOf(e.name)))+'</span>'
        + '<span class="fbn">'+esc(e.name)+'</span>'
        + '<span class="fbs">'+(e.dir?'':kb(e.size||0))+'</span>'
        + '<button class="fbc" title="Copy path">⧉</button></div>';
  }
  if(!j.entries.length) html+='<div class="fbnote">this folder is empty</div>';
  body.innerHTML=html;
  body.scrollTop=0;
}
async function fbShow(path){
  fbFile=path; fbHead();
  const body=document.getElementById('fbbody');
  const e=extOf(path), url='/read?path='+encodeURIComponent(path);
  if(IMGEXT.includes(e)){ body.innerHTML='<img class="fbimg" src="'+att(url)+'">'; body.scrollTop=0; return; }
  if(e==='pdf'){ body.innerHTML='<iframe class="fbpdf" src="'+att(url)+'"></iframe>'; return; }
  body.innerHTML='<div class="fbnote">Loading…</div>';
  try{
    const r=await fetch(url,{cache:'no-store'});
    const type=r.headers.get('content-type')||'';
    if(!r.ok){
      // 415 is the server saying "this is binary" — the answer to that is a download, not an error.
      const msg=esc(await r.text());
      body.innerHTML='<div class="fbnote">'+msg+(r.status===415
        ?'<br><a href="'+att(url)+'&dl=1">download it</a>':'')+'</div>';
      return;
    }
    if(type.startsWith('image/')){ body.innerHTML='<img class="fbimg" src="'+att(url)+'">'; return; }
    const t=await r.text();
    body.innerHTML='<pre class="fbtext"></pre>';
    body.querySelector('pre').textContent=t;      // textContent, so a file of HTML stays a file
  }catch(err){ body.innerHTML='<div class="fbnote">could not read that file</div>'; }
  body.scrollTop=0;
}
document.getElementById('fbbody').addEventListener('click',e=>{
  const row=e.target.closest('.fbrow'); if(!row)return;
  if(e.target.closest('.fbc')){ copyText(row.dataset.p); return; }
  if(row.dataset.d==='1') fbList(row.dataset.p); else fbShow(row.dataset.p);
});
document.getElementById('fbcrumbs').addEventListener('click',e=>{
  const b=e.target.closest('b'); if(b) fbList(b.dataset.p);
});

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
  const z=[{k:'done',t:done?'Unmark':'🔖 Mark'},{k:'duplicate',t:'⧉ Duplicate'},{k:'rename',t:'✎ Rename'}];
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
    /* pointer-events:none, because it is only ever faded out and never removed: an invisible node
       parked 70px off the bottom at z-index 70 otherwise goes on swallowing every tap that lands on
       it — which is precisely where the composer's key row sits. */
    t.style.cssText='position:fixed;left:50%;bottom:70px;transform:translateX(-50%);z-index:70;pointer-events:none;background:var(--card);border:1px solid var(--stroke);color:var(--text);padding:9px 14px;border-radius:10px;font-size:13px;box-shadow:0 6px 20px rgba(0,0,0,.5)';
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
  const dn=t.done?'🔖 ':'';
  return `<div class="card ${locked?'locked':''} ${t.done?'done':''}" data-id="${t.id}" data-name="${esc(t.name)}" data-cluster="${t.clusterId?'1':'0'}" data-canopen="${t.canOpen?'1':'0'}" data-done="${t.done?'1':'0'}">
    <div class="cardtop">
      <span class="dot" style="background:${COLORS[t.status]||COLORS.closed}"></span>
      <span class="name">${dn}${esc(t.name)}</span>${agent}
      <span class="status" style="color:${COLORS[t.status]||COLORS.closed}">${esc(t.statusLabel)}${tok}</span>
    </div>
    <div class="prompt"><span class="sig">${sig}</span><span class="txt">${t.prompt?esc(t.prompt):'—'}</span></div>
    ${t.running>=0?`<div class="ago"><span class="run" data-run="${t.id}"></span></div>`
                  :((t.lastRun>=0||t.idle>=0)?`<div class="ago">${t.lastRun>=0?`<span class="run done">⏱ ${clockText(t.lastRun*1000)}</span> `:''}${ago(t.idle)}</div>`:'')}
  </div>`;
}
/* How long the current run has been going. The number is deliberately NOT in the markup above: the
   board is only rebuilt when its HTML differs, and a clock baked into it would differ every second
   — rebuilding the whole board under your finger for one digit (which is the stall the rebuild
   guard exists to avoid). The Mac sends elapsed seconds, not a start time, because the phone's
   clock is its own; this turns that into a local anchor and then only ever writes text nodes. */
const runStart={};
function clockText(ms){
  const s=Math.max(0,Math.floor(ms/1000)),h=Math.floor(s/3600),m=Math.floor(s%3600/60),sec=s%60;
  const p=n=>String(n).padStart(2,'0');
  return h>0?h+':'+p(m)+':'+p(sec):m+':'+p(sec);
}
function syncRuns(terms){
  const live={};
  for(const t of terms){
    if(t.running<0) continue;
    live[t.id]=1;
    const st=Date.now()-t.running*1000;
    // Re-anchor only on a real disagreement: each poll's value is a fraction of a second staler
    // than the last, and following that exactly makes the seconds digit stutter.
    if(!runStart[t.id]||Math.abs(runStart[t.id]-st)>2000) runStart[t.id]=st;
  }
  for(const id in runStart){ if(!live[id]) delete runStart[id]; }
  paintRuns();
}
/* `[data-run]` only: a finished run's chip carries the same class but its figure is fixed and
   already in the markup, and blanking it a second after it rendered is exactly what a blind
   `.run` sweep would do. */
function paintRuns(){
  for(const el of document.querySelectorAll('.run[data-run]')){
    const st=runStart[el.dataset.run];
    el.textContent=st?('⏱ '+clockText(Date.now()-st)):'';
  }
}
setInterval(paintRuns,1000);
function render(s){
  const cnt=document.getElementById('counts');
  const cntText=`${s.projects.length} project${s.projects.length===1?'':'s'} · ${s.terminals.length} terminal${s.terminals.length===1?'':'s'}`;
  if(cnt.textContent!==cntText) cnt.textContent=cntText;
  let pills='';
  if(s.working>0)pills+=`<span class="pill" style="color:var(--green);background:rgba(92,209,140,.18)">${s.working} working</span> `;
  if(s.needs>0)pills+=`<span class="pill" style="color:var(--amber);background:rgba(250,184,82,.18)">${s.needs} needs you</span>`;
  const pillEl=document.getElementById('pills');
  if(pillEl.innerHTML!==pills) pillEl.innerHTML=pills;
  // The mark filter is this device's, not the fleet's: it is kept in localStorage rather than sent
  // to the Mac, so filtering on the phone does not empty the board you are working at.
  const marked=s.terminals.filter(t=>t.done).length;
  const mb=document.getElementById('markbtn');
  mb.style.display=(marked||onlyMarked)?'':'none';
  mb.classList.toggle('on',onlyMarked);
  document.getElementById('markcount').textContent=marked?marked:'';
  let html='';
  if(!s.remoteOK)html+=`<div class="banner">Web terminals are disabled — run <b>${esc(s.remoteHint)}</b> and relaunch FleetView. Status is still shown.</div>`;
  /* What is moving, before what exists. The board below is grouped by project because that is how
     work is organised; this answers the other question, which otherwise means scrolling every
     section looking for green dots. Same cards — a second place to see a terminal, not a second
     kind — each tagged with the project it came from, since this row cannot say it by grouping.
     Absent rather than empty when nothing runs. */
  const runList=(onlyMarked?s.terminals.filter(t=>t.done):s.terminals).filter(t=>t.status==='working');
  if(runList.length){
    const pname=id=>{const p=s.projects.find(x=>x.id===id);return p?p.name:'—';};
    html+=`<div class="proj runbox"><div class="projhead">`
        + `<span class="rlabel">⚡ RUNNING NOW</span><span class="count">${runList.length}</span></div>`
        + `<div class="grid">${runList.map(t=>
            `<div class="rcard"><div class="rtag">📁 ${esc(pname(t.projectId))}</div>${card(t)}</div>`
          ).join('')}</div></div>`;
  }
  for(const p of s.projects){
    const all=s.terminals.filter(t=>t.projectId===p.id);
    const terms=onlyMarked?all.filter(t=>t.done):all;
    // A project with nothing marked is left out whole, the way the Mac's board does it — the point
    // of the filter is a board with only the work you are tracking on it.
    if(!terms.length&&onlyMarked) continue;
    const tot=all.reduce((a,t)=>a+t.tokens,0);
    html+=`<div class="proj"><div class="projhead"><span class="name">${esc(p.name)}</span>`+
      // Same rule as the cluster header: the project's real size, and what is on screen of it.
      `<span class="count">${terms.length===all.length?all.length:terms.length+' / '+all.length}</span>`+
      (tot>0?`<span class="tok">Σ ${short(tot)}</span>`:'')+
      `<button class="addbtn" onclick="newTerm('${p.id}')">+ Terminal</button>`+
      // The path rides in a data attribute rather than in the handler's text: it is arbitrary user
      // data, and a project directory with a quote in it would otherwise end the attribute.
      `<button class="fbbtn" data-path="${att(p.path)}" onclick="fbOpen(this.dataset.path)" title="${att(p.path)}">📁 Files</button></div>`;
    const cids=[...new Set(terms.filter(t=>t.clusterId).map(t=>t.clusterId))];
    for(const cid of cids){
      const c=s.clusters.find(x=>x.id===cid);const mem=terms.filter(t=>t.clusterId===cid);
      // The cluster's real size, and what is being shown of it — the header must not claim a
      // two-terminal task when the task has six and four are filtered out.
      const memAll=all.filter(t=>t.clusterId===cid);
      const size=mem.length===memAll.length?`· ${memAll.length}`:`· ${mem.length} of ${memAll.length}`;
      html+=`<div class="cluster"><div class="chead"><span class="clabel">CLUSTER</span><span class="cname">${esc(c?c.name:'')}</span><span class="muted" style="margin-left:8px">${size}</span></div><div class="grid">${mem.map(card).join('')}</div></div>`;
    }
    const solo=terms.filter(t=>!t.clusterId);
    if(solo.length)html+=`<div class="grid">${solo.map(card).join('')}</div>`;
    html+='</div>';
  }
  // Every 1.5s this used to replace the whole board, which forces a layout in the middle of a
  // flick and shows up as a stall at the end of a scroll. Almost every tick is identical, so the
  // rebuild only happens when the markup actually differs.
  const out=html||(onlyMarked
    ? '<div class="empty">Nothing is marked.<br><span style="font-size:12px">The board is filtered to marked terminals only.</span>'
      +'<br><button class="addbtn" style="margin:14px auto 0;display:block" onclick="toggleOnlyMarked()">Show all terminals</button></div>'
    : '<div class="empty">No projects yet. Add one on the Mac.</div>');
  const root=document.getElementById('root');
  if(out!==lastBoard){ lastBoard=out; root.innerHTML=out; }
  syncRuns(s.terminals);   // after any rebuild, so fresh chips are filled in the same frame
}
let lastBoard='';
/* Marked-only view. Device-local (localStorage, never sent to the Mac): which cards you want to
   look at on a phone is not a property of the fleet, and filtering here must not empty the board
   someone is working at on the desktop. */
let onlyMarked=localStorage.getItem('fv_onlymark')==='1';
function toggleOnlyMarked(){
  onlyMarked=!onlyMarked;
  localStorage.setItem('fv_onlymark',onlyMarked?'1':'0');
  if(state) render(state);
  toast(onlyMarked?'showing marked only':'showing all terminals');
}

/* Appearance. Following the Mac is still the default — the dashboard is a mirror of that window and
   the two disagreeing reads as a bug — but only the default: the Mac is in one room and the phone
   is wherever you are, and a board that is dark because the desk is dark is no help outdoors. So
   the button cycles Mac → dark → light, and the choice sticks per browser rather than per device or
   per session, which is the only scope localStorage actually gives us.

   `macDark` is remembered rather than re-read, because /state is polled and `cycleScheme` is not:
   the tick passes the Mac's flag, the button passes nothing, and both have to end up applying the
   same rule. Applied to <html> rather than <body> so `color-scheme` reaches the scrollbars and form
   controls too. */
let scheme=localStorage.getItem('fv_scheme')||'auto';
let macDark=true;
function applyScheme(dark){
  if(dark!==undefined)macDark=dark;
  document.documentElement.classList.toggle('light',
    scheme==='light'||(scheme==='auto'&&macDark===false));
  const b=document.getElementById('schemebtn');
  if(b){
    b.textContent=scheme==='auto'?'🖥':(scheme==='dark'?'🌙':'☀️');
    b.title=scheme==='auto'?'Appearance: following the Mac':('Appearance: '+scheme+' (tap to change)');
  }
}
function cycleScheme(){
  scheme=scheme==='auto'?'dark':(scheme==='dark'?'light':'auto');
  localStorage.setItem('fv_scheme',scheme);
  applyScheme();
  toast(scheme==='auto'?'appearance follows the Mac':('appearance: '+scheme));
}
/* Before the first /state lands, so a saved choice is on the page it paints rather than one poll
   later — and so the button carries the right glyph from the start. */
applyScheme();
async function tick(){
  if(dragging)return;
  try{
    const r=await fetch('/state',{cache:'no-store'});state=await r.json();
    // The appearance is the one thing worth keeping current while a conversation is open — for a
    // browser that is following the Mac, flipping the Mac's theme and watching the phone stay dark
    // reads as broken. Redrawing the board behind the overlay is not: that is the guard below.
    applyScheme(state.dark);
    if(termOpen()){watchTermAlive(state);return;}
    render(state);
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
/* On its own timer, not inside tick(): tick() stops while a conversation is open, and a file that
   arrives while you are reading one is exactly when you want to be told. Slower, because handing a
   file over is a human-paced event. */
loadFiles();setInterval(loadFiles,4000);
</script>
</body>
</html>
"""#
}
