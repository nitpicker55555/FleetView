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
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>FleetView</title>
<style>
  /* Dark is the default, and these are the same values the desktop app's Theme uses, so the two
     palettes can be compared line by line. `html.light` below is the other appearance; which one is
     applied follows the Mac (state.dark) until this browser says otherwise — see `applyScheme`. */
  :root{
    /* Material 3, SchemeTonalSpot for seed #6750A4 — the same values as Theme.swift. The old names
       are kept and mapped onto roles so every rule below keeps working: --card is a filled card
       (surface-container-high), --green is "live" (the primary), --teal/--gray are the outline. */
    --bg:#141218; --panel:#1d1b20; --card:#2b292f; --cardHover:#36343a;
    --stroke:#49454e; --text:#e6e0e9; --sub:#cac4cf; --accent:#cfbdfe;
    --green:#cfbdfe; --teal:#948f99; --gray:#948f99; --amber:#ffb86a; --red:#ffb4ab;
    --claude:#d97757; --codex:#e6e0e9;
    --primaryContainer:#4d3d75; --onPrimaryContainer:#e9ddff;
    --secondaryContainer:#4a4458; --onSecondaryContainer:#e8def8;
    --tertiary:#efb8c8; --outline:#948f99; --outlineVariant:#49454e;
    --tertiaryContainer:#633b48; --onTertiaryContainer:#ffd9e3;
    --surfaceLowest:#0f0d13; --surfaceHighest:#36343a;
    --warnContainer:#683d00; --onWarnContainer:#ffdcbc;
    --errorContainer:#93000a; --onErrorContainer:#ffdad6;
    --inverseSurface:#e6e0e9; --inverseOnSurface:#322f35;
    --scrim:rgba(0,0,0,.32);
    --onAccent:#36275d;
    /* A running card: the light tone for its first ten seconds, the deep one after — in both
       themes (see .card.run). */
    --runFresh:#cfbdfe; --onRunFresh:#36275d; --runSettled:#4d3d75; --onRunSettled:#e9ddff;
    /* Your own words: a primary-container bubble, as in Material's chat patterns. */
    --quoteBg:#4d3d75; --quoteFg:#e9ddff; --quoteEdge:rgba(233,221,255,.08);
    --markBg:#2b292f; --markTint:#efb8c8;
    --quoteBgSoft:rgba(77,61,117,.88);
    --codeBg:#0f0d13;
    --headerBg:rgba(20,18,24,.94);
    --accentSoft:rgba(207,189,254,.14); --accentFaint:rgba(207,189,254,.06);
    --accentEdge:rgba(207,189,254,.30); --accentEdgeOn:rgba(207,189,254,.55);
    --amberSoft:rgba(255,184,106,.12);  --amberEdge:rgba(255,184,106,.38);
    --greenSoft:rgba(207,189,254,.14);  --greenEdge:rgba(207,189,254,.30); --greenFg:#e9ddff;
    --redSoft:rgba(255,180,171,.12);    --redEdge:rgba(255,180,171,.42);  --redFg:#ffdad6;
    --codeInline:rgba(255,255,255,.08);
    --skel1:rgba(255,255,255,.05); --skel2:rgba(255,255,255,.11);
    --skelU1:rgba(255,255,255,.10); --skelU2:rgba(255,255,255,.20);
    --quoteCode:rgba(255,255,255,.10); --quoteCodeFg:#e9ddff; --quoteLink:#cfbdfe;
    --quoteEdgeSoft:rgba(233,221,255,.28);
    --scheme:dark;
  }
  html.light{
    --bg:#fdf7ff; --panel:#f8f2fa; --card:#ece6ee; --cardHover:#e6e0e9;
    --stroke:#cac4cf; --text:#1d1b20; --sub:#49454e; --accent:#65558f;
    --green:#65558f; --teal:#7a757f; --gray:#7a757f; --amber:#895200; --red:#ba1a1a;
    --claude:#b4552f; --codex:#1d1b20;
    --primaryContainer:#e9ddff; --onPrimaryContainer:#4d3d75;
    --secondaryContainer:#e8def8; --onSecondaryContainer:#4a4458;
    --tertiary:#7e5260; --outline:#7a757f; --outlineVariant:#cac4cf;
    --tertiaryContainer:#ffd9e3; --onTertiaryContainer:#633b48;
    --surfaceLowest:#ffffff; --surfaceHighest:#e6e0e9;
    --warnContainer:#ffdcbc; --onWarnContainer:#2c1700;
    --errorContainer:#ffdad6; --onErrorContainer:#93000a;
    --inverseSurface:#322f35; --inverseOnSurface:#f5eff7;
    --scrim:rgba(0,0,0,.32);
    --onAccent:#ffffff;
    --runFresh:#cfbdfe; --onRunFresh:#36275d; --runSettled:#65558f; --onRunSettled:#ffffff;
    --quoteBg:#e9ddff; --quoteFg:#4d3d75; --quoteEdge:rgba(77,61,117,.12);
    --markBg:#ece6ee; --markTint:#7e5260;
    --quoteBgSoft:rgba(233,221,255,.9);
    --codeBg:#f2ecf4;
    --headerBg:rgba(253,247,255,.94);
    --accentSoft:rgba(101,85,143,.10);  --accentFaint:rgba(101,85,143,.045);
    --accentEdge:rgba(101,85,143,.32);  --accentEdgeOn:rgba(101,85,143,.55);
    --amberSoft:rgba(137,82,0,.10);     --amberEdge:rgba(137,82,0,.38);
    --greenSoft:rgba(101,85,143,.10);   --greenEdge:rgba(101,85,143,.32); --greenFg:#4d3d75;
    --redSoft:rgba(186,26,26,.08);      --redEdge:rgba(186,26,26,.40);    --redFg:#93000a;
    --codeInline:rgba(29,27,32,.07);
    --skel1:rgba(29,27,32,.05); --skel2:rgba(29,27,32,.11);
    --skelU1:rgba(77,61,117,.10); --skelU2:rgba(77,61,117,.20);
    --quoteCode:rgba(77,61,117,.10); --quoteCodeFg:#4d3d75; --quoteLink:#65558f;
    --quoteEdgeSoft:rgba(77,61,117,.28);
    --scheme:light;
  }
  /* Tells the browser to render form controls, scrollbars and the like to match. */
  :root{color-scheme:dark}
  html.light{color-scheme:light}
  *{box-sizing:border-box}
  /* min-height, not height, on body. Pinned to exactly one screen, the body was the box the sticky
     header could stick inside — so the header scrolled away with the board after the first screen
     and was "sticky" only in the stylesheet. */
  html{height:100%}
  /* Mobile browsers inflate text they judge too small for a wide block, and iOS does it again on
     rotation; the board is laid out for its own sizes. A browser's own text zoom (an in-app Android
     browser's, which scales fonts and px line-heights but no px height) can still apply on top, so
     every fixed-line-count box below takes its height from its lines rather than from a px figure —
     the card prompt's 32px was what cut its second line in half. */
  html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
  body{margin:0;min-height:100%}
  html{margin:0}
  /* Stops the rubber-band at the root, so a flick that the overlay did not consume cannot drag the
     page itself — the same class of movement the overlay's own overflow now prevents. */
  html{overscroll-behavior:none}
  /* PingFang SC named ahead of the generic fallbacks: with lang=zh-CN that is what the Mac draws, and
     a browser left to pick its own CJK face mixes two of them on one card. Tabular figures throughout,
     so a clock or a token count does not shuffle its neighbours as it changes. */
  body{background:var(--bg);color:var(--text);
    font:14px/20px -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Hiragino Sans GB","Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    font-variant-numeric:tabular-nums;
    -webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent}
  button,input,textarea{font-family:inherit}
  /* Material 3's type scale — the same steps as the Mac's Theme. Every size on the page is one of
     16 / 14 / 12 / 11; weights are 500 or 400 and nothing else. */
  .tm{font-size:16px;line-height:24px;font-weight:500}
  .ts{font-size:14px;line-height:20px;font-weight:500}
  .bs{font-size:12px;line-height:16px;font-weight:400}
  .lm{font-size:12px;line-height:16px;font-weight:500}
  .ls{font-size:11px;line-height:16px;font-weight:500}
  /* Line icons, Lucide's geometry drawn inline (see IC) so the page still needs nothing off the LAN.
     18 in a control, 16 on a card or a row. */
  svg.ic{width:18px;height:18px;flex:none;display:block;fill:none;stroke:currentColor;stroke-width:1.75;
    stroke-linecap:round;stroke-linejoin:round}
  svg.ic.s16{width:16px;height:16px}
  svg.ic.s14{width:14px;height:14px}
  svg.ic.s12{width:12px;height:12px}
  /* Status is a still shape in a role colour, never a word (see glyph()). It moves once, at the
     moment it changes (see playChanges), and not otherwise. The word is the shape's title, for hover
     and for a screen reader. */
  svg.g{width:16px;height:16px;flex:none;display:block;overflow:visible}
  svg.g.s12{width:12px;height:12px}
  .g.working{color:var(--accent)}
  .g.needsYou{color:var(--amber)}
  .g.idle,.g.shell{color:var(--outline)}
  .g.exited,.g.closed{color:color-mix(in srgb,var(--text) 38%,transparent)}
  /* Who the agent is — identity, not state, so it only ever sits in a card's footer. */
  svg.ag{width:13px;height:13px;flex:none;display:block;overflow:visible}
  .ag.claude{color:var(--claude)}
  .ag.codex{color:var(--codex)}
  #panel{display:none;position:relative;border-bottom:1px solid var(--outlineVariant);background:var(--bg)}
  #panel.show{display:block}
  #panelframe{width:100%;height:240px;border:0;display:block;background:var(--bg)}
  /* 240px is a third of an iPhone SE's screen spent before the board has drawn a single card. The
     panel is worth less than the fleet underneath it, so where the screen is short it takes a share
     instead of a fixed slab. Tablets are tall enough to keep the full height. */
  @media (max-height:760px){ #panelframe{height:min(240px,26vh)} }
  #panel.min #panelframe{height:0}
  /* Collapsing zeroed the iframe, the panel box collapsed with it, and the sticky header (z-index 5)
     painted over the absolutely-positioned toggle — so "hide" could never be undone. */
  #panel.min{min-height:40px}
  #panel .pcollapse{position:absolute;right:8px;top:6px;z-index:6;display:inline-flex;align-items:center;gap:4px;
    height:28px;padding:0 12px 0 8px;background:var(--card);color:var(--sub);border:0;border-radius:999px;
    font-size:12px;line-height:16px;font-weight:500;cursor:pointer}
  /* The Material top app bar: the page's own surface, no rule under it, and every control in it the
     same 36px pill — a row where some controls have a ground and some do not reads as two rows. */
  header{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:8px;flex-wrap:wrap;
    transition:transform .2s cubic-bezier(.2,.8,.3,1);
    min-height:64px;padding:14px 16px;background:var(--bg);padding-top:max(14px,env(safe-area-inset-top));
    padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right))}
  /* Slides up while you read down the board and comes back on the way up (see autoHide). */
  header.hide{transform:translateY(calc(-100% - 1px))}
  .brand{display:inline-flex;align-items:center;gap:10px;margin-right:6px}
  .brand .logo{width:28px;height:28px;border-radius:8px;background:var(--accent);color:var(--onAccent);
    display:grid;place-items:center;flex:none}
  .brand .logo svg{width:16px;height:16px;stroke-width:2.25}
  .muted{color:var(--sub)}
  .spacer{flex:1}
  .tb{position:relative;display:inline-flex;align-items:center;justify-content:center;gap:6px;flex:none;
    height:36px;min-width:36px;padding:0 9px;border:0;border-radius:999px;background:var(--card);color:var(--sub);
    font-size:12px;line-height:16px;font-weight:500;cursor:pointer;transition:background .15s}
  .tb:active{background:var(--cardHover)}
  @media (hover:hover){ .tb:hover{background:var(--cardHover)} }
  .tb.on,.tb.on:hover{background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  /* The summary is the shapes the cards use, counted, in the container colour of the zone they lead
     to — "1 needs you" spelled out was a sentence to read where a mark is a glance. */
  #pills{display:contents}
  .badge{display:inline-flex;align-items:center;gap:6px;flex:none;height:36px;padding:0 12px;border-radius:999px;
    font-size:12px;line-height:16px;font-weight:500}
  .badge.need{background:var(--warnContainer);color:var(--onWarnContainer)}
  .badge.run{background:var(--primaryContainer);color:var(--onPrimaryContainer)}
  .badge .g{color:inherit}
  /* A phone has room for the controls or for the words, not both. Narrower still, the brand goes
     too and the summary badges take the left edge, so the whole bar stays one row. */
  @media (max-width:560px){
    #counts,.brand .bname{display:none}
    header{gap:6px;padding-left:max(12px,env(safe-area-inset-left));padding-right:max(12px,env(safe-area-inset-right))}
    .badge{padding:0 10px}
    header .netsig{padding:0 10px}
  }
  @media (max-width:440px){
    .brand{display:none}
    header .spacer{order:1}
    header .tb,header .netsig{order:2}
    /* The bars over the number, as in the conversation's header, so the pill is an icon wide. */
    header .netsig{flex-direction:column;justify-content:center;gap:1px;width:44px;padding:0;line-height:14px}
  }
  /* Connection: signal bars and round-trip time, from the /ping probe (see ping()). */
  .netsig{display:inline-flex;align-items:center;gap:6px;background:none;border:0;padding:4px 2px;
    font:inherit;font-size:11px;line-height:16px;font-weight:500;color:var(--sub);cursor:pointer;font-variant-numeric:tabular-nums}
  header .netsig{height:36px;padding:0 12px;border-radius:999px;background:var(--card)}
  .bars{display:inline-flex;align-items:flex-end;gap:2px;height:12px}
  .bars i{width:3px;border-radius:1px;background:var(--outlineVariant)}
  .bars i:nth-child(1){height:4px}.bars i:nth-child(2){height:6px}
  .bars i:nth-child(3){height:9px}.bars i:nth-child(4){height:12px}
  .bars.l4 i,.bars.l3 i:nth-child(-n+3){background:var(--green)}
  .bars.l2 i:nth-child(-n+2){background:var(--amber)}
  .bars.l1 i:nth-child(1){background:var(--red)}
  .netsig.off .ms{color:var(--red)}
  /* In the conversation's header: the bars over the number, in the width of an icon button. */
  .tsig{flex:none;width:40px;flex-direction:column;gap:2px;padding:0}
  main{padding:8px 16px 120px;max-width:1240px;margin:0 auto;display:flex;flex-direction:column;gap:24px;
    padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right))}
  /* ---- the board, in the Mac's order: 进行中 → projects used in the last two hours → the rest ---- */
  .zh{display:flex;align-items:center;gap:8px;margin:0 0 12px}
  .zh .n{color:var(--sub)}
  /* One grid for every card on the board, so a card is the same size wherever it appears. */
  .grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(280px,1fr))}
  /* 进行中 lifts a card out of its project, so the card has to say where it came from. */
  .from{display:flex;align-items:center;gap:6px;min-width:0;margin:0 0 6px 2px;color:var(--sub)}
  .from span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .rc{min-width:0}
  /* Copies of 进行中 cards on their way out (see flipBoard), placed in document coordinates. Under the
     board, not over it: the cards closing the gap slide across them instead of being covered. */
  #ghosts{position:absolute;left:0;top:0;width:0;height:0;z-index:-1;pointer-events:none}
  #ghosts > *{position:absolute;margin:0}
  /* A Material filled card: three rows — status and name, the last prompt, who and how much. */
  .card{background:var(--card);border-radius:12px;padding:14px 16px;display:flex;flex-direction:column;gap:8px;
    transition:transform .12s,background .12s;cursor:pointer;position:relative;min-width:0;
    user-select:none;-webkit-user-select:none}
  /* touch-action is NOT inherited: with it only on .card, a finger landing on the card's text hit
     an `auto` element and the browser scrolled instead. pan-y keeps the list scrollable; a press
     and hold claims the gesture for dragging (see onDown). */
  .card, .card *{touch-action:pan-y}
  @media (hover:hover){ .card:hover{background:var(--cardHover)} }
  .card.locked{cursor:default}
  /* Rows are min-heights: at 100% they are exactly these figures, and enlarged text grows the row
     rather than spilling over the next one. Every card has the same rows, so they grow together. */
  .card .hd{display:flex;align-items:center;gap:10px;min-height:20px;min-width:0}
  /* Unitless line-heights wherever text is clipped to its lines (here, the prompt, the clamps below):
     the line then scales with the font under any text zoom, so the clip stays between lines. Each
     is its px figure divided by the font size, a hair over so 100% still lays out on the same pixel. */
  .card .nm{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.42858}
  /* A name's distinguishing tail — the (2) a taken name was given, or an older duplicate's time — stays
     whole; the rest of the name gives way (see nameHTML). */
  .card .nm.split{display:flex;text-overflow:clip}
  .card .nm .nb{min-width:0;overflow:hidden;text-overflow:ellipsis}
  .card .nm .ns{flex:none;white-space:pre}
  .card .when{flex:none;color:var(--sub)}
  /* tabular-nums so a ticking clock doesn't shuffle the card's right edge every second */
  .card .clock{color:var(--accent)}
  .card .mk{flex:none;color:var(--tertiary)}
  .card .mk svg{fill:currentColor}
  .card .hid{flex:none;color:var(--sub)}
  /* Two lines, always: a one-line prompt must not make a shorter card than its neighbours. The two
     lines are real ones — an invisible two-line strut beside the text — rather than a height:
     32px was two lines only until a browser scaled the text and not the box, and .tx, stretched to
     that box, cut its second line through the middle. An em height would follow the text only as far
     as a zoom scales what em resolves against, which is not a given; the strut is set in the same
     font and line-height as the text, so the row is two of its lines whatever the zoom did. */
  .card .pr{display:flex;gap:6px;min-width:0;color:var(--sub);line-height:1.33334}
  .card .pr::after{content:"\200B\A\200B";white-space:pre;flex:none;width:0;margin-left:-6px;visibility:hidden}
  .card .pr .sig{flex:none;font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace}
  .card .pr .tx{min-width:0;overflow:hidden;word-break:break-word;
    display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
  .card .ft{display:flex;align-items:center;gap:8px;min-height:28px;min-width:0;color:var(--sub)}
  /* The terminal's id in the footer's corner, four characters of it — enough to tell two cards apart
     and to match one against `project-manager`. Always shown, since a phone has no hover to reveal
     it; the vertical padding is a finger's worth of target that the row's height hides. */
  .card .uid{flex:none;font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:11px;
    line-height:16px;font-weight:500;color:var(--sub);cursor:pointer;padding:6px 0;margin:-6px 0;white-space:nowrap}
  /* Something will make this agent act on its own (see AgentTrigger on the Mac): a schedule, or
     background work that wakes it. Always shown — a card that looks idle with a cron behind it is
     what this is for — and its own target: a tap opens the list, it never opens the terminal. */
  .card .trig{flex:none;display:inline-flex;align-items:center;gap:3px;height:18px;padding:0 6px;
    border:1px solid color-mix(in srgb,var(--accent) 60%,transparent);border-radius:999px;color:var(--accent);
    font-size:11px;line-height:16px;font-weight:500;font-variant-numeric:tabular-nums;cursor:pointer}
  .card.tint .trig,.card.idle.fresh .trig{color:inherit;border-color:color-mix(in srgb,currentColor 50%,transparent)}
  /* The fill is the state, on every copy of a card: the one lifted into 进行中 and the one in its
     project look the same, so either answers the same glance. Running and finished each get a loud
     first ten seconds — `fresh`, which paintFresh sets and the markup never carries: a run that has
     just started is the strong primary, one that has just come back to the prompt the tertiary
     container with a check for its shape. Then running settles to the primary container and finished
     to the plain card. Terminals start and stop on their own (hooks, auto-recover, scheduled pings),
     and a one-off flash is missed by anyone not looking at that moment; ten seconds is long enough to
     catch with a glance and short enough not to become a state of its own to read (AppState.freshFor).
     Secondary text is the same ink at 78% rather than a second hue — except on the fresh tone,
     where 78% of it stops reading as text.
     Running uses its own pair rather than primary / primary-container: those swap depth between
     themes (in light, primary is the deep tone), which made the fresh card the darker one on a
     light board and the lighter one on a dark board. Fresh is the light purple and settled the deep
     one in both. */
  .card.run{--fill:var(--runSettled);--fg:var(--onRunSettled);--fg2:color-mix(in srgb,var(--onRunSettled) 78%,transparent)}
  .card.run.fresh{--fill:var(--runFresh);--fg:var(--onRunFresh);--fg2:var(--onRunFresh)}
  .card.need{--fill:var(--warnContainer);--fg:var(--onWarnContainer);--fg2:color-mix(in srgb,var(--onWarnContainer) 78%,transparent)}
  .card.idle.fresh{--fill:var(--tertiaryContainer);--fg:var(--onTertiaryContainer);--fg2:color-mix(in srgb,var(--onTertiaryContainer) 78%,transparent)}
  /* :not(.dragging), or a coloured card picked up would leave a filled block where the dashed space
     should be — this rule outranks .card.dragging otherwise. */
  .card.tint:not(.dragging),.card.idle.fresh:not(.dragging){background:var(--fill);color:var(--fg)}
  .card.tint .g,.card.tint .ag,.card.tint .when,.card.tint .clock,.card.tint .mk,.card.tint .uid,
  .card.idle.fresh .g,.card.idle.fresh .ag,.card.idle.fresh .when,.card.idle.fresh .mk,.card.idle.fresh .uid{color:inherit}
  .card.tint .pr,.card.tint .ft,.card.tint .hid,.card.idle.fresh .pr,.card.idle.fresh .ft,.card.idle.fresh .hid{color:var(--fg2)}
  /* An idle card draws both of its shapes, the check it wears while fresh and the dot it settles to,
     and the class picks one — so the ten-second line is a class flip, not a rebuild (see cardGlyph). */
  .card .g .gd,.card.idle.fresh .g .gi{opacity:0}
  .card.idle.fresh .g .gd{opacity:1}
  /* Crossing the ten-second line flips `fresh` in place, and this is what eases it instead of letting
     it jump. Only for that moment — paintFresh takes it off again — because left on, the hover of
     every card that ever finished would take a second to answer. */
  .card.ease{transition:transform .12s,background-color 1.2s ease,color 1.2s ease}
  .card.ease *{transition:color 1.2s ease,opacity .6s ease}
  /* The ring a card throws once when its status changes (see playChanges). An element of its own,
     added for the moment: the card's box-shadow already belongs to the drag lift and the ended card. */
  .card .halo{position:absolute;inset:0;border-radius:inherit;pointer-events:none}
  /* Ended (exited / closed): Material's outlined card, its contents at the disabled 38%. Same size as
     every other card — the step down is colour and opacity, never dimensions. */
  .card.ghost{background:transparent;box-shadow:inset 0 0 0 1px var(--outlineVariant)}
  .card.ghost > *{opacity:.38}
  @media (hover:hover){ .card.ghost:hover{background:transparent} .card.ghost:hover > *{opacity:1} }
  /* Held long enough to drag: lifted, with the primary ring the drop targets use. */
  .card.armed{transform:scale(1.02);box-shadow:0 10px 26px rgba(0,0,0,.4);outline:2px solid var(--accent);outline-offset:-2px}
  /* While it is being dragged the card leaves a dashed space where it was. */
  .card.dragging{background:transparent;box-shadow:none;transform:none;outline:1.5px dashed var(--outline);outline-offset:-1.5px}
  .card.dragging > *{visibility:hidden}
  /* A group of terminals on one task: a frame around cards, not a coloured block. */
  /* Out into the margin by its own padding, so the cards inside are on the project grid's columns at
     its size — laid out again inside the padding they were narrower and off the columns around them. */
  .cluster{border-radius:16px;padding:12px;box-shadow:inset 0 0 0 1px var(--outlineVariant);margin:0 -12px 12px}
  .cluster .chead{display:flex;align-items:center;gap:8px;min-height:28px;margin-bottom:12px;color:var(--sub);min-width:0}
  .cluster .cname{color:var(--text);min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  /* A full-width rule above every project is what tells the sections apart from 进行中 above them. */
  .proj{border-top:1px solid var(--outlineVariant);padding-top:16px}
  .ph{display:flex;align-items:center;gap:12px;min-height:40px;margin-bottom:8px;min-width:0}
  .ph .pname{min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
  .ph .meta{display:flex;align-items:center;gap:14px;flex:none;color:var(--sub)}
  .ph .meta > span{display:inline-flex;align-items:center;gap:4px}
  .ph .acts{margin-left:auto;display:flex;align-items:center;gap:2px;flex:none}
  @media (max-width:420px){ .ph{gap:10px} .ph .meta{gap:10px} }
  /* Standard icon buttons — no ground, a state layer on press — as every action in a project header is. */
  .icb{display:grid;place-items:center;width:36px;height:36px;padding:0;border:0;border-radius:999px;
    background:transparent;color:var(--sub);cursor:pointer;transition:background .12s}
  .icb:active{background:color-mix(in srgb,var(--text) 12%,transparent)}
  @media (hover:hover){ .icb:hover{background:color-mix(in srgb,var(--text) 8%,transparent)} }
  /* A project with no terminals: its empty row is the way to start one. */
  .emptyrow{display:flex;align-items:center;gap:8px;width:100%;padding:16px;border-radius:12px;cursor:pointer;
    background:transparent;color:var(--sub);border:1px dashed var(--outlineVariant);font-size:12px;line-height:16px;font-weight:500}
  /* Quiet for two hours: each project as nothing but its own header, folded — the same row as any
     project, with a chevron that opens it in place for this visit. */
  .dorm{display:flex;flex-direction:column;gap:12px}
  .proj.folded .ph{margin-bottom:0}
  .ph .chev{margin-left:-8px;flex:none}
  .ph .chev svg{transition:transform .15s}
  .ph .chev.open svg{transform:rotate(90deg)}
  .banner{background:var(--warnContainer);color:var(--onWarnContainer);padding:12px 16px;border-radius:12px}
  .banner b{font-weight:500}
  .empty{color:var(--sub);text-align:center;padding:60px 20px;display:flex;flex-direction:column;align-items:center;gap:8px}
  .empty .et{color:var(--text)}
  .empty svg.ic{width:24px;height:24px}
  .tonal{display:inline-flex;align-items:center;gap:6px;height:36px;padding:0 16px;margin-top:8px;border:0;border-radius:999px;
    background:var(--secondaryContainer);color:var(--onSecondaryContainer);cursor:pointer;font-size:12px;line-height:16px;font-weight:500}
  /* Dragging: a small inverse label rides with the finger and says what letting go will do. */
  #chip{position:fixed;z-index:60;pointer-events:none;display:none;max-width:70vw;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis;background:var(--inverseSurface);color:var(--inverseOnSurface);border-radius:8px;padding:6px 10px;
    font-size:12px;line-height:16px;font-weight:500;box-shadow:0 6px 18px rgba(0,0,0,.35);transform:translate(-50%,-160%)}
  /* The action bar a card is dropped on: surface-container-high, the dialog corner, the destructive
     action last and in the error colour. */
  #dock{position:fixed;left:12px;right:12px;bottom:max(16px,env(safe-area-inset-bottom));z-index:55;display:none;
    justify-content:center;gap:4px;width:auto;max-width:600px;margin:0 auto;padding:8px;border-radius:28px;
    background:var(--card);box-shadow:0 8px 28px rgba(0,0,0,.4)}
  .zone{flex:1 1 0;min-width:0;max-width:96px;display:flex;flex-direction:column;align-items:center;gap:4px;
    padding:10px 4px;border-radius:20px;color:var(--text);text-align:center;white-space:nowrap;
    font-size:12px;line-height:16px;font-weight:500;transition:background .12s,color .12s,transform .12s,box-shadow .12s}
  .zone svg.ic{width:20px;height:20px}
  .zone span{max-width:100%;overflow:hidden;text-overflow:ellipsis}
  /* The zone under the finger. It used to take the secondary-container tint, which in light is
     #e8def8 on a #ece6ee dock — a difference nobody could see, least of all around the fingertip
     covering it. Filled with the accent and lifted clear of the finger instead. */
  .zone.hot{background:var(--accent);color:var(--onAccent);transform:translateY(-10px) scale(1.12);
    box-shadow:0 6px 16px rgba(0,0,0,.3)}
  .zone.danger{color:var(--red)}
  .zone.danger.hot{background:var(--red);color:var(--bg)}
  /* Where a card dropped away from the dock would land — a card, a group or another project — ringed
     the way the Mac rings it; and the group a card would walk out of, dashed in the error colour,
     because leaving and joining are opposite outcomes and must not look alike. */
  .droptarget{outline:2.5px solid var(--accent);outline-offset:3px;
    box-shadow:0 0 0 7px color-mix(in srgb,var(--accent) 22%,transparent)}
  section.proj.droptarget{border-radius:16px}
  .cluster.leaving{outline:2px dashed var(--red);outline-offset:3px}
  #chip .note{display:block;margin-top:2px;font-weight:400;opacity:.8;white-space:normal}
  /* Six actions across a phone: tighter, and the label a step down, so "取消书签" still fits whole. */
  @media (max-width:440px){ #dock{gap:2px;padding:6px} .zone{padding:10px 2px;font-size:11px} }
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
  /* The side insets, which nothing read until now. `viewport-fit=cover` puts the page under the
     notch and the home indicator, and the top and bottom of that were handled — but hold a notched
     iPhone sideways and the inset moves to the left edge, where it ran through the ‹ button, the
     transcript and the composer alike. Padding #term rather than each row keeps it in one place;
     syncViewport only ever writes paddingTop/paddingBottom, so these survive it. */
  #term{position:fixed;top:0;left:0;right:0;height:100%;height:100dvh;
    padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right);
    z-index:50;background:var(--bg);
    display:none;flex-direction:column;overflow:hidden;overscroll-behavior:none}
  /* Belt and braces for the fallback path, where the overlay can still be shorter than the screen. */
  body.locked{background:var(--bg)}
  #term.show{display:flex}
  /* inset:0 rather than width alone: a body left at its scrolled offset is another way the page
     underneath ends up visible at an edge. overscroll-behavior kills the rubber-band with it. */
  body.locked{overflow:hidden;position:fixed;inset:0;width:100%;overscroll-behavior:none}
  /* The header lies OVER the transcript instead of above it, so hiding it is a transform on one
     layer — the text underneath does not move. Taking it out of the flow the other way (collapsing
     its height) reflowed the pane on every frame of the slide and shoved the line under your finger
     up by the bar's height. #chat is padded by the bar's measured height (--headh) so nothing starts
     under it. `--padtop` is the band syncViewport leaves when the keyboard pans the page. */
  #thead{position:absolute;left:0;right:0;top:var(--padtop,0px);z-index:7;
    padding-top:env(safe-area-inset-top);padding-left:env(safe-area-inset-left);
    padding-right:env(safe-area-inset-right);
    background:var(--headerBg);-webkit-backdrop-filter:blur(18px) saturate(150%);
    backdrop-filter:blur(18px) saturate(150%);border-bottom:1px solid var(--outlineVariant);
    transition:transform .2s cubic-bezier(.2,.8,.3,1)}
  #term.headhide #thead{transform:translateY(calc(-100% - 1px))}
  #termbar{display:flex;align-items:center;gap:4px;min-height:54px;padding:5px 8px;
    max-width:980px;margin:0 auto}
  /* Icon buttons: no box until pressed. Five bordered boxes in one row was most of what made the
     bar look heavy. */
  .ib{flex:none;width:40px;height:40px;display:grid;place-items:center;background:transparent;
    border:0;border-radius:999px;color:var(--text);cursor:pointer;padding:0}
  .ib:active{background:color-mix(in srgb,var(--text) 12%,transparent)}
  .ib svg,.rb svg,.nsearch svg,.tile svg{width:20px;height:20px;fill:none;stroke:currentColor;
    stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round}
  .tile svg{width:24px;height:24px}
  .rb svg circle[r="1.2"]{fill:currentColor;stroke:none}
  .ttl{flex:1;min-width:0;display:flex;flex-direction:column;justify-content:center;gap:1px;padding:0 4px}
  #termbar .tname{font-weight:500;font-size:16px;line-height:22px;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis}
  #termframe{flex:1;border:0;width:100%;background:#000;display:none}
  #termframe.on{display:block}
  /* Shown instead of the blank iframe when its port doesn't answer. A white rectangle is the one
     thing this must never be: it says nothing, and it looks identical to a page still loading. */
  #termerr{display:none;flex:1;align-items:center;justify-content:center;padding:24px;background:var(--bg)}
  #termerr.on{display:flex}
  #termerr .te{max-width:420px;text-align:center;display:flex;flex-direction:column;gap:10px}
  #termerr .te b{font-size:14px;line-height:20px;font-weight:500;color:var(--text)}
  #termerr .te span{font-size:12px;color:var(--sub);line-height:18px}
  #termerr .te button{align-self:center;background:var(--accent);color:var(--onAccent);border:0;
    border-radius:999px;height:36px;padding:0 20px;font-size:14px;font-weight:500;cursor:pointer}
  /* view switch */
  /* Material's segmented button: a surface-container-high trough, the chosen side a
     secondary-container pill. */
  #tabs{flex:none;display:flex;align-items:center;gap:2px;height:36px;background:var(--card);border-radius:999px;padding:3px}
  #tabs button{height:30px;background:transparent;border:0;color:var(--sub);border-radius:999px;padding:0 12px;
    font-size:12px;line-height:16px;font-weight:500;cursor:pointer;transition:background .15s,color .15s}
  #tabs button.on{background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  /* conversation pane — plain scrollable chat, the reliable way to read history on a phone */
  /* pan-y: vertical scrolling stays the browser's, horizontal gestures come to us — which is both
     how the swipe-back below is possible and what stops Safari's own edge swipe leaving the page. */
  #chat{flex:1;min-height:0;position:relative;overflow-y:auto;-webkit-overflow-scrolling:touch;
    background:var(--bg);padding:calc(var(--headh,54px) + 16px) 20px 26px;display:none;
    overscroll-behavior:contain;touch-action:pan-y}
  /* The live terminal has no scroll of ours to watch, so there the bar simply stays, and the frame
     starts below it. */
  #termframe.on,#termerr.on{margin-top:var(--headh,54px)}
  /* Held halfway, the overlay has to read as a card lifted off the dashboard rather than a broken
     layout — hence the edge shadow, kept through the settle so it fades out with the movement. */
  #term.dragging{transition:none}
  #term.settle{transition:transform .2s cubic-bezier(.22,.8,.3,1)}
  #term.dragging,#term.settle{box-shadow:-22px 0 46px rgba(0,0,0,.55)}
  /* Hold the text to a comfortable measure on a wide screen instead of letting lines run the
     full width of a desktop browser. */
  #chat > *{max-width:760px;margin-left:auto;margin-right:auto}
  #chat.on{display:block}
  .msg{margin:0 0 16px;font-size:14px;line-height:22px}
  /* One floating bar carries the prompt currently being answered. Making each prompt sticky piled
     every past one at the top instead of replacing it, so a single element is kept and its text
     swapped as you scroll. */
  #stickyq{position:absolute;left:0;right:0;z-index:4;display:none;padding:12px 20px 0;
    pointer-events:none;transition:top .2s cubic-bezier(.2,.8,.3,1)}
  #stickyq .sq{max-width:760px;margin:0 auto}
  #stickyq.on{display:block}
  /* It floats over live text, so it needs to read as a separate layer: the same primary-container
     bubble as the prompt it quotes, lifted by a shadow rather than set apart by a second colour. */
  #stickyq .sq{position:relative;padding:12px 16px;border-radius:16px;
    font-size:14px;line-height:1.42858;font-weight:400;color:var(--quoteFg);
    background:var(--quoteBg);
    box-shadow:0 6px 20px rgba(0,0,0,.35);
    display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
  .msg .mtext{white-space:pre-wrap;word-break:break-word}
  .msg.user{margin-top:26px}                 /* a new question needs a visible break before it */
  .msg.user:first-child{margin-top:0}
  /* Same primary-container bubble as #stickyq: that bar is a quotation of one of these, so they have
     to read as the same object. Inline code and links need their own colours on that ground. */
  .msg.user .mtext{background:var(--quoteBg);color:var(--quoteFg);
    padding:12px 16px;border-radius:16px;font-size:14px;line-height:22px}
  .msg.user .mtext code{background:var(--quoteCode);color:var(--quoteCodeFg)}
  /* Sending: the card rises out of the composer — once, because you pressed Send, and inside the
     120–200ms every other response on the page takes. */
  @keyframes extrude{
    from{transform:translateY(10px);opacity:0}
    to  {transform:none;opacity:1}
  }
  .msg.user.sending .mtext{animation:extrude .2s cubic-bezier(.2,.8,.3,1) both}
  @media (prefers-reduced-motion:reduce){ .msg.user.sending .mtext{animation:none} }
  .msg.user .mtext a{color:var(--quoteLink)}
  .msg.asst .mtext{color:var(--text);padding:0 2px}
  .msg.sub{opacity:.72}
  .msg .tag{font-size:11px;line-height:16px;font-weight:500;color:var(--accent);margin-bottom:2px}
  /* typed while the agent was working: the same card, just drawn with a broken edge */
  .msg.user.queued .mtext{background:var(--quoteBgSoft);
    outline:1px dashed var(--quoteEdgeSoft);outline-offset:-1px}
  .msg.think,.msg.tool{background:var(--card);border:1px solid transparent;border-radius:12px;
    padding:10px 14px;cursor:pointer;margin-left:10px}
  .msg.think{opacity:.7}
  .msg.tool.bad{border-color:var(--redEdge)}
  .mhead{display:flex;gap:8px;align-items:center;font-size:12px;line-height:16px;min-width:0}
  .mhead b{font-weight:500}
  .mhead svg.ic{color:var(--sub)}
  .mhead .sum{color:var(--sub);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
  .msg .mbody{display:none;white-space:pre-wrap;word-break:break-word;margin-top:8px;padding-top:8px;
    border-top:1px solid var(--stroke);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    font-size:12px;line-height:18px;color:var(--sub);max-height:340px;overflow:auto}
  .mbody b{font-weight:500;color:var(--text)}
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
  /* Still blocks, not a shimmer: a sweep that runs for as long as the fetch takes is motion nobody
     asked for, and when the fetch kept failing it shimmered forever (see showChatError). */
  .skel .row{height:12px;border-radius:8px;margin-bottom:8px;background:var(--skel2)}
  .skel .sk-user .row{height:44px;border-radius:16px;background:var(--skelU2)}
  /* The conversation you just opened arrives rather than appearing: the last few cards rise into
     place, slightly staggered, once — as the answer to the tap that opened it. */
  @keyframes flyIn{
    from{opacity:0;transform:translateY(10px)}
    to  {opacity:1;transform:none}
  }
  .msg.fly{animation:flyIn .2s cubic-bezier(.2,.8,.3,1) both}
  @media (prefers-reduced-motion:reduce){ .msg.fly{animation:none} }
  @media (max-width:520px){
    #chat{padding:calc(var(--headh,54px) + 12px) 13px 22px}
    #stickyq{padding:10px 13px 0}
    #inputbar{padding-left:8px;padding-right:8px}
    #termbar{padding-left:4px;padding-right:4px}
    #tabs button{padding:0 10px}
    .msg.think,.msg.tool{margin-left:0}
  }
  /* a shell terminal's scrollback — wrapped so a phone never scrolls sideways */
  .shellout{margin:0;white-space:pre-wrap;word-break:break-word;font-size:12px;line-height:18px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text)}
  /* markdown inside a message (block elements handle spacing, so no pre-wrap here) */
  .msg .mtext.md{white-space:normal}
  .md p{margin:0 0 8px}
  .md p:last-child{margin-bottom:0}
  .md h1,.md h2,.md h3{margin:12px 0 6px;font-weight:500;line-height:1.4;font-size:14px}
  .md h1,.md h2{font-size:16px}
  .md ul,.md ol{margin:4px 0 8px;padding-left:20px}
  .md li{margin:2px 0}
  .md blockquote{margin:6px 0;padding:2px 0 2px 10px;border-left:2px solid var(--stroke);color:var(--sub)}
  .md hr{border:0;border-top:1px solid var(--stroke);margin:10px 0}
  .md a{color:var(--accent)}
  .md code{background:var(--codeInline);padding:1px 4px;border-radius:4px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
  .md pre.code{background:var(--codeBg);border:1px solid var(--outlineVariant);border-radius:8px;padding:10px 12px;
    margin:8px 0;overflow-x:auto;white-space:pre;position:relative;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;line-height:18px}
  .md pre.code i.lang{position:absolute;right:8px;top:2px;font-style:normal;font-size:11px;
    color:var(--sub)}
  .md table{border-collapse:collapse;margin:8px 0;font-size:12px;display:block;overflow-x:auto}
  .md th,.md td{border:1px solid var(--stroke);padding:4px 8px;text-align:left}
  .md th{background:var(--card);font-weight:500}
  /* code diff (Edit / MultiEdit / Write / codex apply_patch) */
  .diff{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;line-height:18px;
    overflow-x:auto;border-radius:8px;background:var(--codeBg);padding:6px 0;margin-top:7px}
  .dl{white-space:pre;padding:0 10px}
  .dl.add{background:var(--greenSoft);color:var(--greenFg)}
  .dl.del{background:var(--redSoft);color:var(--redFg)}
  .dl.ctx{color:var(--sub)}
  .dl.ph{color:var(--accent);font-weight:500}
  .dgap{color:var(--sub);opacity:.7;padding:2px 10px;font-size:11px}
  .dhead{color:var(--sub);padding:5px 10px 1px;font-size:11px}
  .dstat{font-size:11px;font-weight:500;white-space:nowrap}
  .dstat .a{color:var(--green)}
  .dstat .d{color:var(--red)}
  /* Session status, as the header's subtitle: one line of plain text, not a row of pills. It was its
     own strip of bordered chips — a second bar under the first, 40px of a phone before the
     conversation began. Everything is still on it; it scrolls sideways when it runs long. */
  #sinfo{display:flex;gap:0;align-items:center;font-size:12px;line-height:16px;color:var(--sub);
    white-space:nowrap;overflow-x:auto;scrollbar-width:none;
    -webkit-mask-image:linear-gradient(90deg,#000 88%,transparent);mask-image:linear-gradient(90deg,#000 88%,transparent)}
  #sinfo::-webkit-scrollbar{display:none}
  #sinfo:empty{display:none}
  #sinfo > *{flex:none}
  #sinfo > * + *::before{content:"·";margin:0 6px;color:var(--sub);opacity:.6}
  #sinfo .chip.warn{color:var(--amber)}
  #sinfo .chip.danger{color:var(--red)}
  #sinfo .ctx{display:inline-flex;align-items:center;gap:5px}
  #sinfo .bar{display:inline-block;height:4px;width:34px;background:var(--card);border-radius:2px;overflow:hidden}
  #sinfo .bar i{display:block;height:100%;background:var(--accent)}
  #sinfo .ctx.warn .bar i{background:var(--amber)}
  #sinfo .ctx.danger .bar i{background:var(--red)}
  #sinfo .ctx.warn{color:var(--amber)}
  #sinfo .ctx.danger{color:var(--red)}
  #sinfo .live{display:inline-flex;align-items:center;gap:5px;font-weight:500}
  #sinfo .live svg.g{width:12px;height:12px}
  /* what the agent is doing right now, pinned under the last message */
  .runbar{display:flex;align-items:center;gap:8px;padding:10px 14px;margin:2px 0 10px;
    background:var(--primaryContainer);color:var(--onPrimaryContainer);border-radius:12px;
    font-size:12px;line-height:16px}
  .runbar b{font-weight:500;flex:none}
  .runbar .spin{background:currentColor}
  .runbar .g{color:inherit;width:14px;height:14px}
  .runbar .what{color:color-mix(in srgb,currentColor 78%,transparent);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .runbar.wait{background:var(--warnContainer);color:var(--onWarnContainer)}
  /* a tool still running (no result yet) */
  .msg.tool.run{border-color:var(--accentEdgeOn)}
  /* "Running" — Material's soft-burst shape, still. It was a spinner; nothing on the page moves
     unless you moved it. Same mark as the Mac's StatusGlyph. */
  .spin{display:inline-block;width:11px;height:11px;flex:none;background:var(--accent);
    -webkit-mask:url('data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2016%2016%22%3E%3Cpath%20d%3D%22M16.00%208.00%20L15.81%208.51%20L15.30%208.96%20L14.63%209.32%20L14.01%209.61%20L13.62%209.91%20L13.54%2010.30%20L13.72%2010.82%20L14.03%2011.48%20L14.27%2012.19%20L14.28%2012.82%20L14.00%2013.26%20L13.44%2013.44%20L12.72%2013.39%20L11.99%2013.21%20L11.39%2013.07%20L10.96%2013.13%20L10.70%2013.47%20L10.51%2014.06%20L10.30%2014.78%20L9.99%2015.43%20L9.56%2015.83%20L9.03%2015.85%20L8.49%2015.52%20L8.00%2014.96%20L7.58%2014.37%20L7.22%2013.95%20L6.84%2013.83%20L6.39%2014.01%20L5.83%2014.40%20L5.18%2014.80%20L4.54%2015.02%20L4.00%2014.93%20L3.65%2014.51%20L3.52%2013.84%20L3.54%2013.08%20L3.60%2012.40%20L3.53%2011.92%20L3.24%2011.65%20L2.69%2011.55%20L1.97%2011.48%20L1.24%2011.33%20L0.68%2011.03%20L0.44%2010.57%20L0.57%209.99%20L0.97%209.40%20L1.49%208.86%20L1.92%208.40%20L2.08%208.00%20L1.92%207.60%20L1.49%207.14%20L0.97%206.60%20L0.57%206.01%20L0.44%205.43%20L0.68%204.97%20L1.24%204.67%20L1.97%204.52%20L2.69%204.45%20L3.24%204.35%20L3.53%204.08%20L3.60%203.60%20L3.54%202.92%20L3.52%202.16%20L3.65%201.49%20L4.00%201.07%20L4.54%200.98%20L5.18%201.20%20L5.83%201.60%20L6.39%201.99%20L6.84%202.17%20L7.22%202.05%20L7.58%201.63%20L8.00%201.04%20L8.49%200.48%20L9.03%200.15%20L9.56%200.17%20L9.99%200.57%20L10.30%201.22%20L10.51%201.94%20L10.70%202.53%20L10.96%202.87%20L11.39%202.93%20L11.99%202.79%20L12.72%202.61%20L13.44%202.56%20L14.00%202.74%20L14.28%203.18%20L14.27%203.81%20L14.03%204.52%20L13.72%205.18%20L13.54%205.70%20L13.62%206.09%20L14.01%206.39%20L14.63%206.68%20L15.30%207.04%20L15.81%207.49Z%22/%3E%3C/svg%3E') center/contain no-repeat;mask:url('data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2016%2016%22%3E%3Cpath%20d%3D%22M16.00%208.00%20L15.81%208.51%20L15.30%208.96%20L14.63%209.32%20L14.01%209.61%20L13.62%209.91%20L13.54%2010.30%20L13.72%2010.82%20L14.03%2011.48%20L14.27%2012.19%20L14.28%2012.82%20L14.00%2013.26%20L13.44%2013.44%20L12.72%2013.39%20L11.99%2013.21%20L11.39%2013.07%20L10.96%2013.13%20L10.70%2013.47%20L10.51%2014.06%20L10.30%2014.78%20L9.99%2015.43%20L9.56%2015.83%20L9.03%2015.85%20L8.49%2015.52%20L8.00%2014.96%20L7.58%2014.37%20L7.22%2013.95%20L6.84%2013.83%20L6.39%2014.01%20L5.83%2014.40%20L5.18%2014.80%20L4.54%2015.02%20L4.00%2014.93%20L3.65%2014.51%20L3.52%2013.84%20L3.54%2013.08%20L3.60%2012.40%20L3.53%2011.92%20L3.24%2011.65%20L2.69%2011.55%20L1.97%2011.48%20L1.24%2011.33%20L0.68%2011.03%20L0.44%2010.57%20L0.57%209.99%20L0.97%209.40%20L1.49%208.86%20L1.92%208.40%20L2.08%208.00%20L1.92%207.60%20L1.49%207.14%20L0.97%206.60%20L0.57%206.01%20L0.44%205.43%20L0.68%204.97%20L1.24%204.67%20L1.97%204.52%20L2.69%204.45%20L3.24%204.35%20L3.53%204.08%20L3.60%203.60%20L3.54%202.92%20L3.52%202.16%20L3.65%201.49%20L4.00%201.07%20L4.54%200.98%20L5.18%201.20%20L5.83%201.60%20L6.39%201.99%20L6.84%202.17%20L7.22%202.05%20L7.58%201.63%20L8.00%201.04%20L8.49%200.48%20L9.03%200.15%20L9.56%200.17%20L9.99%200.57%20L10.30%201.22%20L10.51%201.94%20L10.70%202.53%20L10.96%202.87%20L11.39%202.93%20L11.99%202.79%20L12.72%202.61%20L13.44%202.56%20L14.00%202.74%20L14.28%203.18%20L14.27%203.81%20L14.03%204.52%20L13.72%205.18%20L13.54%205.70%20L13.62%206.09%20L14.01%206.39%20L14.63%206.68%20L15.30%207.04%20L15.81%207.49Z%22/%3E%3C/svg%3E') center/contain no-repeat}
  .msg .when{font-size:11px;line-height:16px;color:var(--sub);opacity:.7;margin-left:6px;font-weight:400}
  .msg .cp{font-size:11px;line-height:16px;color:var(--sub);opacity:.6;cursor:pointer;padding:0 5px;float:right}
  .msg .cp:active{opacity:1;color:var(--accent)}
  /* permission / question card */
  #perm{display:none;background:var(--warnContainer);color:var(--onWarnContainer);padding:12px 14px}
  #perm.on{display:block}
  #perm .q{font-size:14px;line-height:20px;font-weight:500;margin-bottom:8px}
  #perm .what{font-size:12px;color:color-mix(in srgb,var(--onWarnContainer) 78%,transparent);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
    margin-bottom:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #perm .opts{display:flex;flex-direction:column;gap:6px}
  #perm button{text-align:left;background:var(--bg);color:var(--text);border:0;
    border-radius:12px;padding:10px 14px;font-size:14px;line-height:20px;cursor:pointer}
  #perm button:active{background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  /* todo / plan / question tool views */
  .todo{margin-top:7px}
  .todo div{display:flex;align-items:flex-start;gap:6px;padding:2px 0;font-size:12px;line-height:18px}
  .todo div svg.ic{margin-top:2px}
  .todo .d{color:var(--sub);text-decoration:line-through}
  .todo .p{color:var(--accent);font-weight:500}
  .qopts{margin-top:6px}
  .qopts .qq{font-size:12px;font-weight:500;margin:6px 0 3px}
  .qopts .qo{font-size:12px;color:var(--sub);padding:1px 0 1px 14px}
  /* jump to latest */
  #jump{position:absolute;right:14px;bottom:96px;z-index:6;background:var(--accent);color:var(--onAccent);border:0;
    border-radius:999px;width:40px;height:40px;padding:0;cursor:pointer;display:none;place-items:center;
    box-shadow:0 4px 14px rgba(0,0,0,.35)}
  #jump.on{display:grid}
  /* flex:none + the safe-area pad keeps the composer pinned to the true bottom; without it the
     bar floated and the page showed through underneath on a phone. With the drawer open the drawer
     is the bottom edge, so the pad moves down to it. */
  #inputbar{flex:none;background:var(--panel);
    padding:8px 10px;padding-bottom:max(8px,env(safe-area-inset-bottom))}
  #term.drawer #inputbar{padding-bottom:8px}
  #inputbar > *{max-width:760px;margin-left:auto;margin-right:auto}
  #keys{display:flex;gap:6px;overflow-x:auto;margin-bottom:8px}
  #keys button{flex:none;height:32px;background:var(--card);color:var(--text);border:0;border-radius:8px;padding:0 12px;font-size:12px;font-weight:500;cursor:pointer}
  #keys button:active{background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  /* The key row exists to drive a TUI: scrolling a pane, arrowing through a menu, ^C, backspace.
     Chat has none of that — it scrolls natively, answers prompts with real buttons, and stops the
     agent with the Send/Stop button — so the whole row goes away there. */
  #keys.chatview{display:none}
  /* One row, the WeChat arrangement: quick commands | the box | more | send. It used to be three
     rows — a resize grip, a filter-and-chips strip and then the box — which took 150px of a phone
     for a strip of chips that was mostly scrolled out of sight anyway.

     --rowh is the height of a composer at rest, and every control is held to it so they cannot
     drift apart. They had: the box sized itself off its own text, the buttons off their padding,
     and the row came out 38/42/38. It is a floor, not a height, so the box still grows with what
     you type while the buttons stay on the bottom line. It is also what stops autoGrow from ever
     drawing the box shorter than the line it holds. */
  #sendrow{--rowh:40px;display:flex;gap:6px;align-items:flex-end}
  #inputtext{flex:1;min-width:0;resize:none;background:var(--card);color:var(--text);
    border:1px solid transparent;border-radius:20px;padding:9px 14px;
    /* Longhands on purpose. This was `font:14px/1.35 inherit`, which is not valid — `inherit` may
       only stand alone in the shorthand — so the whole declaration was dropped and the box drew in
       the browser's default textarea face: monospace in Chrome, which also made the placeholder
       too wide for the box and wrap under its own clip. */
    font-family:inherit;font-size:14px;line-height:1.35;
    max-height:120px;min-height:var(--rowh);outline:none;transition:border-color .15s}
  #inputtext:focus{border-color:var(--accent)}
  .rb{flex:none;width:var(--rowh);height:var(--rowh);display:grid;place-items:center;padding:0;
    background:transparent;border:0;border-radius:50%;color:var(--sub);cursor:pointer;
    transition:color .15s,background .15s,transform .2s}
  .rb:active{background:var(--card)}
  .rb.on{color:var(--onSecondaryContainer);background:var(--secondaryContainer)}
  #morebtn.on svg{transform:rotate(45deg)}
  .rb svg{transition:transform .2s}
  #sendbtn{flex:none;background:var(--accent);color:var(--onAccent);border:0;border-radius:999px;
    padding:0 18px;font-size:14px;font-weight:500;cursor:pointer;min-height:var(--rowh);
    transition:background .15s}
  /* The panels under the composer — quick commands, and the ⊕ tiles. Only one is open at a time, and
     the drawer is the bottom of the overlay while it is. */
  #drawer{flex:none;display:none;background:var(--panel);
    padding:2px 10px max(10px,env(safe-area-inset-bottom))}
  #term.drawer #drawer{display:block}
  #drawer > *{max-width:760px;margin-left:auto;margin-right:auto}
  .dpane{display:none}
  .dpane.on{display:block;animation:drawerIn .2s cubic-bezier(.2,.8,.3,1)}
  @keyframes drawerIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
  @media (prefers-reduced-motion:reduce){ .dpane.on{animation:none} }
  .nhead{display:flex;gap:6px;align-items:center;margin:4px 0 8px}
  .nsearch{flex:1;min-width:0;display:flex;align-items:center;gap:8px;min-height:40px;background:var(--card);
    border:1px solid transparent;border-radius:999px;padding:0 14px;color:var(--sub)}
  .nsearch:focus-within{border-color:var(--accent)}
  .nsearch svg{width:16px;height:16px;flex:none}
  #pfind{flex:1;min-width:0;background:transparent;border:0;outline:none;color:var(--text);
    padding:9px 0;font-family:inherit;font-size:14px;-webkit-appearance:none;appearance:none}
  #pfind::-webkit-search-cancel-button{display:none}
  .nact{flex:none;display:inline-flex;align-items:center;justify-content:center;height:40px;min-width:40px;
    background:var(--card);color:var(--accent);border:0;
    border-radius:999px;padding:0 14px;font-size:12px;font-weight:500;cursor:pointer}
  .nact.on{background:var(--accent);color:var(--onAccent);border-color:transparent}
  /* The list is the palette: whole commands, two lines each, instead of chips cut off at the edge
     of a strip you had to scroll sideways to read. */
  #presets{max-height:min(38vh,300px);overflow-y:auto;-webkit-overflow-scrolling:touch;
    overscroll-behavior:contain;display:flex;flex-direction:column;gap:6px;padding-bottom:2px}
  .nrow{display:flex;align-items:center;gap:8px;width:100%;text-align:left;background:var(--card);
    color:var(--text);border:0;border-radius:12px;padding:10px 14px;
    cursor:pointer;font:inherit}
  .nrow:active{background:var(--cardHover)}
  .nrow .ntext{flex:1;min-width:0;font-size:12px;line-height:1.5;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all;
    display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
  .nrow .nuse{flex:none;color:var(--sub)}
  .nrow .ndel{flex:none;height:32px;background:var(--errorContainer);color:var(--onErrorContainer);border:0;
    border-radius:999px;padding:0 14px;font-size:12px;font-weight:500;cursor:pointer}
  .nempty{color:var(--sub);font-size:12px;text-align:center;padding:18px 8px}
  .tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;padding:12px 0 6px}
  .tile{display:flex;flex-direction:column;align-items:center;gap:7px;background:transparent;
    border:0;color:var(--sub);cursor:pointer;font:inherit;font-size:12px;padding:0}
  .tile .ti{width:56px;height:56px;border-radius:16px;background:var(--card);display:grid;
    place-items:center;color:var(--text);border:0;transition:transform .12s}
  .tile:active .ti{transform:scale(.94);background:var(--cardHover)}
  .tile .ti svg{width:24px;height:24px}
  .tile .ttxt{font:500 16px ui-monospace,SFMono-Regular,Menlo,monospace}
  .tile[disabled]{opacity:.5}
  /* Touch sizing. Two separate things, both of which only apply where the pointer is a finger — on
     a mouse-driven browser the denser text and smaller chips are worth keeping.

     The 16px floor is not a matter of taste: Safari on iOS zooms the whole page in whenever it
     focuses a field whose text is under 16px, and it does not zoom back out afterwards. That zoom
     is where "the terminal card doesn't fill the screen, it's slightly bigger and I have to scroll
     to reach the top and bottom buttons" comes from — #term is still exactly `dvh` tall, the
     viewport shrank underneath it. So tapping the composer, or the quick-command search, was
     enough to break the overlay's fit for the rest of the session. See also TA_MIN, which holds the
     same floor against the A−/A+ buttons: an inline font-size beats this rule.

     44px is Apple's minimum target. */
  @media (pointer:coarse){
    #inputtext,#pfind{font-size:16px}
    #sendrow{--rowh:44px}          /* Apple's minimum, and every control rises to it together */
    #inputtext{border-radius:22px}
    #sendbtn{border-radius:22px;min-width:56px}
    #keys button{min-height:40px}
    .ib{width:44px;height:44px}
    #tabs button{min-height:34px}
    .nact{min-height:40px}
    /* Width only. Height is --gtoolh, because the row's own height is derived from it — and this
       button is the one control the user is most likely to hit by accident, so it earns a
       comfortable width rather than a bigger area in every direction. */
    #grip .gtools button{min-width:40px}
  }
  /* The composer can be pulled up into a proper editor. Writing anything longer than a sentence
     through a three-line slot means never seeing what you wrote, which is the whole reason the
     phone loses to the Mac for a considered prompt. It is entered from the ⊕ tiles; once open, the
     grip on top resizes it and ⤡ puts it back. */
  /* Two things this row got wrong, both of which ended in the composer expanding when nobody asked.

     The handle drags, not the row. The pointer handlers used to sit on the whole 16px strip, which
     spans the full width of the bar directly above the textarea — exactly where a thumb crosses on
     its way to type. Brushing it upward expanded the composer, and with no movement threshold one
     pixel of travel was enough to jump the bar from its collapsed height straight to BAR_MIN. Only
     the visible handle takes the gesture now, and only past SLOP; the rest of the strip is inert.

     And the row is as tall as the tools it carries — --gtoolh is what ties the two together. They
     are positioned absolutely so the handle stays centred on the row rather than being pushed off
     by them, which also means the row does not grow to fit them on its own. */
  #grip{--gtoolh:22px;position:relative;min-height:calc(var(--gtoolh) + 2px);
    display:none;align-items:center;justify-content:center;margin-bottom:2px}
  #inputbar.big #grip{display:flex}
  #grip .gbar{width:72px;align-self:stretch;display:flex;align-items:center;justify-content:center;
    cursor:ns-resize;touch-action:none}
  #grip .gbar::before{content:"";display:block;width:32px;height:4px;border-radius:999px;background:var(--outline);opacity:.4}
  #grip .gtools{position:absolute;right:0;top:50%;transform:translateY(-50%);display:flex;gap:5px}
  #grip .gtools button{display:inline-grid;place-items:center;background:var(--card);color:var(--sub);border:0;
    border-radius:999px;font-size:11px;font-weight:500;line-height:1;padding:3px 8px;cursor:pointer;
    font-family:inherit;min-height:var(--gtoolh)}
  #grip .gtools button svg.ic{width:14px;height:14px}
  /* Expanded: the box takes the whole column and the row's buttons drop underneath it. Left in a
     row, they ate a third of the width and the "expanded" editor wrapped every three words —
     narrower than the bar it replaced. */
  #inputbar.big{display:grid;gap:8px;grid-template-columns:minmax(0,1fr);
    grid-template-rows:auto minmax(0,1fr) auto;grid-template-areas:"grip" "send" "keys";min-height:0}
  #inputbar.big > *{max-width:760px;width:100%;margin-left:auto;margin-right:auto}
  #inputbar.big #grip{grid-area:grip;margin-bottom:0}
  #inputbar.big #keys{grid-area:keys;margin-bottom:0}
  #inputbar.big #sendrow{grid-area:send;min-height:0;
    display:grid;gap:6px;grid-template-columns:auto auto minmax(0,1fr) auto;
    grid-template-rows:minmax(0,1fr) auto;grid-template-areas:"box box box box" "notes more . send"}
  #inputbar.big #inputtext{max-height:none;height:100%;grid-area:box;border-radius:16px}
  #inputbar.big #notesbtn{grid-area:notes}
  #inputbar.big #morebtn{grid-area:more}
  #inputbar.big #sendbtn{grid-area:send}
  /* A phone held sideways has about 390px of height. Nothing is dropped here: the rows that are
     chips and readouts rather than thumb targets simply stop being sized as though they were. */
  @media (max-height:500px){
    #termbar{min-height:46px;padding-top:2px;padding-bottom:2px}
    #grip{--gtoolh:20px;margin-bottom:0}
    #inputbar{padding-top:6px}
    #keys button{min-height:34px}
    #presets{max-height:30vh}
    .tiles{padding-top:8px}
    .tile .ti{width:46px;height:46px}
  }
  /* Dropping a file anywhere on the conversation should work, so the whole overlay is the target. */
  #term.dropping{outline:2px dashed var(--accent);outline-offset:-6px}
  /* Files an agent handed over. Lives in the header rather than inside a conversation: it is the
     one thing you want to reach without first knowing which terminal produced it. */
  /* Open a project: the folders in ~/PycharmProjects, under the header like the files tray. */
  #projs{display:none;position:sticky;top:0;z-index:6;background:var(--panel);
    border-bottom:1px solid var(--outlineVariant);padding:10px 12px 6px}
  #projs.on{display:block}
  #projs .nsearch{margin-bottom:8px}
  #pquery{flex:1;min-width:0;background:transparent;border:0;outline:none;color:var(--text);
    padding:9px 0;font-family:inherit;font-size:14px;-webkit-appearance:none;appearance:none}
  #projlist{max-height:min(55vh,420px);overflow-y:auto;overscroll-behavior:contain;
    -webkit-overflow-scrolling:touch}
  .prow{display:flex;align-items:center;gap:8px;padding:10px 12px 10px 16px;margin-bottom:6px;
    background:var(--card);border-radius:12px}
  .prow .pn{flex:1;min-width:0}
  .prow .pn b{display:block;font-size:14px;line-height:20px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .prow .pn span{font-size:11px;line-height:16px;color:var(--sub)}
  .prow button{flex:none;height:32px;font-size:12px;font-weight:500;border-radius:999px;padding:0 12px;cursor:pointer;
    border:0;background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  .prow button.go{background:var(--accent);color:var(--onAccent)}
  .prow .onb{font-size:11px;line-height:16px;font-weight:500;color:var(--onPrimaryContainer);background:var(--primaryContainer);
    border-radius:8px;padding:0 6px;margin-left:6px;vertical-align:1px}
  @media (pointer:coarse){ #pquery{font-size:16px} .prow button{min-height:36px} }
  /* The mark filter fills its pill while it is filtering (.tb.on): a board hiding most of itself has
     to say so somewhere that is always on screen, or you go looking for terminals that are simply
     not being drawn. */
  #markcount:empty{display:none}
  #traybadge:empty{display:none}
  #traybadge{position:absolute;top:-3px;right:-3px;min-width:16px;height:16px;
    border-radius:999px;background:var(--accent);color:var(--onAccent);font-size:11px;font-weight:500;
    line-height:16px;text-align:center;padding:0 4px}
  #tray{display:none;position:sticky;top:0;z-index:6;background:var(--panel);
    border-bottom:1px solid var(--outlineVariant);max-height:min(60vh,420px);overflow-y:auto;
    padding:8px 12px}
  #tray.on{display:block}
  #tray .f{display:flex;align-items:flex-start;gap:12px;padding:10px 14px;margin-bottom:6px;
    background:var(--card);border-radius:12px;color:var(--text);text-decoration:none}
  #tray .f:active{background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  #tray .f .fi{flex:none;color:var(--sub);padding-top:1px}
  /* Name, facts and note each on a line of their own. They were inline spans, so the name and
     everything after it ran together as one line, past the card's edge — and an inline box
     ignores text-overflow, so nothing was ever clipped with an ellipsis either. */
  #tray .f .fb{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}
  #tray .f .fn{display:block;font-size:14px;line-height:20px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #tray .f .fm{display:block;font-size:11px;line-height:16px;color:var(--sub);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #tray .f .fd{font-variant-numeric:tabular-nums}
  #tray .f .fnote{font-size:11px;line-height:1.45455;color:var(--sub);overflow:hidden;overflow-wrap:anywhere;
    display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
  #tray .tnone{color:var(--sub);font-size:12px;padding:10px 4px}
  /* project file browser — the project's own directory, walkable from the phone. An agent says "see
     Sources/FleetView/Remote/WebServer.swift:120" and until now there was no way to look. */
  #fb{position:fixed;top:0;left:0;right:0;height:100%;height:100dvh;z-index:56;background:var(--bg);
    padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right);
    display:none;flex-direction:column;overflow:hidden;overscroll-behavior:none}
  #fb.show{display:flex}
  /* Same swipe-back treatment as #term — one gesture, so one look (see swipeBack). */
  #fb.dragging{transition:none}
  #fb.settle{transition:transform .2s cubic-bezier(.22,.8,.3,1)}
  #fb.dragging,#fb.settle{box-shadow:-22px 0 46px rgba(0,0,0,.55)}
  #fbbar{display:flex;align-items:center;gap:4px;padding:8px 8px;background:var(--panel);
    border-bottom:1px solid var(--outlineVariant);padding-top:max(8px,env(safe-area-inset-top))}
  #fbbar button{flex:none;display:grid;place-items:center;width:40px;height:40px;padding:0;border:0;border-radius:999px;
    background:transparent;color:var(--text);cursor:pointer}
  #fbbar button:active{background:color-mix(in srgb,var(--text) 12%,transparent)}
  #fbbar button[disabled]{opacity:.38}
  #fbbar .fbname{font-size:16px;line-height:24px;font-weight:500;flex:1;min-width:0;padding:0 4px;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis}
  /* The absolute path in full, wrapped rather than clipped: knowing exactly where you are is the
     point, and an ellipsis through the middle of a path defeats it. Selectable, because
     long-press-to-select is the fallback when the clipboard API is missing (plain http is not a
     secure context, so on the LAN it usually is). */
  #fbpath{display:flex;align-items:center;gap:8px;padding:8px 12px 8px 16px;background:var(--panel);
    border-bottom:1px solid var(--outlineVariant);font-size:12px;line-height:16px;color:var(--sub);
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  #fbcrumbs{flex:1;min-width:0;word-break:break-all;user-select:text;-webkit-user-select:text}
  #fbcrumbs b{color:var(--accent);font-weight:500;cursor:pointer}
  .fbcopy{flex:none;display:inline-flex;align-items:center;gap:4px;height:28px;padding:0 10px;background:var(--card);color:var(--sub);
    border:0;border-radius:999px;font-size:12px;font-weight:500;cursor:pointer;font-family:inherit}
  .fbcopy:active{background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  #fbbody{flex:1;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;padding:10px 12px}
  #fbbody > *{max-width:900px;margin-left:auto;margin-right:auto}
  .fbrow{display:flex;align-items:center;gap:12px;padding:6px 6px 6px 16px;min-height:48px;margin-bottom:6px;
    background:var(--card);border-radius:12px;cursor:pointer}
  .fbrow:active{background:var(--cardHover)}
  .fbrow .fbi{flex:none;color:var(--sub)}
  .fbrow .fbn{flex:1;min-width:0;font-size:14px;line-height:20px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .fbrow .fbs{flex:none;font-size:11px;color:var(--sub)}
  .fbrow .fbc{flex:none;display:grid;place-items:center;width:36px;height:36px;padding:0;background:transparent;color:var(--sub);
    border:0;border-radius:999px;cursor:pointer}
  .fbrow .fbc:active{background:color-mix(in srgb,var(--text) 12%,transparent)}
  .fbnote{color:var(--sub);font-size:12px;padding:14px 4px;text-align:center}
  .fbnote a{color:var(--accent)}
  pre.fbtext{margin:0;white-space:pre-wrap;word-break:break-word;font-size:12px;line-height:18px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text);
    background:var(--codeBg);border:1px solid var(--outlineVariant);border-radius:12px;padding:12px 14px}
  img.fbimg{max-width:100%;display:block;margin:0 auto;border-radius:12px;background:var(--card)}
  iframe.fbpdf{width:100%;height:78vh;border:1px solid var(--outlineVariant);border-radius:12px;background:#fff}
  /* A markdown file: rendered by default, editable in place. The bar stays in view over a long
     document, because Save is the button you need wherever you have scrolled to. */
  .fbtools{display:flex;align-items:center;gap:6px;flex-wrap:wrap;position:sticky;top:-10px;z-index:1;
    background:var(--bg);padding:6px 0 8px}
  .fbtools button{display:inline-flex;align-items:center;gap:4px;height:32px;padding:0 12px;
    font-size:12px;font-weight:500;color:var(--text);background:var(--card);border:0;border-radius:999px;cursor:pointer}
  .fbtools button svg.ic{width:16px;height:16px}
  .fbtools button[disabled]{opacity:.38;cursor:default}
  .fbtools button.on{color:var(--onSecondaryContainer);background:var(--secondaryContainer)}
  .fbtools button.save:not([disabled]){color:var(--onAccent);background:var(--accent)}
  .fbtools .fbstate{flex:1;min-width:0;text-align:right;font-size:11px;color:var(--sub)}
  .fbtools .fbstate.dirty{color:var(--amber)}
  .fbmd{font-size:14px;line-height:22px;padding:2px 2px 30px}
  .fbmd h1{font-size:20px;line-height:28px}.fbmd h2{font-size:16px}.fbmd h3{font-size:14px}
  textarea.fbedit{display:block;width:100%;box-sizing:border-box;height:calc(100dvh - 210px);min-height:240px;
    resize:vertical;margin:0;padding:12px 14px;font-size:14px;line-height:22px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text);background:var(--codeBg);
    border:1px solid var(--outlineVariant);border-radius:12px;outline:none;tab-size:4}
  textarea.fbedit:focus{border-color:var(--accent)}
  /* Sharing a conversation: the trigger list's sheet, with a choice of what goes out. */
  #share{display:none;position:fixed;inset:0;z-index:60}
  #share.on{display:block}
  #share .tscrim{position:absolute;inset:0;background:var(--scrim)}
  #share .tsheet{position:absolute;top:0;right:0;bottom:0;width:min(440px,100vw);display:flex;flex-direction:column;
    background:var(--panel);box-shadow:0 0 24px rgba(0,0,0,.35)}
  @media (max-width:640px){ #share .tsheet{top:auto;left:0;width:auto;max-height:86dvh;border-radius:16px 16px 0 0} }
  #share .thead{display:flex;align-items:center;gap:10px;padding:12px 8px 10px 20px;border-bottom:1px solid var(--outlineVariant)}
  #share .thead b{font-size:16px;line-height:24px;font-weight:500}
  #share .thead .tname{flex:1;min-width:0;font-size:12px;color:var(--sub);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #share .thead button{flex:none;width:40px;height:40px;border:0;background:none;color:var(--sub);cursor:pointer;
    display:flex;align-items:center;justify-content:center;border-radius:999px}
  #sharebody{overflow:auto;padding:12px 16px calc(24px + env(safe-area-inset-bottom));-webkit-overflow-scrolling:touch}
  .sopt{display:flex;gap:12px;align-items:flex-start;background:var(--card);border:1px solid transparent;border-radius:12px;
    padding:12px;margin-bottom:8px;cursor:pointer}
  .sopt.on{border-color:var(--accentEdgeOn);background:var(--accentSoft)}
  .sopt input{flex:none;width:18px;height:18px;margin:1px 0 0;accent-color:var(--accent)}
  .sopt b{display:block;font-size:14px;line-height:20px;font-weight:500}
  .sopt span{display:block;font-size:12px;line-height:18px;color:var(--sub);margin-top:2px}
  .sopt.off{opacity:.45;pointer-events:none}
  .snote{font-size:12px;line-height:18px;color:var(--sub);margin:12px 2px 0}
  .sbtns{display:flex;flex-wrap:wrap;gap:8px;margin-top:16px}
  .sbtn{height:40px;padding:0 18px;border:0;border-radius:999px;background:var(--card);color:var(--text);
    font-size:14px;font-weight:500;cursor:pointer}
  .sbtn.pri{background:var(--accent);color:var(--onAccent)}
  .sbtn:disabled{opacity:.45;cursor:default}
  .slink{margin-top:4px;padding:12px;border-radius:8px;background:var(--bg);font-size:13px;line-height:19px;word-break:break-all;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace;-webkit-user-select:all;user-select:all}
  .sbusy{display:flex;align-items:center;gap:10px;padding:18px 2px;font-size:14px;color:var(--sub)}
  .serr{padding:12px;border-radius:12px;background:var(--errorContainer);color:var(--onErrorContainer);
    font-size:13px;line-height:19px;word-break:break-word}
  .sok{font-size:14px;line-height:20px;font-weight:500;margin:4px 2px 8px}
  /* Picking what to share: a ring beside every message, filled once it is in. Thinking stays out of
     reach — it is never shared. Links are inert while picking, so a tap only ever picks. */
  #chat.picking .msg{position:relative;padding-left:36px;cursor:pointer;-webkit-user-select:none;user-select:none}
  #chat.picking .msg.tool{padding-left:44px}
  #chat.picking .msg::before{content:"";position:absolute;left:4px;top:0;width:22px;height:22px;border-radius:999px;
    border:2px solid var(--outline);box-sizing:border-box}
  #chat.picking .msg.user::before{top:11px}
  #chat.picking .msg.tool::before{left:12px;top:7px}
  #chat.picking .msg.picked::before{background:var(--accent);border-color:var(--accent)}
  #chat.picking .msg.picked::after{content:"";position:absolute;left:12px;top:4px;width:5px;height:10px;
    border:solid var(--onAccent);border-width:0 2px 2px 0;transform:rotate(45deg)}
  #chat.picking .msg.user.picked::after{top:15px}
  #chat.picking .msg.tool.picked::after{left:20px;top:11px}
  #chat.picking .msg.think{opacity:.3;pointer-events:none}
  #chat.picking .msg .cp{display:none}
  #chat.picking a{pointer-events:none}
  #pickbar{display:none;flex:none;align-items:center;gap:8px;background:var(--panel);border-top:1px solid var(--outlineVariant);
    padding:10px 16px calc(10px + env(safe-area-inset-bottom))}
  #pickbar .pn{flex:1;min-width:0;font-size:14px;line-height:20px;font-weight:500}
  #term.picking #pickbar{display:flex}
  #term.picking #inputbar,#term.picking #jump,#term.picking #perm{display:none}
  /* FleetView's own triggers: the same sheet, opened from the board header instead of a card. */
  #ftrig{display:none;position:fixed;inset:0;z-index:60}
  #ftrig.on{display:block}
  #ftrig .tscrim{position:absolute;inset:0;background:var(--scrim)}
  #ftrig .tsheet{position:absolute;top:0;right:0;bottom:0;width:min(440px,100vw);display:flex;flex-direction:column;
    background:var(--panel);box-shadow:0 0 24px rgba(0,0,0,.35)}
  @media (max-width:640px){ #ftrig .tsheet{top:auto;left:0;width:auto;max-height:86dvh;border-radius:16px 16px 0 0} }
  #ftrig .thead{display:flex;align-items:center;gap:10px;padding:12px 8px 10px 20px;border-bottom:1px solid var(--outlineVariant)}
  #ftrig .thead b{font-size:16px;line-height:24px;font-weight:500}
  #ftrig .thead .tname{flex:1;min-width:0;font-size:12px;color:var(--sub);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #ftrig .thead button{flex:none;width:40px;height:40px;border:0;background:none;color:var(--sub);cursor:pointer;
    display:flex;align-items:center;justify-content:center;border-radius:999px}
  #ftriglist{overflow:auto;padding:12px 16px calc(24px + env(safe-area-inset-bottom));-webkit-overflow-scrolling:touch}
  #ftriglist .tnote{font-size:12px;line-height:18px;color:var(--sub);margin:2px 0 12px}
  #ftrigcount:empty{display:none}
  .trow .tg.run{color:var(--onPrimaryContainer);background:var(--primaryContainer);border-color:transparent}
  .trow .tg.bad{color:var(--onErrorContainer);background:var(--errorContainer);border-color:transparent}
  .trow .fsrc{margin-top:8px;font-size:12px;line-height:18px;color:var(--sub)}
  .trow .fsrc b{font-weight:500;color:var(--text)}
  .trow .fsrc code{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:11px;color:var(--text);
    word-break:break-all;-webkit-user-select:all;user-select:all}
  .trow .facts{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
  .trow .facts button{height:30px;padding:0 12px;border:0;border-radius:999px;background:var(--secondaryContainer);
    color:var(--onSecondaryContainer);font-size:12px;font-weight:500;cursor:pointer}
  .trow .facts button.danger{background:var(--errorContainer);color:var(--onErrorContainer)}
  .trow .facts button:disabled{opacity:.45;cursor:default}
  /* The trigger list: a sheet from the right on a wide screen, from the bottom on a phone. */
  #trig{display:none;position:fixed;inset:0;z-index:60}
  #trig.on{display:block}
  #trig .tscrim{position:absolute;inset:0;background:var(--scrim)}
  #trig .tsheet{position:absolute;top:0;right:0;bottom:0;width:min(440px,100vw);display:flex;flex-direction:column;
    background:var(--panel);box-shadow:0 0 24px rgba(0,0,0,.35)}
  @media (max-width:640px){ #trig .tsheet{top:auto;left:0;width:auto;max-height:86dvh;border-radius:16px 16px 0 0} }
  #trig .thead{display:flex;align-items:center;gap:10px;padding:12px 8px 10px 20px;border-bottom:1px solid var(--outlineVariant)}
  #trig .thead b{font-size:16px;line-height:24px;font-weight:500}
  #trig .thead .tname{flex:1;min-width:0;font-size:12px;color:var(--sub);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #trig .thead button{flex:none;width:40px;height:40px;border:0;background:none;color:var(--sub);cursor:pointer;
    display:flex;align-items:center;justify-content:center;border-radius:999px}
  #triglist{overflow:auto;padding:12px 16px calc(24px + env(safe-area-inset-bottom));-webkit-overflow-scrolling:touch}
  #triglist .tnote{font-size:12px;line-height:18px;color:var(--sub);margin:2px 0 12px}
  #triglist .tsec{font-size:12px;line-height:16px;font-weight:500;color:var(--sub);margin:14px 0 8px}
  #triglist .tsec span{color:var(--outline);margin-left:6px}
  .trow{display:flex;gap:12px;align-items:flex-start;background:var(--card);border-radius:12px;padding:12px;margin-bottom:8px}
  .trow.busy{opacity:.7}
  .trow .ti{flex:none;width:30px;height:30px;border-radius:999px;display:flex;align-items:center;justify-content:center;
    background:var(--secondaryContainer);color:var(--onSecondaryContainer)}
  .trow .tm{flex:1;min-width:0}
  .trow .tt{display:flex;flex-wrap:wrap;align-items:center;gap:6px}
  .trow .tt b{font-size:14px;line-height:20px;font-weight:500}
  .trow .tg{font-size:11px;line-height:16px;font-weight:500;color:var(--sub);border:1px solid var(--outlineVariant);
    border-radius:999px;padding:0 6px}
  .trow .tid{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:11px;line-height:16px;color:var(--sub);
    margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .trow .tmeta{font-size:12px;line-height:18px;color:var(--sub);margin-top:3px}
  .trow .tbody{margin-top:8px;padding:10px;border-radius:8px;background:var(--bg);cursor:pointer}
  .trow .ttext{font-size:12px;line-height:18px;white-space:pre-wrap;word-break:break-word;
    display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}
  .trow .tcode{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:11px;line-height:16px;color:var(--sub);
    margin-top:6px;white-space:pre-wrap;word-break:break-all;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
  .trow .tbody.open .ttext,.trow .tbody.open .tcode{display:block;-webkit-line-clamp:unset}
  .trow .tdel{flex:none;width:36px;height:36px;margin:-4px -4px 0 0;border:0;background:none;color:var(--sub);cursor:pointer;
    display:flex;align-items:center;justify-content:center;border-radius:999px}
  @media (hover:hover){ .trow .tdel:hover{color:var(--red);background:var(--redSoft)} }
  .trow .tbusy{font-size:12px;line-height:18px;font-weight:500;color:var(--accent);margin-top:8px}
  #triglist .tempty{text-align:center;color:var(--sub);font-size:12px;line-height:18px;padding:36px 12px}
  #triglist .tempty b{display:block;color:var(--text);font-size:14px;line-height:20px;font-weight:500;margin-bottom:4px}
  /* iOS zooms the page into any field under 16px the moment it is focused. */
  @media (pointer:coarse){ textarea.fbedit{font-size:16px} }
</style>
</head>
<body>
<div id="panel"><button class="pcollapse" onclick="togglePanel()"><i data-ic="chevron-up" class="s16"></i><span data-i18n="common.collapse"></span></button>
  <iframe id="panelframe" sandbox="allow-scripts allow-same-origin allow-popups allow-forms" src="about:blank"></iframe></div>
<header>
  <span class="brand"><span class="logo"><i data-ic="layout-grid"></i></span><span class="bname tm">FleetView</span></span>
  <span class="muted lm" id="counts"></span>
  <span class="spacer"></span>
  <span id="pills"></span>
  <button id="markbtn" class="tb" onclick="toggleOnlyMarked()" data-i18n-title="head.markFilter"><i data-ic="bookmark"></i><span id="markcount"></span></button>
  <button id="ftrigbtn" class="tb" onclick="openFtrig()" data-i18n-title="ftrig.title" data-i18n-aria="ftrig.title"><i data-ic="zap"></i><span id="ftrigcount"></span></button>
  <button id="schemebtn" class="tb" onclick="cycleScheme()"></button>
  <button id="projbtn" class="tb" onclick="toggleProjects()" data-i18n-title="head.projTitle" data-i18n-aria="head.projAria"><i data-ic="folder-open"></i></button>
  <button id="traybtn" class="tb" onclick="toggleTray()" data-i18n-title="head.trayTitle" data-i18n-aria="head.trayAria"><i data-ic="inbox"></i><span id="traybadge"></span></button>
  <button class="netsig" id="netsig" onclick="netToast()" data-i18n-aria="net.aria"></button>
</header>
<div id="tray"><div id="traylist"></div></div>
<div id="projs">
  <label class="nsearch"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/></svg>
    <input id="pquery" type="search" enterkeyhint="go" autocomplete="off" data-i18n-placeholder="proj.search" oninput="renderProjects()"></label>
  <div id="projlist"></div>
</div>
<main id="root"><div class="empty" data-i18n="common.loading"></div></main>
<div id="ghosts" aria-hidden="true"></div>

<div id="chip"></div>
<div id="dock"></div>

<div id="term">
  <!-- One bar, laid over the transcript rather than stacked above it, so it can slide away while you
       read and come back when you scroll up (see headBar). The status strip is its subtitle. -->
  <div id="thead">
    <div id="termbar">
      <button class="ib" onclick="closeTerm()" data-i18n-aria="common.back" data-i18n-title="common.back"><svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg></button>
      <div class="ttl"><span class="tname" id="termname"></span><div id="sinfo"></div></div>
      <button class="netsig tsig" id="tnetsig" onclick="netToast()" data-i18n-aria="net.aria"></button>
      <div id="tabs">
        <button id="tabChat" class="on" onclick="setView('chat')" data-i18n="tab.chat"></button>
        <button id="tabTerm" onclick="setView('term')" data-i18n="tab.term"></button>
      </div>
      <button class="ib" id="sharebtn" onclick="openShare()" data-i18n-title="share.button" data-i18n-aria="share.button"><i data-ic="share"></i></button>
      <button class="ib" onclick="popTerm()" data-i18n-title="term.popOut" data-i18n-aria="term.popOut"><svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg></button>
    </div>
  </div>
  <div id="chat" class="on"><div id="chatnote" data-i18n="common.loading"></div></div>
  <div id="stickyq"><div class="sq"></div></div>
  <button id="jump" onclick="jumpLatest()" data-i18n-title="chat.jump" data-i18n-aria="chat.jump"><i data-ic="arrow-down"></i></button>
  <iframe id="termframe" src="about:blank" allow="clipboard-read; clipboard-write"></iframe>
  <div id="termerr"></div>
  <div id="perm"></div>
  <div id="pickbar"><span class="pn" id="pickn"></span>
    <button class="sbtn" onclick="endPick()" data-i18n="share.cancel"></button>
    <button class="sbtn pri" id="pickgo" onclick="sharePicked()" data-i18n="share.pickGo"></button>
  </div>
  <div id="inputbar">
    <div id="grip"><span class="gbar"></span><span class="gtools">
      <button class="fsz" onclick="taFont(-1)" data-i18n-title="composer.smaller">A−</button>
      <button class="fsz" onclick="taFont(1)" data-i18n-title="composer.larger">A+</button>
      <button id="expand" onclick="toggleBig()" data-i18n-title="composer.collapseEditor"></button>
    </span></div>
    <div id="keys">
      <button class="skey" onclick="scrollTerm('up')">⇞</button>
      <button class="skey" onclick="scrollTerm('down')">⇟</button>
      <button onclick="key('Escape')">Esc</button>
      <button onclick="key('Enter')">⏎</button>
      <button onclick="key('Up')">↑</button>
      <button onclick="key('Down')">↓</button>
      <button onclick="key('Left')">←</button>
      <button onclick="key('Right')">→</button>
      <button onclick="typeRaw('/')" data-i18n-title="keys.slash">/</button>
      <button onclick="key('Tab')">Tab</button>
      <button onclick="key('C-c')">^C</button>
      <button onclick="key('BSpace')">⌫</button>
    </div>
    <div id="sendrow">
      <button id="notesbtn" class="rb" data-pane="notes" data-i18n-title="notes.btnTitle" data-i18n-aria="notes.btnAria"><svg viewBox="0 0 24 24"><path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1.2"/><circle cx="4.5" cy="12" r="1.2"/><circle cx="4.5" cy="18" r="1.2"/></svg></button>
      <textarea id="inputtext" rows="1"></textarea>
      <button id="morebtn" class="rb" data-pane="more" data-i18n-title="more.btnTitle" data-i18n-aria="more.btnAria"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/></svg></button>
      <button id="sendbtn" data-i18n="composer.send"></button>
    </div>
  </div>
  <!-- Under the composer, where the keyboard would be — the WeChat arrangement. -->
  <div id="drawer">
    <div class="dpane" data-pane="notes">
      <div class="nhead">
        <label class="nsearch"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/></svg>
          <input id="pfind" type="search" enterkeyhint="search" autocomplete="off" data-i18n-placeholder="notes.search" oninput="renderPresets()"></label>
        <button class="nact" onclick="addNote()" data-i18n-title="notes.add" data-i18n-aria="notes.add"><i data-ic="plus"></i></button>
        <button class="nact" id="nedit" onclick="toggleEditPresets()" data-i18n="notes.edit"></button>
      </div>
      <div id="presets"></div>
    </div>
    <div class="dpane" data-pane="more">
      <input id="imgfile" type="file" multiple hidden>
      <div class="tiles">
        <button class="tile" id="imgbtn" data-i18n-title="more.attachTitle"><span class="ti"><svg viewBox="0 0 24 24"><path d="M20 11.5l-8.1 8.1a5 5 0 0 1-7.1-7.1l8.5-8.5a3.3 3.3 0 0 1 4.7 4.7l-8.5 8.5a1.7 1.7 0 0 1-2.4-2.4l7.8-7.8"/></svg></span><span class="tl" data-i18n="more.attach"></span></button>
        <button class="tile" onclick="closeDrawer();toggleBig()"><span class="ti"><svg viewBox="0 0 24 24"><path d="M14 4h6v6M10 20H4v-6M20 4l-6.5 6.5M4 20l6.5-6.5"/></svg></span><span class="tl" id="bigLabel" data-i18n="more.editor"></span></button>
        <button class="tile" onclick="closeDrawer();typeRaw('/')" data-i18n-title="keys.slash"><span class="ti ttxt">/</span><span class="tl" data-i18n="more.commands"></span></button>
        <button class="tile" onclick="closeDrawer();key('Escape')" data-i18n-title="more.interruptTitle"><span class="ti ttxt">esc</span><span class="tl" data-i18n="more.interrupt"></span></button>
      </div>
    </div>
  </div>
</div>

<div id="fb">
  <div id="fbbar">
    <button onclick="fbClose()" data-i18n-title="common.back" data-i18n-aria="common.back"><i data-ic="chevron-left"></i></button>
    <span class="fbname" id="fbname"></span>
    <button id="fbreload" onclick="fbRefresh()" data-i18n-title="fb.reload" data-i18n-aria="fb.reload"><i data-ic="rotate-cw"></i></button>
    <button id="fbtab" onclick="fbNewTab()" data-i18n-title="fb.newTab" data-i18n-aria="fb.newTab"><i data-ic="external-link"></i></button>
    <button id="fbup" onclick="fbUp()" data-i18n-title="fb.up" data-i18n-aria="fb.up"><i data-ic="corner-left-up"></i></button>
  </div>
  <div id="fbpath"><span id="fbcrumbs"></span><button class="fbcopy" onclick="fbCopyHere()"><i data-ic="copy" class="s14"></i><span data-i18n="fb.copyPathBtn"></span></button></div>
  <div id="fbbody"></div>
</div>

<div id="ftrig">
  <div class="tscrim" onclick="closeFtrig()"></div>
  <div class="tsheet" role="dialog" aria-modal="true">
    <div class="thead"><b data-i18n="ftrig.title"></b><span class="tname" data-i18n="ftrig.sub"></span>
      <button onclick="closeFtrig()" data-i18n-title="common.back" data-i18n-aria="common.back"><i data-ic="x"></i></button></div>
    <div id="ftriglist"></div>
  </div>
</div>

<div id="trig">
  <div class="tscrim" onclick="closeTrig()"></div>
  <div class="tsheet" role="dialog" aria-modal="true">
    <div class="thead"><b data-i18n="trig.title"></b><span class="tname" id="trigname"></span>
      <button onclick="closeTrig()" data-i18n-title="common.back" data-i18n-aria="common.back"><i data-ic="x"></i></button></div>
    <div id="triglist"></div>
  </div>
</div>

<div id="share">
  <div class="tscrim" onclick="closeShare()"></div>
  <div class="tsheet" role="dialog" aria-modal="true">
    <div class="thead"><b data-i18n="share.title"></b><span class="tname" id="sharename"></span>
      <button onclick="closeShare()" data-i18n-title="common.back" data-i18n-aria="common.back"><i data-ic="x"></i></button></div>
    <div id="sharebody"></div>
  </div>
</div>

<script>
/* ---------- requests that cannot hang ----------
   On a bad line the page used to drop off and stay off until it was reloaded. Nothing here had a
   deadline: a request sent just before the network went away — or before the phone moved to
   another network, or slept — waits for an answer on a connection that no longer exists, and a
   browser lets a page have six connections to one host. The polls below fire every second or two,
   so six such requests piled up within seconds, and every request after them, the ping that
   decides "offline" included, queued behind them for good. Reloading worked only because it threw
   the six away. So every request gets a deadline and can be dropped on demand (`abortAll`), and
   the polls never overlap themselves (`poll`). `timeout:0` opts out, for the few requests whose
   answer must not be guessed at: a send, whose failure path puts the text back to be sent again,
   and a save. */
const FETCH_DEADLINE=12000;
const inflight=new Set();
const fetchNoDeadline=window.fetch.bind(window);
window.fetch=function(input,init){
  init=Object.assign({},init);
  const ms=init.timeout===undefined?FETCH_DEADLINE:init.timeout; delete init.timeout;
  if(!ms) return fetchNoDeadline(input,init);
  const ctl=new AbortController(), theirs=init.signal;
  if(theirs){ if(theirs.aborted) ctl.abort(); else theirs.addEventListener('abort',()=>ctl.abort(),{once:true}); }
  init.signal=ctl.signal;
  inflight.add(ctl);
  /* Left running after the headers arrive: the body can stall too, and aborting a request that
     has finished is a no-op. */
  setTimeout(()=>{ ctl.abort(); inflight.delete(ctl); },ms);
  return fetchNoDeadline(input,init);
};
function abortAll(){ for(const c of inflight) c.abort(); inflight.clear(); }
/* Run `fn` every `ms`, skipping a beat while the last run is still out — at most one request per
   poll on the wire, however slow the line. */
function poll(fn,ms,now=true){
  let busy=false;
  const run=async()=>{ if(busy) return; busy=true; try{ await fn(); }catch(e){} finally{ busy=false; } };
  if(now) run();
  return setInterval(run,ms);
}

/* ---------- words ----------
   Every word the page shows lives here, once per language, key for key — the markup and the code
   below only ever name a key. Two tables side by side rather than strings scattered through 2,000
   lines is what lets a missing translation be found by a machine (see the check underneath) instead
   of by someone reading the English page and spotting Chinese.
   A value may hold {placeholders}. An English value that depends on a count is {one,other}, picked
   by vars.n; Chinese does not inflect, so its values are always plain strings. Values are inserted
   into markup as they are, so they must stay free of " < > & — anything user-supplied goes in
   through a placeholder, escaped by the caller. Proper nouns (FleetView, Claude, Codex, Shell, tmux,
   Tailscale) and key names (Esc, Tab, ⏎) are the same in both. */
const I18N={
  zh:{
    'common.loading':'加载中…','common.back':'返回','common.retry':'重试',
    'common.collapse':'收起','common.expand':'展开','common.newTerm':'新终端','common.tokens':'{n} tokens',
    'status.working':'运行中','status.idle':'空闲','status.needsYou':'等你处理','status.shell':'Shell',
    'status.exited':'已退出','status.closed':'已关闭','status.done':'刚完成',
    'time.now':'刚刚','time.justNow':'刚刚','time.minAgo':'{n} 分钟前','time.hourAgo':'{n} 小时前','time.dayAgo':'{n} 天前',
    'time.today':'今天 {time}','time.yesterday':'昨天 {time}','time.date':'{m}月{d}日 {time}','time.dateYear':'{y}年{m}月{d}日 {time}',
    'head.markFilter':'只显示加了书签的终端','head.projTitle':'从 ~/PycharmProjects 打开项目','head.projAria':'打开项目',
    'head.trayTitle':'agent 发给你的文件','head.trayAria':'收到的文件',
    'count.projects':'{n} 个项目','count.terminals':'{n} 个终端','badge.needs':'{n} 个等你处理','badge.running':'{n} 个运行中',
    'scheme.btnAuto':'外观：跟随 Mac','scheme.btnDark':'外观：深色（点按切换）','scheme.btnLight':'外观：浅色（点按切换）',
    'scheme.toastAuto':'外观跟随 Mac','scheme.toastDark':'外观：深色','scheme.toastLight':'外观：浅色',
    'zone.now':'进行中','zone.dormant':'两小时内没动过',
    'board.banner':'网页终端不可用 — 运行 {cmd} 后重新启动 FleetView。状态仍会照常显示。',
    'empty.noMarked':'没有加了书签的终端','empty.noMarkedSub':'看板现在只显示加了书签的终端。','mark.showAll':'显示全部终端',
    'empty.noProjects':'还没有项目','empty.noProjectsSub':'在 Mac 上添加一个。',
    'toast.onlyMarked':'只显示加了书签的终端','toast.showAll':'显示全部终端',
    'proj.lastActivity':'最后活动','proj.browse':'浏览项目文件','proj.newTerm':'新建终端',
    'proj.nameFolded':'点击展开','proj.nameOpen':'点击复制路径',
    'card.lastRun':'上一轮用了 {time}','card.lastActivity':'最后一次活动','card.marked':'已加书签',
    'card.hidden':'窗口已隐藏，agent 在后台继续运行',
    'card.idTitle':'单击复制终端 ID（{id}），双击复制对话文件路径','card.idCopied':'已复制','card.idPath':'路径',
    'toast.noTranscript':'这个终端没有对话记录',
    'dock.mark':'加书签','dock.unmark':'取消书签','dock.duplicate':'复制','dock.rename':'重命名',
    'dock.hide':'隐藏窗口','dock.show':'显示窗口','dock.leave':'移出组','dock.remove':'移除',
    'drag.drop':'松开：{action}',
    'drop.join':'松开：加入「{name}」','drop.groupWith':'松开：和「{name}」组成一组',
    'drop.leave':'松开：移出「{name}」','drop.moveTo':'松开：移到「{name}」','drop.group':'分组',
    'drop.noteWorking':'agent 正在跑，会被打断后带着记录重开','drop.noteCodex':'Codex 记录按日期存放，不用搬；会在新项目里重新打开',
    'drop.noteNoHistory':'还没有对话记录，只是换个项目','drop.noteMove':'对话记录一起搬过去，然后重新打开这段对话','prompt.rename':'重命名终端',
    'toast.openOnMac':'先在 Mac 上打开这个终端','toast.gone':'这个终端已经不在看板上了',
    'toast.notOpen':'这个终端现在没有在 Mac 上打开',
    'proj.search':'搜索 ~/PycharmProjects','proj.noMatch':'没有匹配的文件夹','proj.none':'~/PycharmProjects 里没有文件夹',
    'proj.onBoard':'已在看板','proj.go':'前往','proj.open':'打开',
    'toast.cantOpen':'打不开 {name}','toast.opened':'已打开 {name}',
    'tray.empty':'还没有收到文件',
    'tab.chat':'对话','tab.output':'输出','tab.term':'终端','term.popOut':'在新标签页打开终端','chat.jump':'跳到最新',
    'term.closed':'这个终端已经关闭',
    'term.closedHint':'它的会话已经不在了，所以 ttyd 的“按 ⏎ 重连”接不上任何东西。回到看板点这张卡片可以重新打开，并接着原来的对话。',
    'term.noMac':'连不上 Mac','term.noMacHint':'看板本身有回应，所以这通常只是网络暂时不稳。',
    'term.portDead':'终端端口没有回应',
    'term.portDeadHint':'对话走的是 FleetView 的 :{chat}；终端是另一个服务，在 :{port}。如果一直这样，说明这个端口在这里和 Mac 之间被挡住了。',
    'chat.retrying':'重试中…','chat.loadFailed':'读取会话失败：{err}','shell.empty':'屏幕上还没有内容。',
    'pm.bypass':'跳过权限','pm.acceptEdits':'自动接受编辑','pm.plan':'计划模式',
    'info.sharedTitle':'这段对话属于 {n} 个终端共用的同一个会话 — 想单独看这个终端，切到「终端」',
    'info.shared':'⇉ {n} 个终端共用','info.session':'会话 {id}',
    'info.branchesTitle':'这个会话因为回退或改写有 {n} 个分叉点 — 这里只显示当前分支','info.context':'上下文 {pct}% · {tok}',
    'perm.default':'等你决定',
    'chat.thinking':'思考','chat.input':'输入','chat.output':'输出','chat.failed':'失败','chat.copy':'复制',
    'chat.subagent':'子代理','chat.answerInTerm':'切到「终端」里回答','chat.empty':'还没有对话 — 发一条消息开始。',
    'diff.unchanged':'⋯ {n} 行未改动','diff.edit':'第 {n} 处修改',
    'toast.copied':'已复制','toast.pathCopied':'已复制路径','toast.copyFailed':'复制失败','toast.copyFailedLong':'复制失败 — 长按路径手动选择',
    'composer.send':'发送','composer.stop':'停止',
    'composer.placeholder':'输入消息 — 回车发送，Shift+回车换行','composer.placeholderShort':'输入消息',
    'composer.smaller':'缩小字号','composer.larger':'放大字号','composer.expandEditor':'展开编辑器','composer.collapseEditor':'收起编辑器',
    'keys.slash':'打开 agent 的斜杠命令菜单',
    'notes.btnTitle':'快捷命令（你的笔记）','notes.btnAria':'快捷命令','notes.search':'搜索快捷命令','notes.add':'添加快捷命令',
    'notes.edit':'编辑','notes.done':'完成','notes.delete':'删除','notes.noMatch':'没有匹配“{q}”的命令',
    'notes.none':'还没有快捷命令 — 点 + 添加，或在 Mac 的笔记里添加','notes.addPrompt':'添加快捷命令（保存到 Mac 的笔记）',
    'more.btnTitle':'附件、编辑器、按键','more.btnAria':'更多','more.attachTitle':'上传到 Mac，路径会填进输入框',
    'more.attach':'附件','more.editor':'编辑器','more.commands':'命令','more.interruptTitle':'打断 agent','more.interrupt':'中断',
    'toast.stuck':'没发出去：文字还停在 agent 的输入框里，点 ⏎ 再发一次',
    'upload.file':'文件','upload.netError':'网络错误','upload.cancelled':'已取消','toast.uploadFailed':'上传失败：{err}',
    'fb.reload':'从磁盘重新读取','fb.newTab':'在新标签页打开','fb.up':'上一级','fb.copyPathBtn':'路径','fb.copyPath':'复制路径',
    'fb.listFailed':'无法列出这个文件夹','fb.truncated':'只显示这个文件夹的前 {n} 项','fb.emptyDir':'这个文件夹是空的',
    'fb.download':'下载','fb.readFailed':'读不了这个文件',
    'fb.confirmReload':'放弃没保存的修改，重新读取磁盘上的版本？',
    'fb.confirmLeave':'有没保存的修改，确定离开？离开后修改会丢失。',
    'fb.confirmOverwrite':'这个文件在你编辑期间被改过了（可能是 agent 写的）。\n\n确定：用你的版本覆盖它\n取消：先不保存（点 ↻ 可以看磁盘上的新版本，但你的修改会丢）',
    'fb.whyLarge':'文件太大（超过 512 KB），这里只读','fb.whyEncoding':'不是 UTF-8 文本，这里只读',
    'fb.whyReadonly':'这个文件没有写权限','fb.whyDefault':'这里只读',
    'md.preview':'预览','md.edit':'编辑','md.undo':'撤销','md.undoTitle':'撤销 (⌘Z)','md.redo':'重做','md.redoTitle':'重做 (⇧⌘Z)',
    'md.save':'保存','md.saveTitle':'保存 (⌘S)','md.emptyFile':'（空文件）','md.unsaved':'未保存','md.saved':'已保存',
    'toast.saveNoMac':'保存失败：连不上 Mac','toast.saveFailed':'保存失败：{err}',
    'net.aria':'连接','net.local':'本机','net.lan':'局域网','net.tsDirect':'Tailscale 直连','net.tsRelay':'Tailscale 中转',
    'net.tsRelayVia':'Tailscale 中转（{relay}）','net.public':'外网','net.offline':'离线',
    'net.toastOff':'连不上 Mac，正在重试','net.toastOffLast':'连不上 Mac，正在重试（上次：{route}）',
    'net.latency':'延迟 {ms} ms','net.latencyRange':'延迟 {ms} ms（最近 {n} 次 {lo}–{hi} ms）',
    'net.node':'本设备：{node}','net.refreshed':'看板 {s} 秒前刷新',
    'net.reconnecting':'正在重连…','net.reconnected':'已重新连接','net.back':'已重新连上 Mac',
    'toast.attachedTo':'文件已附加到「{name}」的输入框',
    'trig.title':'触发器','trig.chip':'{n} 个触发器 · 点击查看',
    'ftrig.title':'FleetView 触发器','ftrig.sub':'由 FleetView 运行，不依赖任何卡片','ftrig.empty':'没有触发器',
    'ftrig.cron':'cron {c}','ftrig.every':'每 {d}','ftrig.at':'一次 · {t}','ftrig.watch':'变化时 · {p}',
    'ftrig.check':'条件成立时 · {c}','ftrig.manual':'手动 / 外部触发','ftrig.paused':'已暂停','ftrig.done':'已执行过（一次性）',
    'ftrig.running':'运行中','ftrig.ok':'{t} 成功','ftrig.exit':'{t} 退出码 {n}',
    'ftrig.source':'来源卡片','ftrig.removed':'已移除','ftrig.gone':'已不在','ftrig.noSource':'不是在卡片里创建的',
    'ftrig.restore':'恢复卡片','ftrig.fire':'立即运行','ftrig.pause':'暂停','ftrig.resume':'继续',
    'ftrig.rm':'移除','ftrig.confirmRm':'确认移除',
    'share.button':'分享','share.title':'分享会话',
    'share.all':'完整会话','share.allDetail':'从第一句到最后一句，所有的输入和回复',
    'share.pick':'挑选消息','share.pickDetail':'在对话里勾选要分享的输入和输出',
    'share.tools':'包含工具调用','share.toolsDetail':'每个一行：工具名和摘要，不含输入输出',
    'share.note':'生成的是公网链接，拿到链接的人都能打开。思考过程和子代理内部的对话不会放进去。',
    'share.make':'生成链接','share.startPick':'开始挑选','share.download':'下载 HTML',
    'share.working':'正在生成…','share.done':'链接已生成','share.copy':'复制链接','share.open':'打开',
    'share.withdraw':'撤回','share.withdrawConfirm':'撤回后这个链接就打不开了。确定吗？','share.withdrawn':'已撤回，链接已失效',
    'share.failed':'没能生成链接','share.retry':'重试','share.loadFailed':'读不到会话：{err}',
    'share.unconfigured':'这台 Mac 还没配置分享服务：在 ~/.fleetview/share.json 写上 {"endpoint","token"}。可以先下载 HTML。',
    'share.picked':'已选 {n} 条','share.pickGo':'分享所选','share.cancel':'取消','share.empty':'没有可分享的消息',
    'share.docAll':'完整会话','share.docPart':'节选','share.docCount':'{n} 条消息','share.docFooter':'由 FleetView 分享',
    'trig.secCron':'定时任务','trig.secBg':'后台任务 · 结束或有动静时唤醒 agent','trig.secLaunchd':'launchd 定时',
    'trig.every':'每 {n} 分钟','trig.hourly':'每小时 {m}','trig.daily':'每天 {t}','trig.weekdays':'工作日 {t}',
    'trig.once':'{t} 一次','trig.interval':'每 {t}',
    'trig.next':'下次 {t}','trig.nextAbout':'下次约 {t}','trig.fired':'已触发 {n} 次，上次 {t}','trig.neverFired':'还没触发过',
    'trig.created':'创建于 {t}','trig.expires':'{t} 自动过期','trig.reason':'原因：{t}',
    'trig.wakeup':'/loop 唤醒','trig.recurring':'重复','trig.oneShot':'一次性',
    'trig.del':'删除这个触发器','trig.stop':'停止这个后台任务',
    'trig.confirmAgent':'FleetView 会给 agent 发一条消息，让它自己取消（会话内的定时任务只有它能删）。确定吗？',
    'trig.confirmLaunchd':'会卸载这个 launchd 任务，并把 plist 移到废纸篓。确定吗？',
    'trig.cancelling':'已发给 agent，等它执行…','trig.removing':'正在移除…','trig.sent':'已发给 agent',
    'trig.removed':'已移除','trig.failed':'没能删除：连不上 Mac',
    'trig.reportedAt':'agent 上次上报：{t}（每轮结束时上报）',
    'trig.neverReported':'还没收到这个 agent 的上报——Claude 会在下一轮结束时报告。',
    'trig.notRunning':'agent 没在运行，会话内的定时和后台任务都已随进程结束。',
    'trig.codexNote':'Codex 没有会话内的定时任务，这里只会列出指向它的 launchd 任务。',
    'trig.none':'没有触发器','trig.noneDetail':'这个终端的 agent 没有定时或后台任务，也没有 launchd 任务指向它。'
  },
  en:{
    'common.loading':'Loading…','common.back':'Back','common.retry':'Retry',
    'common.collapse':'Collapse','common.expand':'Expand','common.newTerm':'New terminal','common.tokens':'{n} tokens',
    'status.working':'Running','status.idle':'Idle','status.needsYou':'Needs you','status.shell':'Shell',
    'status.exited':'Exited','status.closed':'Closed','status.done':'Just finished',
    'time.now':'now','time.justNow':'just now',
    'time.minAgo':{one:'{n} minute ago',other:'{n} minutes ago'},
    'time.hourAgo':{one:'{n} hour ago',other:'{n} hours ago'},
    'time.dayAgo':{one:'{n} day ago',other:'{n} days ago'},
    'time.today':'Today {time}','time.yesterday':'Yesterday {time}','time.date':'{mon} {d} {time}','time.dateYear':'{mon} {d}, {y} {time}',
    'head.markFilter':'Show only marked terminals','head.projTitle':'Open a project from ~/PycharmProjects','head.projAria':'Open project',
    'head.trayTitle':'Files agents sent you','head.trayAria':'Received files',
    'count.projects':{one:'{n} project',other:'{n} projects'},
    'count.terminals':{one:'{n} terminal',other:'{n} terminals'},
    'badge.needs':{one:'{n} needs you',other:'{n} need you'},'badge.running':'{n} running',
    'scheme.btnAuto':'Appearance: follow the Mac','scheme.btnDark':'Appearance: dark (tap to switch)','scheme.btnLight':'Appearance: light (tap to switch)',
    'scheme.toastAuto':'Appearance follows the Mac','scheme.toastDark':'Appearance: dark','scheme.toastLight':'Appearance: light',
    'zone.now':'In progress','zone.dormant':'Quiet for 2 hours',
    'board.banner':'Web terminals are unavailable — run {cmd}, then restart FleetView. Status still shows as usual.',
    'empty.noMarked':'No marked terminals','empty.noMarkedSub':'The board is showing only marked terminals.','mark.showAll':'Show all terminals',
    'empty.noProjects':'No projects yet','empty.noProjectsSub':'Add one on the Mac.',
    'toast.onlyMarked':'Showing only marked terminals','toast.showAll':'Showing all terminals',
    'proj.lastActivity':'Last activity','proj.browse':'Browse project files','proj.newTerm':'New terminal',
    'proj.nameFolded':'Click to expand','proj.nameOpen':'Click to copy the path',
    'card.lastRun':'Last turn took {time}','card.lastActivity':'Last activity','card.marked':'Marked',
    'card.hidden':'Window hidden — the agent keeps running in the background',
    'card.idTitle':'Click to copy the terminal ID ({id}); double-click to copy the conversation file path',
    'card.idCopied':'Copied','card.idPath':'Path',
    'toast.noTranscript':'This terminal has no conversation log',
    // "Mark" rather than "Bookmark" throughout: it is what the Mac called this flag in English, and
    // "Bookmark" is a pixel too wide for six zones across a phone.
    'dock.mark':'Mark','dock.unmark':'Unmark','dock.duplicate':'Duplicate','dock.rename':'Rename',
    'dock.hide':'Hide','dock.show':'Show','dock.leave':'Ungroup','dock.remove':'Remove',
    'drag.drop':'Drop: {action}',
    'drop.join':'Release to join “{name}”','drop.groupWith':'Release to group with “{name}”',
    'drop.leave':'Release to leave “{name}”','drop.moveTo':'Release to move to “{name}”','drop.group':'Group',
    'drop.noteWorking':'The agent is running; it will be interrupted and reopened with its history','drop.noteCodex':'Codex files history by date, so nothing moves; it reopens in the new project',
    'drop.noteNoHistory':'No conversation yet; it just changes project','drop.noteMove':'The conversation moves with it and is reopened there','prompt.rename':'Rename terminal',
    'toast.openOnMac':'Open this terminal on the Mac first','toast.gone':'This terminal is no longer on the board',
    'toast.notOpen':'This terminal isn’t open on the Mac right now',
    'proj.search':'Search ~/PycharmProjects','proj.noMatch':'No matching folders','proj.none':'No folders in ~/PycharmProjects',
    'proj.onBoard':'On board','proj.go':'Go to','proj.open':'Open',
    'toast.cantOpen':'Couldn’t open {name}','toast.opened':'Opened {name}',
    'tray.empty':'No files received yet',
    'tab.chat':'Chat','tab.output':'Output','tab.term':'Terminal','term.popOut':'Open the terminal in a new tab','chat.jump':'Jump to latest',
    'term.closed':'This terminal has been closed',
    'term.closedHint':'Its session is gone, so ttyd’s “Press ⏎ to Reconnect” has nothing to attach to. Go back to the board and tap this card to reopen it and carry on with the conversation.',
    'term.noMac':'Can’t reach the Mac','term.noMacHint':'The board itself is answering, so this is usually just a brief network hiccup.',
    'term.portDead':'The terminal’s port isn’t answering',
    'term.portDeadHint':'Chat goes through FleetView on :{chat}; the terminal is a separate service on :{port}. If this keeps happening, that port is blocked somewhere between here and the Mac.',
    'chat.retrying':'Retrying…','chat.loadFailed':'Couldn’t load the conversation: {err}','shell.empty':'Nothing on screen yet.',
    'pm.bypass':'Skip permissions','pm.acceptEdits':'Auto-accept edits','pm.plan':'Plan mode',
    'info.sharedTitle':'This conversation is one session shared by {n} terminals — switch to Terminal to see this one on its own',
    'info.shared':'⇉ shared by {n}','info.session':'Session {id}',
    'info.branchesTitle':{one:'This session has 1 branch point from a rewind or edit — only the current branch is shown here',
                          other:'This session has {n} branch points from rewinds or edits — only the current branch is shown here'},
    'info.context':'Context {pct}% · {tok}',
    'perm.default':'Waiting for your decision',
    'chat.thinking':'Thinking','chat.input':'Input','chat.output':'Output','chat.failed':'Failed','chat.copy':'Copy',
    'chat.subagent':'Subagent','chat.answerInTerm':'Answer it in the Terminal tab','chat.empty':'No conversation yet — send a message to start.',
    'diff.unchanged':{one:'⋯ 1 unchanged line',other:'⋯ {n} unchanged lines'},'diff.edit':'Edit {n}',
    'toast.copied':'Copied','toast.pathCopied':'Path copied','toast.copyFailed':'Copy failed','toast.copyFailedLong':'Copy failed — long-press the path to select it',
    'composer.send':'Send','composer.stop':'Stop',
    'composer.placeholder':'Message — Enter to send, Shift+Enter for a new line','composer.placeholderShort':'Message',
    'composer.smaller':'Smaller text','composer.larger':'Larger text','composer.expandEditor':'Expand editor','composer.collapseEditor':'Collapse editor',
    'keys.slash':'Open the agent’s slash-command menu',
    'notes.btnTitle':'Quick commands (your notes)','notes.btnAria':'Quick commands','notes.search':'Search quick commands','notes.add':'Add quick command',
    'notes.edit':'Edit','notes.done':'Done','notes.delete':'Delete','notes.noMatch':'No commands match “{q}”',
    'notes.none':'No quick commands yet — tap + to add one, or add it to Notes on the Mac','notes.addPrompt':'Add a quick command (saved to Notes on the Mac)',
    'more.btnTitle':'Attachments, editor, keys','more.btnAria':'More','more.attachTitle':'Upload to the Mac; the path goes into the message box',
    'more.attach':'Attach','more.editor':'Editor','more.commands':'Commands','more.interruptTitle':'Interrupt the agent','more.interrupt':'Interrupt',
    'toast.stuck':'Not sent: the text is still in the agent’s input box — tap ⏎ to send it again',
    'upload.file':'file','upload.netError':'Network error','upload.cancelled':'Cancelled','toast.uploadFailed':'Upload failed: {err}',
    'fb.reload':'Reload from disk','fb.newTab':'Open in a new tab','fb.up':'Up one level','fb.copyPathBtn':'Path','fb.copyPath':'Copy path',
    'fb.listFailed':'Couldn’t list this folder','fb.truncated':'Showing only the first {n} items in this folder','fb.emptyDir':'This folder is empty',
    'fb.download':'Download','fb.readFailed':'Couldn’t read this file',
    'fb.confirmReload':'Discard your unsaved changes and reload the version on disk?',
    'fb.confirmLeave':'You have unsaved changes. Leave anyway? They will be lost.',
    'fb.confirmOverwrite':'This file changed while you were editing it (an agent may have written it).\n\nOK: overwrite it with your version\nCancel: don’t save yet (↻ shows the new version on disk, but your changes will be lost)',
    'fb.whyLarge':'Too large (over 512 KB) — read-only here','fb.whyEncoding':'Not UTF-8 text — read-only here',
    'fb.whyReadonly':'No write permission for this file','fb.whyDefault':'Read-only here',
    'md.preview':'Preview','md.edit':'Edit','md.undo':'Undo','md.undoTitle':'Undo (⌘Z)','md.redo':'Redo','md.redoTitle':'Redo (⇧⌘Z)',
    'md.save':'Save','md.saveTitle':'Save (⌘S)','md.emptyFile':'(Empty file)','md.unsaved':'Unsaved','md.saved':'Saved',
    'toast.saveNoMac':'Save failed: can’t reach the Mac','toast.saveFailed':'Save failed: {err}',
    'net.aria':'Connection','net.local':'This Mac','net.lan':'LAN','net.tsDirect':'Tailscale direct','net.tsRelay':'Tailscale relay',
    'net.tsRelayVia':'Tailscale relay ({relay})','net.public':'Internet','net.offline':'Offline',
    'net.toastOff':'Can’t reach the Mac — retrying','net.toastOffLast':'Can’t reach the Mac — retrying (last: {route})',
    'net.latency':'Latency {ms} ms','net.latencyRange':'Latency {ms} ms (last {n}: {lo}–{hi} ms)',
    'net.node':'This device: {node}','net.refreshed':'Board refreshed {s}s ago',
    'net.reconnecting':'Reconnecting…','net.reconnected':'Reconnected','net.back':'Back in touch with the Mac',
    'toast.attachedTo':'Attached to {name}’s message box',
    'trig.title':'Triggers','trig.chip':{one:'1 trigger · tap to see',other:'{n} triggers · tap to see'},
    'ftrig.title':'FleetView triggers','ftrig.sub':'run by FleetView, not by any card','ftrig.empty':'No triggers',
    'ftrig.cron':'cron {c}','ftrig.every':'every {d}','ftrig.at':'once · {t}','ftrig.watch':'on change · {p}',
    'ftrig.check':'when it holds · {c}','ftrig.manual':'manual / fired from outside','ftrig.paused':'paused','ftrig.done':'done (once)',
    'ftrig.running':'running','ftrig.ok':'{t} ok','ftrig.exit':'{t} exit {n}',
    'ftrig.source':'Source card','ftrig.removed':'removed','ftrig.gone':'gone','ftrig.noSource':'Not created from a card',
    'ftrig.restore':'Restore card','ftrig.fire':'Run now','ftrig.pause':'Pause','ftrig.resume':'Resume',
    'ftrig.rm':'Remove','ftrig.confirmRm':'Confirm remove',
    'share.button':'Share','share.title':'Share conversation',
    'share.all':'Whole conversation','share.allDetail':'Every prompt and reply, first to last',
    'share.pick':'Pick messages','share.pickDetail':'Tick the prompts and replies to include',
    'share.tools':'Include tool calls','share.toolsDetail':'One line each: the tool and its summary, no input or output',
    'share.note':'The link is public: anyone who has it can open it. Thinking and subagents’ own conversations are left out.',
    'share.make':'Create link','share.startPick':'Start picking','share.download':'Download HTML',
    'share.working':'Creating…','share.done':'Link created','share.copy':'Copy link','share.open':'Open',
    'share.withdraw':'Withdraw','share.withdrawConfirm':'Once withdrawn, the link stops working. Withdraw it?','share.withdrawn':'Withdrawn — the link no longer works',
    'share.failed':'Could not create the link','share.retry':'Retry','share.loadFailed':'Could not read the conversation: {err}',
    'share.unconfigured':'No share service is set up on this Mac: put {"endpoint","token"} in ~/.fleetview/share.json. You can download the HTML meanwhile.',
    'share.picked':{one:'1 picked',other:'{n} picked'},'share.pickGo':'Share these','share.cancel':'Cancel','share.empty':'Nothing to share',
    'share.docAll':'Whole conversation','share.docPart':'Excerpt','share.docCount':{one:'1 message',other:'{n} messages'},'share.docFooter':'Shared from FleetView',
    'trig.secCron':'Scheduled','trig.secBg':'Background work · wakes the agent when it reports','trig.secLaunchd':'launchd jobs',
    'trig.every':'every {n} min','trig.hourly':'hourly at {m}','trig.daily':'daily at {t}','trig.weekdays':'weekdays at {t}',
    'trig.once':'once, {t}','trig.interval':'every {t}',
    'trig.next':'next {t}','trig.nextAbout':'next ~{t}','trig.fired':{one:'fired once, last {t}',other:'fired {n}×, last {t}'},
    'trig.neverFired':'not fired yet',
    'trig.created':'created {t}','trig.expires':'expires {t}','trig.reason':'why: {t}',
    'trig.wakeup':'/loop wakeup','trig.recurring':'recurring','trig.oneShot':'one-shot',
    'trig.del':'Delete this trigger','trig.stop':'Stop this background task',
    'trig.confirmAgent':'FleetView will send the agent a message asking it to cancel this itself — only it can reach its session schedule. Go ahead?',
    'trig.confirmLaunchd':'This unloads the launchd job and moves its plist to the Trash. Go ahead?',
    'trig.cancelling':'Sent to the agent — waiting for it…','trig.removing':'Removing…','trig.sent':'Sent to the agent',
    'trig.removed':'Removed','trig.failed':'Couldn’t delete: can’t reach the Mac',
    'trig.reportedAt':'Last reported by the agent {t} (at the end of each turn)',
    'trig.neverReported':'Nothing reported yet — Claude reports at the end of its next turn.',
    'trig.notRunning':'No agent is running; session schedules and background work ended with it.',
    'trig.codexNote':'Codex has no session scheduler; only launchd jobs that name this terminal can appear here.',
    'trig.none':'No triggers','trig.noneDetail':'Its agent has nothing scheduled or running in the background, and no launchd job names it.'
  }
};
/* The device's language, read once: a page that switched halfway through a session would show both.
   Only the first preference counts — it is the one the system UI is in. */
const LANG=String((navigator.languages&&navigator.languages[0])||navigator.language||'').toLowerCase().startsWith('zh')?'zh':'en';
const LOCALE=LANG==='zh'?'zh-CN':'en-US';
document.documentElement.lang=LOCALE;
/* Falls back to English and then to the key itself, so a gap shows up as a readable word or an
   obvious id — never as an empty button. */
function tr(key,vars){
  let v=I18N[LANG][key];
  if(v===undefined) v=I18N.en[key];
  if(v===undefined) return key;
  if(typeof v==='object') v=(vars&&vars.n===1)?v.one:v.other;
  return vars?v.replace(/\{(\w+)\}/g,(m,k)=>k in vars?String(vars[k]):m):v;
}
(function(){
  for(const [a,b] of [['zh','en'],['en','zh']]){
    const miss=Object.keys(I18N[a]).filter(k=>!(k in I18N[b]));
    if(miss.length) console.error('i18n: missing from '+b+': '+miss.join(', '));
  }
})();
/* The static markup carries keys, not words: data-i18n for the text, and -title / -placeholder /
   -aria for the attributes. Only ever on leaf elements, since filling the text replaces children. */
function applyI18n(root){
  for(const el of root.querySelectorAll('[data-i18n]')) el.textContent=tr(el.dataset.i18n);
  for(const el of root.querySelectorAll('[data-i18n-title]')) el.title=tr(el.dataset.i18nTitle);
  for(const el of root.querySelectorAll('[data-i18n-placeholder]')) el.placeholder=tr(el.dataset.i18nPlaceholder);
  for(const el of root.querySelectorAll('[data-i18n-aria]')) el.setAttribute('aria-label',tr(el.dataset.i18nAria));
}
applyI18n(document);

let curUrl='',curId='',state=null,dragging=false,curView='chat',chatTimer=null,termLoaded=false,curInfo={},sentAt=0,stickBottom=false,flyNext=false;
/* The position a conversation is to open at, until it has been put there (see goTo). */
let pendingPos=null, settle=null, chatTouched=0, liveSeen=false;

/* ---------- icons and status shapes ----------
   Line icons are Lucide's geometry (the library the design names for the web side), inlined so the
   page still needs nothing from outside the LAN. Emoji were the icons before, and they drew in a
   different weight and colour on every platform. One icon means one thing; a button that is only an
   icon always carries a title. */
const IC={
  'layout-grid':'<rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/>',
  bookmark:'<path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z"/>',
  'bookmark-x':'<path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2Z"/><path d="m14.5 7.5-5 5M9.5 7.5l5 5"/>',
  'eye-off':'<path d="M10.73 5.08A10.74 10.74 0 0 1 21.94 11.65a1 1 0 0 1 0 .7 10.75 10.75 0 0 1-1.44 2.49"/><path d="M14.08 14.16a3 3 0 0 1-4.24-4.24"/><path d="M17.48 17.5a10.75 10.75 0 0 1-15.42-5.15 1 1 0 0 1 0-.7 10.75 10.75 0 0 1 4.45-5.14"/><path d="m2 2 20 20"/>',
  eye:'<path d="M2.06 12.35a1 1 0 0 1 0-.7 10.75 10.75 0 0 1 19.88 0 1 1 0 0 1 0 .7 10.75 10.75 0 0 1-19.88 0"/><circle cx="12" cy="12" r="3"/>',
  monitor:'<rect width="20" height="14" x="2" y="3" rx="2"/><path d="M8 21h8M12 17v4"/>',
  moon:'<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
  sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/>',
  folder:'<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  'folder-open':'<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>',
  inbox:'<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
  plus:'<path d="M5 12h14M12 5v14"/>',
  x:'<path d="M18 6 6 18M6 6l12 12"/>',
  'alarm-clock':'<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2M5 3 2 6M22 6l-3-3M6.38 18.7 4 21M17.64 18.67 20 21"/>',
  hourglass:'<path d="M5 22h14M5 2h14M17 22v-4.17a2 2 0 0 0-.59-1.42L12 12l-4.41 4.41A2 2 0 0 0 7 17.83V22M7 2v4.17a2 2 0 0 0 .59 1.42L12 12l4.41-4.41A2 2 0 0 0 17 6.17V2"/>',
  repeat:'<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>',
  activity:'<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
  users:'<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
  'calendar-clock':'<path d="M21 7.5V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h3.5M16 2v4M8 2v4M3 10h5"/><path d="M17.5 17.5 16 16.3V14"/><circle cx="16" cy="16" r="6"/>',
  'circle-stop':'<circle cx="12" cy="12" r="10"/><rect x="9" y="9" width="6" height="6" rx="1"/>',
  check:'<path d="M20 6 9 17l-5-5"/>',
  circle:'<circle cx="12" cy="12" r="8"/>',
  copy:'<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
  'copy-plus':'<path d="M15 12v6M12 15h6"/><rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
  pencil:'<path d="M21.17 6.81a1 1 0 0 0-3.99-3.99L3.84 16.17a2 2 0 0 0-.5.83l-1.32 4.35a.5.5 0 0 0 .62.62l4.35-1.32a2 2 0 0 0 .83-.5z"/><path d="m15 5 4 4"/>',
  trash:'<path d="M3 6h18M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2M10 11v6M14 11v6"/>',
  'log-out':'<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
  'chevron-right':'<path d="m9 18 6-6-6-6"/>',
  'chevron-left':'<path d="m15 18-6-6 6-6"/>',
  'chevron-down':'<path d="m6 9 6 6 6-6"/>',
  'chevron-up':'<path d="m18 15-6-6-6 6"/>',
  'square-terminal':'<path d="m7 11 2-2-2-2M11 13h4"/><rect width="18" height="18" x="3" y="3" rx="2"/>',
  sigma:'<path d="M18 7V5a1 1 0 0 0-1-1H6.5a.5.5 0 0 0-.4.8l4.5 6a2 2 0 0 1 0 2.4l-4.5 6a.5.5 0 0 0 .4.8H17a1 1 0 0 0 1-1v-2"/>',
  'square-stack':'<path d="M4 10c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h4c1.1 0 2 .9 2 2"/><path d="M10 16c-1.1 0-2-.9-2-2v-4c0-1.1.9-2 2-2h4c1.1 0 2 .9 2 2"/><rect width="8" height="8" x="14" y="14" rx="2"/>',
  'arrow-down':'<path d="M12 5v14M19 12l-7 7-7-7"/>',
  'external-link':'<path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
  'rotate-cw':'<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>',
  'corner-left-up':'<path d="M14 9 9 4 4 9"/><path d="M20 20h-7a4 4 0 0 1-4-4V4"/>',
  'corner-down-left':'<path d="M20 4v7a4 4 0 0 1-4 4H4"/><path d="m9 10-5 5 5 5"/>',
  'maximize-2':'<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>',
  'minimize-2':'<path d="M4 14h6v6M20 10h-6V4M14 10l7-7M3 21l7-7"/>',
  'undo-2':'<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  'redo-2':'<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5a5.5 5.5 0 0 0 0 11H13"/>',
  file:'<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>',
  'file-text':'<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4M10 9H8M16 13H8M16 17H8"/>',
  image:'<rect width="18" height="18" x="3" y="3" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.09-3.09a2 2 0 0 0-2.82 0L6 21"/>',
  sheet:'<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18M3 15h18M9 9v12M15 9v12"/>',
  archive:'<rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8M10 12h4"/>',
  film:'<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 3v18M3 7.5h4M3 12h18M3 16.5h4M17 3v18M17 7.5h4M17 16.5h4"/>',
  paperclip:'<path d="m21.44 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48"/>',
  lightbulb:'<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5M9 18h6M10 22h4"/>',
  terminal:'<path d="m4 17 6-6-6-6M12 19h8"/>',
  search:'<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  globe:'<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20M2 12h20"/>',
  bot:'<path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2M20 14h2M15 13v2M9 13v2"/>',
  share:'<path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><path d="m16 6-4-4-4 4"/><path d="M12 2v13"/>',
  zap:'<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
  dot:'<circle cx="12" cy="12" r="2.5" fill="currentColor"/>'
};
function ic(name,cls){
  return '<svg class="ic'+(cls?' '+cls:'')+'" viewBox="0 0 24 24" aria-hidden="true">'+(IC[name]||'')+'</svg>';
}
/* Static markup names its icons as <i data-ic>; they are drawn here once, before anything renders. */
function paintIcons(root){
  for(const el of (root||document).querySelectorAll('i[data-ic]')) el.outerHTML=ic(el.dataset.ic,el.className);
}
const STATUS_TEXT={working:tr('status.working'),idle:tr('status.idle'),needsYou:tr('status.needsYou'),
  shell:tr('status.shell'),exited:tr('status.exited'),closed:tr('status.closed')};
/* The six states as still shapes — the Mac's StatusGlyph, point for point. The fuller the mark, the
   more it wants you: a soft burst for running (Material's shape, not a spinner), a diamond with the
   "!" cut out of it (even-odd, so it stays a hole on any ground) for needs-you, a small disc for idle,
   a prompt in a box for a shell, an empty ring for closed and a crossed one for exited. Nothing here
   moves except the one pop when a card's status changes; the word is the title. */
const BURST=(()=>{
  let d='';
  for(let i=0;i<96;i++){
    const a=i/96*2*Math.PI, r=7.4*(.87+.13*Math.cos(9*a));
    d+=(i?'L':'M')+(8+r*Math.cos(a)).toFixed(2)+' '+(8+r*Math.sin(a)).toFixed(2);
  }
  return d+'Z';
})();
const GLYPH={
  working:'<path d="'+BURST+'" fill="currentColor"/>',
  needsYou:'<path fill="currentColor" fill-rule="evenodd" d="M8 .8 15.2 8 8 15.2 .8 8Z M8 4.26a.94.94 0 0 1 .94.94v2.73a.94.94 0 0 1-1.88 0V5.2A.94.94 0 0 1 8 4.26Z M8 9.87a1.08 1.08 0 1 1 0 2.16a1.08 1.08 0 1 1 0-2.16Z"/>',
  idle:'<circle cx="8" cy="8" r="4" fill="currentColor"/>',
  shell:'<g fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2.56" width="12" height="10.88" rx="2.72" stroke-width="1.4"/><path d="M5.36 6.15 7.52 8l-2.16 1.85M8.48 10.18h2.4" stroke-width="1.3"/></g>',
  exited:'<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="5.6"/><path d="M6.08 6.08l3.84 3.84M9.92 6.08l-3.84 3.84"/></g>',
  closed:'<circle cx="8" cy="8" r="5.6" fill="none" stroke="currentColor" stroke-width="1.5"/>'
};
function glyph(status,cls){
  const s=GLYPH[status]?status:'closed', label=STATUS_TEXT[s];
  return '<svg class="g '+s+(cls?' '+cls:'')+'" viewBox="0 0 16 16" role="img" aria-label="'+label+'"><title>'+label+'</title>'+GLYPH[s]+'</svg>';
}
/* On a card, idle carries a second shape: a check cut out of a disc, worn for the first ten seconds
   after a run comes back to the prompt. Both are drawn and the card's `fresh` class picks one, so
   settling is a class change the stylesheet can ease, not a rebuild. paintFresh keeps the word in
   step with whichever is showing. */
const DONE_TEXT=tr('status.done');
function cardGlyph(status){
  if(status!=='idle') return glyph(status);
  return glyph('idle').replace('<circle ','<circle class="gi" ').replace('</svg>',
    '<path class="gd" fill="currentColor" fill-rule="evenodd" d="M8 1.2a6.8 6.8 0 1 1 0 13.6A6.8 6.8 0 0 1 8 1.2zM4.9 8.1l2.1 2.1 4.1-4.3-.95-.9L7 8.3 5.85 7.15z"/></svg>');
}
/* Who is behind a card — identity, so it is a mark in the footer and never a colour on the card:
   Claude's eight rays in its own orange, Codex's hexagon in the ink colour. */
const AGENT={
  claude:'<path d="M1.1 8h13.8M8 1.1v13.8M3.12 3.12l9.76 9.76M12.88 3.12l-9.76 9.76" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"/>',
  codex:'<path d="M8 1.1l5.98 3.45v6.9L8 14.9l-5.98-3.45v-6.9Z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/><circle cx="8" cy="8" r="1.8" fill="currentColor"/>'
};
function agentMark(a){
  if(!AGENT[a]) return '';
  const n=a==='claude'?'Claude':'Codex';
  return '<svg class="ag '+a+'" viewBox="0 0 16 16" role="img" aria-label="'+n+'"><title>'+n+'</title>'+AGENT[a]+'</svg>';
}
paintIcons(document);

function short(n){if(n<1000)return ''+n;if(n<1000000)return (n/1000).toFixed(n<10000?1:0)+'k';return (n/1000000).toFixed(1)+'M';}
function ago(sec){if(sec<0)return '';if(sec<60)return tr('time.justNow');
  const m=Math.floor(sec/60);if(m<60)return tr('time.minAgo',{n:m});const h=Math.floor(m/60);if(h<24)return tr('time.hourAgo',{n:h});
  return tr('time.dayAgo',{n:Math.floor(h/24)});}
/* How long ago, as compactly as it can be said — RelativeTime.compact on the Mac: "刚刚" / "now", "25m",
   "5h", "4d". What a card shows when nothing is running; the unit letter is enough once seen, in
   either language. */
function rel(sec){if(sec<60)return tr('time.now');const m=Math.floor(sec/60);if(m<60)return m+'m';
  const h=Math.floor(m/60);if(h<24)return h+'h';return Math.floor(h/24)+'d';}
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
  el.dataset.sig='';
  sentGhost=null; stickBottom=false; flyNext=true;     // where it lands is pendingPos's to say
  curInfo=Object.assign({},c.info,{status:'',pendingTool:'',pendingText:''});
  document.getElementById('stickyq').classList.remove('on');
  document.getElementById('perm').classList.remove('on');
  renderChat(c.messages,c.note);
  renderInfo(curInfo);
}
/* ---------- each card keeps its own place and its own unsent text ----------
   One composer and one scroll used to serve every card. A draft typed for one terminal was still
   in the box when you opened another — and Send would have given it to that one. And a
   conversation reopened from this device's cache was scrolled to its end while the overlay was
   still hidden, which a browser may ignore: it then opened wherever the cached list began, which
   is 150 messages back, the middle of the conversation. Now each card reopens where you left it:
   at the latest message if that is where you were, else at the message you were reading. */
const POS_KEY='fv_pos', DRAFT_KEY='fv_draft', PER_CARD_MAX=60;
function cardMap(key){ try{ return JSON.parse(localStorage.getItem(key)||'{}')||{}; }catch(e){ return {}; } }
function cardPut(key,id,val){
  if(!id)return;
  const m=cardMap(key);
  if(val==null) delete m[id]; else m[id]=Object.assign({t:Date.now()},val);
  for(const x of Object.keys(m).sort((a,b)=>(m[b].t||0)-(m[a].t||0)).slice(PER_CARD_MAX)) delete m[x];
  try{ localStorage.setItem(key,JSON.stringify(m)); }catch(e){}
}
/* Where the chat is being read: its end, or the message at the top of the view and how far down
   it sits. A message rather than a pixel offset, because the list is a window onto the last 150
   messages that slides as new ones arrive — an offset would point at something else next time. */
function readingAt(el){
  if(el.scrollHeight-el.scrollTop-el.clientHeight<120) return {bottom:true};
  const top=el.getBoundingClientRect().top;
  for(const n of el.querySelectorAll('.msg[data-k]')){
    const r=n.getBoundingClientRect();
    if(r.bottom>top) return {k:n.dataset.k,off:r.top-top};
  }
  return {bottom:true};
}
/* Put the view back there. False when that message is not in the list on screen. */
function goTo(el,at){
  if(!at||at.bottom){ el.scrollTop=el.scrollHeight; return true; }
  const n=el.querySelector('.msg[data-k="'+at.k+'"]');      // msgKey is [a-z0-9]: safe in a selector
  if(!n) return false;
  el.scrollTop+=n.getBoundingClientRect().top-el.getBoundingClientRect().top-at.off;
  return true;
}
/* Arrived at: hold it there for a moment, while late layout (fonts, the viewport settling, the
   header's height) moves things under it — unless you have started scrolling yourself. */
function settleAt(el,at){
  const since=performance.now();
  settle={at,since};
  for(const ms of [0,120,400,1000]) setTimeout(()=>{
    if(settle&&settle.since===since&&chatTouched<since&&curId) goTo(el,at);
  },ms);
}
function savePos(){
  const el=document.getElementById('chat');
  if(!curId||pendingPos||!el.querySelector('.msg')) return;   // nothing of its own on screen yet
  cardPut(POS_KEY,curId,readingAt(el));
}
function saveDraft(){
  if(!curId)return;
  const v=document.getElementById('inputtext').value;
  cardPut(DRAFT_KEY,curId,v?{v}:null);
}
function loadDraft(id){
  const ta=document.getElementById('inputtext');
  ta.value=(cardMap(DRAFT_KEY)[id]||{}).v||'';
  autoGrow(ta); syncSendBtn();
}
['wheel','touchstart','keydown','mousedown'].forEach(ev=>
  document.getElementById('chat').addEventListener(ev,()=>{ chatTouched=performance.now(); },{passive:true}));
window.addEventListener('pagehide',()=>{ savePos(); saveDraft(); });
document.addEventListener('visibilitychange',()=>{ if(document.hidden){ savePos(); saveDraft(); } });

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
  showBoardHead();                         // coming back is not reading on; the menu should be there
  // The last one: a running terminal is drawn twice now (once in the strip at the top, once in its
  // project), and "the card you came out of" means the one in the board, not the summary copy.
  const all=id?document.querySelectorAll('.card[data-id="'+id+'"]'):[];
  const card=all.length?all[all.length-1]:null;
  if(!card) return;
  const r=card.getBoundingClientRect();
  if(r.top<8||r.bottom>window.innerHeight-8) card.scrollIntoView({block:'center'});
}
function openTerm(id,name){
  if(curId&&curId!==id){ savePos(); saveDraft(); }          // leaving one card for another
  endPick(); closeShare();
  curId=id;curUrl='';termLoaded=false;chatFails=0;termGone=false;
  // Shown before anything is drawn into it: a pane that is not laid out cannot be scrolled.
  document.getElementById('term').classList.add('show');
  pendingPos=cardMap(POS_KEY)[id]||{bottom:true}; settle=null; liveSeen=false;
  const cached=cacheGet(id);
  if(cached&&cached.messages&&cached.messages.length) showCached(cached); else showSkeleton();
  loadDraft(id);
  document.getElementById('termname').textContent=name;
  document.getElementById('termframe').src='about:blank';
  closeDrawer(); showTermHead();            // every conversation opens with its header and no drawer
  lockBoard();                              // stop the page scrolling behind the overlay
  syncViewport();
  requestAnimationFrame(syncViewport);     // re-measure once the lock has taken effect
  renderPresets();          // latest Notes as quick-commands
  beaconSelect(id,'chat');
  setView('chat');          // reading history is the common remote case
  termSyncHash();
  // Next frame, so the panes have their real heights and the ceiling is measured against those.
  // The collapsed bar needs the same treatment: its height is a measurement too, and until now
  // nothing took one after the overlay became visible (see autoGrow).
  requestAnimationFrame(()=>{
    if(barH) applyBar(); else { autoGrow(document.getElementById('inputtext')); placeJump(); }
  });
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
swipeBack('term','chat','pre.code,.mbody,#presets,#keys,#inputbar,#drawer,#tabs',()=>closeTerm());
/* The file browser is the other full-screen overlay, and it was the one place on the phone with no
   way back but the ‹ button. Its exclusions are its own: the crumb bar is selectable text you
   long-press to copy, a code preview scrolls sideways, and a PDF is an iframe that pans itself. */
swipeBack('fb','fbbody','#fbpath,#fbcrumbs,pre,iframe,textarea,.fbtools,table',()=>fbClose());
function closeTerm(){
  savePos(); saveDraft();
  closeDrawer(); showTermHead();
  document.getElementById('stickyq').classList.remove('on');
  document.getElementById('term').classList.remove('show');
  unlockBoard(curId);                      // back to the card you came from, not to the top
  syncViewport();                          // drop the keyboard-era height/offset
  document.getElementById('termframe').src='about:blank';
  document.getElementById('termerr').classList.remove('on');
  endPick(); closeShare();
  curId='';termLoaded=false;stopChatPoll();pendingPos=null;settle=null;
  beaconSelect('','');
  termSyncHash();
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
  placeJump();                   // the key row just came or went, so the bar is a different height
  updateStickyPrompt();          // it belongs to the chat pane — never leave it over the terminal
  syncShareBtn();
  if(v==='term'){endPick();showTermHead();stopChatPoll();ensureTerm();}   // nothing of ours scrolls there to bring it back
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
              +'<button onclick="retryTerm()">'+tr('common.retry')+'</button></div>';
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
  termError(tr('term.closed'),tr('term.closedHint'));
}
async function ensureTerm(){
  if(termLoaded||!curId)return;
  termLoaded=true;
  const want=curId;
  document.getElementById('termerr').classList.remove('on');
  let j;
  try{ j=await(await fetch('/open?id='+encodeURIComponent(curId))).json(); }
  catch(e){ termLoaded=false; termError(tr('term.noMac'),tr('term.noMacHint')); return; }
  if(want!==curId) return;                 // you moved on while it was starting
  if(!j.port){termLoaded=false;toast(tr('toast.notOpen'));return;}
  curUrl=location.protocol+'//'+location.hostname+':'+j.port+'/';
  /* Each terminal is served by its OWN ttyd on its own port, so the Chat tab working says nothing
     about whether this one is reachable — different port, and possibly a different address family
     or a route your phone doesn't have. Check before handing the URL to the iframe. */
  if(!await termReachable(curUrl)){
    if(want!==curId) return;
    termLoaded=false;
    termError(tr('term.portDead'),tr('term.portDeadHint',{chat:location.port,port:j.port}));
    return;
  }
  if(want!==curId) return;
  document.getElementById('termframe').src=curUrl;
}
async function popTerm(){await ensureTerm();if(curUrl)window.open(curUrl,'_blank');}

/* ---------- conversation view ---------- */
const TOOLICON={terminal:'terminal',edit:'pencil',read:'file-text',search:'search',web:'globe',task:'bot',other:'dot'};
function startChatPoll(){stopChatPoll();chatTimer=poll(loadChat,3000,false);}
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
  el.innerHTML='<div id="chatnote">'+esc(msg)+'<br><span style="opacity:.6">'+tr('chat.retrying')+'</span></div>';
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
    else {
      renderChat(j.messages||[],j.note); cachePut(want,j);
      // The first live list is the last word on where to open. If what you were reading is not in
      // it — it has scrolled out of the last 150 since — the latest is the next best place: the
      // cached copy may have found it, but holding on to a message that is about to vanish would
      // leave you at whatever the list now starts with.
      if(!liveSeen&&(j.messages||[]).length){
        liveSeen=true;
        const el=document.getElementById('chat'), at=pendingPos||(settle&&settle.at);
        const untouched=!settle||chatTouched<settle.since;
        if(at&&!at.bottom&&untouched&&!el.querySelector('.msg[data-k="'+at.k+'"]')){
          goTo(el,{bottom:true}); settleAt(el,{bottom:true});
        }
        pendingPos=null;
      }
    }
    renderInfo(curInfo);
    renderPerm(curInfo);
    syncSendBtn();
  }catch(e){
    if(want!==curId)return;
    // One miss is a blip and not worth a message; two in a row (≈6s) is a state you should be told
    // about. Polling continues either way, so this clears itself the moment a request succeeds.
    if(++chatFails>=2) showChatError(tr('chat.loadFailed',{err:e.message||e}));
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
    t.style.removeProperty('--padtop');
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
  t.style.setProperty('--padtop',top+'px');   // the header is absolute, so padding alone misses it
  t.style.paddingBottom=bottom+'px';
  // The band just changed size; an expanded composer drawn against the old one can be taller than
  // what is left, and #term clips rather than scrolls — the conversation would simply be gone.
  if(barH) applyBar();
  placeJump();
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
  closeDrawer();
},{passive:true});
/* Coming back from another app is the other way to return to a keyboard-sized band with no
   keyboard: the events that would have cleared it fired while the tab was hidden. */
document.addEventListener('visibilitychange',()=>{
  if(document.hidden) return;
  lastBand=''; syncViewport(); setTimeout(syncViewport,200);
});

/* The ↓ rides above the composer, and the composer is not a fixed height: it grows with the preset
   and key rows, with a wrapped placeholder, and again when it is expanded. Its offset was the
   literal 96px the bar happened to measure when the button was added, so every row added since had
   pushed the button down into it — 43px in, far enough to cover the right-hand end of the preset
   strip, where a tap meant for a quick command jumped the transcript instead. Measure the bar. */
function placeJump(){
  const t=document.getElementById('term'), bar=document.getElementById('inputbar');
  const kb=parseFloat(t.style.paddingBottom)||0;   // the band syncViewport leaves for the keyboard
  const dr=document.getElementById('drawer');
  document.getElementById('jump').style.bottom=(bar.offsetHeight+(dr.offsetHeight||0)+12+kb)+'px';
}

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
                  :'<div id="chatnote">'+tr('shell.empty')+'</div>';
  if(nearBottom)el.scrollTop=el.scrollHeight;
  updateStickyPrompt();
}
/* model / permission-mode / context-window strip */
function renderInfo(i){
  const el=document.getElementById('sinfo');
  document.getElementById('tabChat').textContent=tr((i&&i.shell)?'tab.output':'tab.chat');   // shell has no chat
  syncShareBtn();                                                                   // nor anything to share
  if(!i||(!i.model&&!i.contextTokens&&!i.status)){el.innerHTML='';return;}
  let h='';
  // Chat had no sign of whether the agent was actually working — the transcript just stopped growing.
  if(i.status){
    const ink=i.status==='working'?'var(--accent)':i.status==='needsYou'?'var(--amber)':'var(--sub)';
    h+='<span class="live" style="color:'+ink+'">'+glyph(i.status)+(STATUS_TEXT[i.status]||i.status)+'</span>';
  }
  if(i.model) h+='<span class="chip">'+esc(i.model.replace(/^claude-/,''))+'</span>';
  if(i.permissionMode&&i.permissionMode!=='default'){
    const risky=/bypass|yolo|accept/i.test(i.permissionMode);
    // A subtitle has room for a word, not an identifier: "bypassPermissions" alone was a third of it.
    const PM={bypassPermissions:tr('pm.bypass'),acceptEdits:tr('pm.acceptEdits'),plan:tr('pm.plan')};
    const pm=PM[i.permissionMode]||i.permissionMode.replace(/Permissions$/,'').replace(/([a-z])([A-Z])/g,'$1 $2').toLowerCase();
    h+='<span class="chip'+(risky?' danger':'')+'" title="'+esc(i.permissionMode)+'">'+esc(pm)+'</span>';
  }
  // Several terminals can be attached to one agent session — then the chat is identical for all of
  // them by definition. Say so, rather than letting it look like the wrong conversation.
  if(i.shared>1) h+='<span class="chip warn" title="'+tr('info.sharedTitle',{n:i.shared})+'">'+
    tr('info.shared',{n:i.shared})+'</span>';
  if(i.session) h+='<span class="chip" title="'+tr('info.session',{id:esc(i.session)})+'">'+esc(i.session.slice(0,8))+'</span>';
  // The session is a tree; only the live branch is shown. Say when earlier attempts exist.
  if(i.branches>0) h+='<span class="chip" title="'+tr('info.branchesTitle',{n:i.branches})+'">⑂ '+i.branches+'</span>';
  if(i.contextWindow>0&&i.contextTokens>0){
    const pct=Math.min(100,Math.round(i.contextTokens*100/i.contextWindow));
    const lvl=pct>=95?'danger':(pct>=90?'warn':'');
    h+='<span class="ctx '+lvl+'"><span class="bar"><i style="width:'+pct+'%"></i></span>'+
       tr('info.context',{pct:pct,tok:short(i.contextTokens)})+'</span>';
  }
  el.innerHTML=h;
}
/* the agent is blocked on a decision → real buttons instead of guessing a digit */
function renderPerm(i){
  const el=document.getElementById('perm');
  if(!i||!i.options||!i.options.length){ el.classList.remove('on'); el.innerHTML=''; return; }
  el.innerHTML='<div class="q">'+esc(i.question||tr('perm.default'))+'</div>'+
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
  btn.textContent=tr(stop?'composer.stop':'composer.send');
  btn.style.background=stop?'var(--errorContainer)':'var(--accent)';
  btn.style.color=stop?'var(--onErrorContainer)':'var(--onAccent)';
  btn.dataset.stop=stop?'1':'';
}
function jumpLatest(){ const el=document.getElementById('chat'); el.scrollTop=el.scrollHeight; }
let posSaveT=0;
document.getElementById('chat').addEventListener('scroll',()=>{
  const el=document.getElementById('chat');
  clearTimeout(posSaveT); posSaveT=setTimeout(savePos,300);
  document.getElementById('jump').classList.toggle('on', el.scrollHeight-el.scrollTop-el.clientHeight>300);
  updateStickyPrompt();
});
/* Which question do the replies on screen belong to? The last prompt that has scrolled past the
   top — shown until you scroll back to it, then it goes back to being an ordinary message. */
function updateStickyPrompt(){
  const chat=document.getElementById('chat'), bar=document.getElementById('stickyq');
  if(!chat.classList.contains('on')||(curInfo&&curInfo.shell)){bar.classList.remove('on');return;}
  let cur=null;
  // The header lies over the top of the pane, so "scrolled past" means past its bottom edge — and
  // that edge moves when the header slides away.
  const cover=document.getElementById('term').classList.contains('headhide')?0:
    document.getElementById('thead').offsetHeight;
  const users=chat.querySelectorAll('.msg.user'), line=chat.scrollTop+cover+6;
  for(let i=0;i<users.length;i++){
    if(users[i].offsetTop < line) cur=users[i]; else break;
  }
  // Not while that prompt's own bubble still shows below the header: the bar used to appear the
  // moment its top edge passed, and sat over the rest of the same bubble — one question, twice.
  if(!cur||cur.offsetTop+cur.offsetHeight > line){bar.classList.remove('on');return;}
  const t=cur.querySelector('.mtext');
  bar.firstElementChild.textContent=t?(t.innerText||t.textContent||''):'';
  bar.style.top=(chat.offsetTop+cover)+'px';
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
    if(gap){ html+='<div class="dgap">'+tr('diff.unchanged',{n:gap})+'</div>'; gap=0; }
    const cls=r[0]==='+'?'add':(r[0]==='-'?'del':'ctx');
    html+='<div class="dl '+cls+'">'+esc(r[0]+' '+r[1])+'</div>';
  });
  if(gap) html+='<div class="dgap">'+tr('diff.unchanged',{n:gap})+'</div>';
  return {html:html,add:add,del:del};
}
function diffHTML(edits){
  let body='',add=0,del=0;
  edits.forEach((e,idx)=>{
    const a=e.old?e.old.split('\n'):[], b=e.new?e.new.split('\n'):[];
    let rows=lcsDiff(a,b);
    if(!rows) rows=a.map(l=>['-',l]).concat(b.map(l=>['+',l]));
    const r=diffRows(rows); add+=r.add; del+=r.del;
    body+=(edits.length>1?'<div class="dhead">'+tr('diff.edit',{n:idx+1})+'</div>':'')+r.html;
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
  if(picking){                                            // picking what to share: a tap picks
    const n=e.target.closest?e.target.closest('.msg'):null;
    if(n&&!n.classList.contains('think')){ e.preventDefault(); togglePick(n); }
    return;
  }
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
      const box=ic(s==='completed'?'check':(s==='in_progress'?'chevron-right':'circle'),'s14');
      return '<div class="'+cls+'">'+box+'<span>'+esc(t.activeForm&&s==='in_progress'?t.activeForm:(t.content||''))+'</span></div>';
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
    return '<b>'+tr('chat.subagent')+'</b><div>'+esc(d.description||'')+'</div><div class="mtext md">'+md(d.prompt)+'</div>';
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
      '<div class="mhead">'+ic('lightbulb','s16')+'<span class="sum">'+tr('chat.thinking')+'</span></div><div class="mtext">'+esc(m.text)+'</div></div>';
  if(m.kind==='tool'){
    // Tools whose payload IS the content get a purpose-built view; edits get a diff;
    // everything else falls back to input/output.
    let d=null, special=toolView(m);
    if(!special){
      if(m.edits&&m.edits.length) d=diffHTML(m.edits);
      else if(m.patch) d=patchHTML(m.patch);
    }
    const det=special ? special : (d ? d.html
      : (m.detail?'<b>'+tr('chat.input')+'</b><div>'+esc(m.detail)+'</div>':'')+
        (m.output?'<b>'+tr('chat.output')+'</b><div>'+esc(m.output)+'</div>':''));
    return '<div class="msg tool'+(m.ok===false?' bad':'')+(m.pending?' run':'')+'" data-k="'+msgKey(m)+'">'+
      '<div class="mhead">'+(m.pending?'<span class="spin"></span>':ic(TOOLICON[m.cat]||'dot','s16'))+
      '<b>'+esc(m.tool||'')+'</b><span class="sum">'+esc(m.text)+'</span>'+(d?statHTML(d):'')+
      (m.pending?'<span class="when">'+since(m.ts)+'</span>':'')+
      (m.ok===false?'<span style="color:var(--red)" title="'+tr('chat.failed')+'">'+ic('x','s16')+'</span>':'')+'</div>'+
      (det?'<div class="mbody">'+det+'</div>':'')+'</div>';
  }
  return '<div class="msg '+(m.role==='user'?'user':'asst')+(m.sub?' sub':'')+(m.queued?' queued':'')+'" data-k="'+msgKey(m)+'">'+
    '<span class="cp" data-copy="1">'+tr('chat.copy')+'</span>'+
    (m.sub?'<div class="tag">'+tr('chat.subagent')+'</div>':'')+
    (m.ts?'<span class="when">'+hhmm(m.ts)+'</span>':'')+
    '<div class="mtext md">'+md(m.text)+'</div></div>';
}
/* The tail of the conversation says what the agent is doing right now — a chat that simply stops
   updating looks identical whether it is thinking, blocked, or finished. */
function runBarHTML(){
  const i=curInfo||{};
  if(i.status==='working')
    return '<div class="runbar"><span class="spin"></span><b>'+tr('status.working')+'</b>'+
           (i.pendingTool?'<span class="what">'+esc(i.pendingTool)+
             (i.pendingText?' · '+esc(i.pendingText):'')+'</span>':'')+'</div>';
  if(i.status==='needsYou' && !(i.options&&i.options.length))
    return '<div class="runbar wait">'+glyph('needsYou')+'<b>'+tr('status.needsYou')+'</b>'+
           '<span class="what">'+tr('chat.answerInTerm')+'</span></div>';
  return '';
}
function renderChat(msgs,note){
  const el=document.getElementById('chat');
  if(!msgs.length){el.innerHTML='<div id="chatnote">'+esc(note||tr('chat.empty'))+'</div>';return;}
  const last=msgs[msgs.length-1]||{};
  const st=curInfo||{};
  const sig=msgs.length+':'+(last.text||'').length+':'+(last.output||'').length+
            ':'+(st.status||'')+':'+(st.pendingText||'');
  chatMsgs=msgs;
  if(el.dataset.sig===sig)return;      // unchanged → don't rebuild at all
  const nearBottom=stickBottom||el.scrollHeight-el.scrollTop-el.clientHeight<120;
  // Read before the rebuild: the message you are on, to hold it still while the window slides.
  const reading=pendingPos||nearBottom?null:readingAt(el);
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
  tagPicks(el,msgs);
  reconcileSent(el);
  if(flyNext){                       // only when the conversation is first put on screen
    flyNext=false;
    const all=el.querySelectorAll('.msg'), n=all.length, from=Math.max(0,n-8);
    for(let i=from;i<n;i++){ all[i].classList.add('fly');
      all[i].style.animationDelay=((i-from)*20)+'ms'; }
  }
  if(pendingPos){
    if(goTo(el,pendingPos)){ settleAt(el,pendingPos); pendingPos=null; }
  }else if(nearBottom) el.scrollTop=el.scrollHeight;
  else if(reading) goTo(el,reading);
  stickBottom=false;
  updateStickyPrompt();
}

/* ---------- sharing a conversation ----------
   The page that goes out is built here, by the same md() the chat renders with, so a shared
   conversation reads exactly like the one on screen. FleetView only carries it: POST /share hands
   it to the service named in ~/.fleetview/share.json and returns the public link. The page is
   static — no script at all — and the service serves it under a CSP that forbids any. */
let chatMsgs=[], picking=false, picked=new Set(), pickMsgs={}, pickOrder={}, pickSeq=0;
let shareOpt={mode:'all',tools:false}, lastShare=null;
/* Messages are re-rendered from scratch every few seconds, so a pick is remembered by content —
   msgKey, plus which repeat of that key it is — and put back on the new nodes (see renderChat). */
function tagPicks(el,msgs){
  const nodes=el.querySelectorAll('.msg'), seen={};
  for(let i=0;i<msgs.length&&i<nodes.length;i++){
    const k=msgKey(msgs[i]); seen[k]=(seen[k]||0)+1;
    const p=k+'.'+seen[k];
    nodes[i].dataset.p=p;
    if(!picking) continue;
    pickMsgs[p]=msgs[i];
    // First seen = conversation order: each list is in order, and new messages only ever join at the end.
    if(!(p in pickOrder)) pickOrder[p]=pickSeq++;
    if(picked.has(p)) nodes[i].classList.add('picked');
  }
}
function startPick(){
  picking=true; picked=new Set(); pickMsgs={}; pickOrder={}; pickSeq=0;
  const el=document.getElementById('chat');
  el.classList.add('picking'); document.getElementById('term').classList.add('picking');
  tagPicks(el,chatMsgs); syncPick();
}
function endPick(){
  if(!picking) return;
  picking=false; picked=new Set();
  const el=document.getElementById('chat');
  el.classList.remove('picking'); document.getElementById('term').classList.remove('picking');
  Array.prototype.forEach.call(el.querySelectorAll('.msg.picked'),n=>n.classList.remove('picked'));
}
function togglePick(n){
  const p=n.dataset.p; if(!p) return;
  if(picked.has(p)) picked.delete(p); else picked.add(p);
  n.classList.toggle('picked',picked.has(p)); syncPick();
}
function syncPick(){
  document.getElementById('pickn').textContent=tr('share.picked',{n:picked.size});
  document.getElementById('pickgo').disabled=!picked.size;
}
/* Only where there is a conversation on screen: a shell has none, and the Terminal tab is showing
   the pane — and on a phone the bar has no room to spare for a button that does nothing there. */
function syncShareBtn(){
  document.getElementById('sharebtn').style.display=(curView==='term'||(curInfo&&curInfo.shell))?'none':'';
}
function shareCard(){
  const t=((state&&state.terminals)||[]).find(x=>x.id===curId)||{};
  const p=((state&&state.projects)||[]).find(x=>x.id===t.projectId)||{};
  return {name:t.name||document.getElementById('termname').textContent||'FleetView',
          project:p.name||'', agent:t.agent||'', model:(curInfo&&curInfo.model)||''};
}
function openShare(){
  if(!curId) return;
  lastShare=null;
  document.getElementById('sharename').textContent=shareCard().name;
  renderShareOpts();
  document.getElementById('share').classList.add('on');
}
function closeShare(){ document.getElementById('share').classList.remove('on'); }
function shareBody(h){ const b=document.getElementById('sharebody'); b.innerHTML=h; paintIcons(b); }
function renderShareOpts(){
  const o=shareOpt, opt=(on,click,input,title,detail,off)=>
    '<label class="sopt'+(on?' on':'')+(off?' off':'')+'" onclick="'+click+'">'+input+
    '<div><b>'+esc(tr(title))+'</b><span>'+esc(tr(detail))+'</span></div></label>';
  shareBody(
    opt(o.mode==='all',"shareSet(event,'mode','all')",'<input type="radio" name="smode"'+(o.mode==='all'?' checked':'')+'>','share.all','share.allDetail')+
    opt(o.mode==='pick',"shareSet(event,'mode','pick')",'<input type="radio" name="smode"'+(o.mode==='pick'?' checked':'')+'>','share.pick','share.pickDetail')+
    // When picking, what you tick is what goes — a tool call included — so this only steers "whole".
    opt(o.tools,"shareSet(event,'tools',"+(!o.tools)+")",'<input type="checkbox"'+(o.tools?' checked':'')+'>','share.tools','share.toolsDetail',o.mode==='pick')+
    '<div class="snote">'+esc(tr('share.note'))+'</div>'+
    '<div class="sbtns">'+(o.mode==='pick'
      ? '<button class="sbtn pri" onclick="closeShare();startPick()">'+esc(tr('share.startPick'))+'</button>'
      : '<button class="sbtn pri" onclick="shareWhole(\'link\')">'+esc(tr('share.make'))+'</button>'+
        '<button class="sbtn" onclick="shareWhole(\'file\')">'+esc(tr('share.download'))+'</button>')+'</div>');
}
// preventDefault: a label also clicks the input inside it, which would run this a second time.
function shareSet(e,k,v){ e.preventDefault(); shareOpt[k]=v; renderShareOpts(); }
function shareBusy(){ shareBody('<div class="sbusy"><span class="spin"></span>'+esc(tr('share.working'))+'</div>'); }
function shareFail(msg,canDownload){
  shareBody('<div class="sok">'+esc(tr('share.failed'))+'</div><div class="serr">'+esc(msg)+'</div>'+
    '<div class="sbtns">'+(canDownload?'<button class="sbtn pri" onclick="shareDownload()">'+esc(tr('share.download'))+'</button>':'')+
    '<button class="sbtn" onclick="renderShareOpts()">'+esc(tr('share.retry'))+'</button></div>');
}
/* What a whole conversation leaves out: thinking, a subagent's own exchange (its result reaches the
   main thread anyway), and the user-role records the CLI writes itself — a background task
   reporting back, a reminder, a local command's echo. They are machinery, not something anyone said. */
function shareFilter(msgs,whole){
  return msgs.filter(m=>{
    if(m.kind==='thinking') return false;
    if(!whole) return true;
    if(m.sub) return false;
    if(m.kind==='tool') return shareOpt.tools;
    if(m.role==='user'&&/^\s*<(task-notification|system-reminder|local-command|command-)/.test(m.text||'')) return false;
    return !!String(m.text||'').trim();
  });
}
async function shareWhole(kind){
  const id=curId; shareBusy();
  let j;
  try{
    const r=await fetch('/conversation?id='+encodeURIComponent(id)+'&full=1',{cache:'no-store',timeout:90000});
    if(!r.ok) throw new Error('HTTP '+r.status);
    j=await r.json();
  }catch(e){ if(id===curId) shareFail(tr('share.loadFailed',{err:e.message||e}),false); return; }
  if(id!==curId) return;
  await shareOut(shareFilter(j.messages||[],true),true,kind);
}
async function sharePicked(){
  const list=[...picked].sort((a,b)=>pickOrder[a]-pickOrder[b]).map(p=>pickMsgs[p]).filter(Boolean);
  if(!list.length) return;
  document.getElementById('sharename').textContent=shareCard().name;
  document.getElementById('share').classList.add('on');
  shareBusy();
  await shareOut(shareFilter(list,false),false,'link');
  endPick();
}
async function shareOut(msgs,whole,kind){
  if(!msgs.length){ shareFail(tr('share.empty'),false); return; }
  const card=shareCard(), doc=shareDoc(msgs,card,whole);
  lastShare={doc:doc,name:card.name,id:'',url:''};
  if(kind==='file'){ shareDownload(); renderShareOpts(); return; }
  try{
    const r=await fetch('/share?title='+encodeURIComponent(card.name),
      {method:'POST',body:doc,headers:{'Content-Type':'text/html; charset=utf-8'},timeout:180000});
    const j=await r.json().catch(()=>({error:'HTTP '+r.status}));
    if(!r.ok||!j.url){ shareFail(j.unconfigured?tr('share.unconfigured'):(j.error||('HTTP '+r.status)),true); return; }
    lastShare.id=j.id; lastShare.url=j.url;
    shareBody('<div class="sok">'+esc(tr('share.done'))+'</div><div class="slink">'+esc(j.url)+'</div>'+
      '<div class="sbtns"><button class="sbtn pri" onclick="copyText(lastShare.url)">'+esc(tr('share.copy'))+'</button>'+
      '<button class="sbtn" onclick="window.open(lastShare.url,\'_blank\',\'noopener\')">'+esc(tr('share.open'))+'</button>'+
      '<button class="sbtn" onclick="shareDownload()">'+esc(tr('share.download'))+'</button>'+
      '<button class="sbtn" onclick="shareWithdraw()">'+esc(tr('share.withdraw'))+'</button></div>');
  }catch(e){ shareFail(e.message||String(e),true); }
}
async function shareWithdraw(){
  if(!lastShare||!lastShare.id||!confirm(tr('share.withdrawConfirm'))) return;
  try{
    const r=await fetch('/share?del='+encodeURIComponent(lastShare.id),{method:'POST',timeout:30000});
    const j=await r.json().catch(()=>({}));
    if(!r.ok){ toast(j.error||('HTTP '+r.status),3000); return; }
    toast(tr('share.withdrawn'),2400); lastShare.id=''; closeShare();
  }catch(e){ toast(e.message||String(e),3000); }
}
function shareDownload(){
  if(!lastShare) return;
  const a=document.createElement('a');
  a.href=URL.createObjectURL(new Blob([lastShare.doc],{type:'text/html;charset=utf-8'}));
  a.download=(lastShare.name||'conversation').replace(/[\\/:*?"<>|\s]+/g,'_')+'.html';
  document.body.appendChild(a); a.click();
  setTimeout(()=>{ URL.revokeObjectURL(a.href); a.remove(); },1500);
}
/* Self-contained: its own palette (the dashboard's, light and dark by the reader's setting, since
   there is no script to pick one), its own copy of the logo, nothing fetched from anywhere. */
const SHARE_CSS=`
:root{--bg:#fdf7ff;--card:#ece6ee;--stroke:#cac4cf;--text:#1d1b20;--sub:#49454e;--accent:#65558f;--onAccent:#fff;
  --quoteBg:#e9ddff;--quoteFg:#4d3d75;--quoteCode:rgba(77,61,117,.10);--codeBg:#f2ecf4;--codeInline:rgba(29,27,32,.07);color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#141218;--card:#2b292f;--stroke:#49454e;--text:#e6e0e9;--sub:#cac4cf;--accent:#cfbdfe;
  --onAccent:#36275d;--quoteBg:#4d3d75;--quoteFg:#e9ddff;--quoteCode:rgba(255,255,255,.10);--codeBg:#0f0d13;--codeInline:rgba(255,255,255,.08);color-scheme:dark}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);
  font:15px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",system-ui,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:0 16px}
.top{border-bottom:1px solid var(--stroke)}
.top .wrap{display:flex;align-items:center;gap:10px;height:56px}
.logo{width:28px;height:28px;border-radius:8px;background:var(--accent);color:var(--onAccent);display:grid;place-items:center;flex:none}
.logo svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:2.25;stroke-linecap:round;stroke-linejoin:round}
.bname{font-size:15px;font-weight:600}
.hero{padding:28px 0 4px}
.kicker{font-size:12px;line-height:18px;color:var(--sub)}
h1.name{margin:4px 0 6px;font-size:26px;line-height:1.3;font-weight:600;word-break:break-word}
.meta{font-size:13px;line-height:20px;color:var(--sub)}
.conv{padding:8px 0 40px}
.day{margin:28px 0 12px;text-align:center;font-size:12px;color:var(--sub)}
.msg{margin:0 0 18px}
.msg.user{margin-top:26px}
.when{display:block;margin:0 4px 4px;text-align:right;font-size:11px;line-height:16px;color:var(--sub)}
.tag{margin-bottom:2px;font-size:11px;font-weight:600;color:var(--accent)}
.msg.user .md{padding:12px 16px;border-radius:16px;background:var(--quoteBg);color:var(--quoteFg)}
.msg.user .md code{background:var(--quoteCode)}
.msg.user .md a{color:inherit}
.tool{display:flex;align-items:baseline;gap:8px;min-width:0;margin:0 0 8px;padding:7px 12px;border-radius:10px;
  background:var(--card);font-size:12px;line-height:18px}
.tool .tn{flex:none;font-weight:600}
.tool .ts{min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;color:var(--sub);
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.md{word-break:break-word}
.md p{margin:0 0 10px}.md p:last-child{margin-bottom:0}
.md h1,.md h2,.md h3{margin:18px 0 8px;line-height:1.4;font-weight:600}
.md h1,.md h2{font-size:18px}.md h3{font-size:16px}
.md ul,.md ol{margin:4px 0 10px;padding-left:22px}
.md li{margin:3px 0}
.md blockquote{margin:8px 0;padding:2px 0 2px 12px;border-left:3px solid var(--stroke);color:var(--sub)}
.md hr{margin:14px 0;border:0;border-top:1px solid var(--stroke)}
.md a{color:var(--accent)}
.md code{padding:1px 5px;border-radius:4px;background:var(--codeInline);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.88em}
.md pre.code{position:relative;margin:10px 0;padding:12px 14px;border:1px solid var(--stroke);border-radius:10px;background:var(--codeBg);
  overflow-x:auto;white-space:pre;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;line-height:1.55}
.md pre.code i.lang{position:absolute;right:10px;top:4px;font-style:normal;font-size:11px;color:var(--sub)}
.md table{display:block;margin:10px 0;overflow-x:auto;border-collapse:collapse;font-size:13px}
.md th,.md td{padding:5px 9px;border:1px solid var(--stroke);text-align:left}
.md th{background:var(--card);font-weight:600}
.foot{border-top:1px solid var(--stroke);padding:20px 0 calc(28px + env(safe-area-inset-bottom));font-size:12px;color:var(--sub)}
.foot .wrap{display:flex;align-items:center;gap:8px}
.foot .logo{width:20px;height:20px;border-radius:6px}.foot .logo svg{width:12px;height:12px}
`;
function shareDoc(msgs,card,whole){
  const valid=ts=>{ const d=ts?new Date(ts):null; return d&&!isNaN(d)?d:null; };
  const dayOf=d=>d.toLocaleDateString(LOCALE,{year:'numeric',month:'long',day:'numeric',weekday:'short'});
  let body='', lastDay='';
  for(const m of msgs){
    const d=valid(m.ts);
    if(d&&dayOf(d)!==lastDay){ lastDay=dayOf(d); body+='<div class="day">'+esc(lastDay)+'</div>'; }
    if(m.kind==='tool'){
      body+='<div class="tool"><span class="tn">'+esc(m.tool||'')+'</span><span class="ts">'+esc(m.text||'')+'</span></div>';
      continue;
    }
    const user=m.role==='user';
    body+='<div class="msg '+(user?'user':'asst')+'">'+(m.sub?'<div class="tag">'+esc(tr('chat.subagent'))+'</div>':'')+
      (user&&d?'<span class="when">'+esc(hhmm(m.ts))+'</span>':'')+'<div class="md">'+md(m.text)+'</div></div>';
  }
  const stamps=msgs.map(m=>valid(m.ts)).filter(Boolean);
  const at=d=>d.toLocaleString(LOCALE,{year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
  let span='';
  if(stamps.length){
    const a=stamps[0], b=stamps[stamps.length-1];
    span=at(a)+(b-a>60000?' – '+(dayOf(a)===dayOf(b)?hhmm(b.toISOString()):at(b)):'');
  }
  const said=msgs.filter(m=>m.kind!=='tool').length;
  const agent={claude:'Claude Code',codex:'Codex'}[card.agent]||'';
  const kicker=[agent,card.project,(card.model||'').replace(/^claude-/,'')].filter(Boolean).join(' · ');
  const meta=[tr(whole?'share.docAll':'share.docPart'),tr('share.docCount',{n:said}),span].filter(Boolean).join(' · ');
  const logo='<span class="logo"><svg viewBox="0 0 24 24" aria-hidden="true">'+IC['layout-grid']+'</svg></span>';
  return '<!doctype html><html lang="'+LOCALE+'"><head><meta charset="utf-8">'+
    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'+
    '<meta name="robots" content="noindex"><meta name="generator" content="FleetView">'+
    '<title>'+esc(card.name)+' · FleetView</title><style>'+SHARE_CSS+'</style></head><body>'+
    '<header class="top"><div class="wrap">'+logo+'<span class="bname">FleetView</span></div></header>'+
    '<main class="wrap"><div class="hero">'+(kicker?'<div class="kicker">'+esc(kicker)+'</div>':'')+
    '<h1 class="name">'+esc(card.name)+'</h1><div class="meta">'+esc(meta)+'</div></div>'+
    '<div class="conv">'+body+'</div></main>'+
    '<footer class="foot"><div class="wrap">'+logo+'<span>'+esc(tr('share.docFooter'))+' · '+esc(at(new Date()))+'</span></div></footer>'+
    '</body></html>';
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
  let html=notes.map(n=>presetEdit
    ?`<div class="nrow"><span class="ntext">${esc(n.text)}</span><button class="ndel" onclick="delNote('${n.id}')">${tr('notes.delete')}</button></div>`
    :`<button class="nrow" onclick="usePreset('${n.id}')" title="${esc(n.text).replace(/"/g,'&quot;')}"><span class="ntext">${esc(n.text)}</span><span class="nuse">${ic('corner-down-left','s16')}</span></button>`).join('');
  if(!notes.length) html='<div class="nempty">'+
    (q?tr('notes.noMatch',{q:esc(q)}):tr('notes.none'))+'</div>';
  document.getElementById('presets').innerHTML=html;
  const ed=document.getElementById('nedit');
  ed.textContent=tr(presetEdit?'notes.done':'notes.edit'); ed.classList.toggle('on',presetEdit);
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
  closeDrawer();
  autoGrow(ta); ta.focus();
  syncSendBtn(); saveDraft();
}
async function addNote(){const c=prompt(tr('notes.addPrompt'));
  if(c&&c.trim()){await fetch('/note?add='+encodeURIComponent(c.trim()));await refreshState();renderPresets();}}
async function delNote(id){await fetch('/note?del='+encodeURIComponent(id));await refreshState();renderPresets();}
function toggleEditPresets(){presetEdit=!presetEdit;renderPresets();}
renderPresets();

/* ---------- the drawer under the composer ----------
   Quick commands and the ⊕ tiles, one at a time, where the keyboard would otherwise be — WeChat's
   arrangement. The quick commands used to be a strip of chips above the box: always on screen,
   mostly scrolled out of sight, and a filter field 82px wide. */
function drawerPane(){ const p=document.querySelector('#drawer .dpane.on'); return p?p.dataset.pane:''; }
function openDrawer(pane){
  document.querySelectorAll('#drawer .dpane').forEach(p=>p.classList.toggle('on',p.dataset.pane===pane));
  document.querySelectorAll('#sendrow .rb').forEach(b=>b.classList.toggle('on',b.dataset.pane===pane));
  document.getElementById('term').classList.add('drawer');
  if(pane==='notes'){ presetEdit=false; document.getElementById('pfind').value=''; renderPresets(); }
  placeJump();
}
function closeDrawer(){
  const t=document.getElementById('term');
  if(!t.classList.contains('drawer')) return;
  t.classList.remove('drawer');
  document.querySelectorAll('#drawer .dpane').forEach(p=>p.classList.remove('on'));
  document.querySelectorAll('#sendrow .rb').forEach(b=>b.classList.remove('on'));
  const f=document.getElementById('pfind'); if(document.activeElement===f) f.blur();
  placeJump();
}
(function(){
  for(const b of document.querySelectorAll('#sendrow .rb')){
    /* A press would take focus from the box, and on a phone losing focus is the keyboard dropping:
       the row jumps out from under the finger and the tap lands on something else — the same fault
       that once made Send take two taps. So the press is swallowed and the work happens on click. */
    b.addEventListener('pointerdown',e=>{ if(!e.button) e.preventDefault(); });
    b.addEventListener('click',()=>{
      const pane=b.dataset.pane;
      if(drawerPane()===pane){
        closeDrawer();
        if(pane==='notes') document.getElementById('inputtext').focus();
        return;
      }
      openDrawer(pane);
      if(pane==='notes'){
        /* Straight into the search, inside the tap itself: iOS raises the keyboard only for a
           focus() it can tie to a gesture, and one made after an await or a timeout gets none. */
        document.getElementById('pfind').focus();
      }else{
        // The tiles are the keyboard's alternative, as in WeChat, so the keyboard goes away.
        const a=document.activeElement;
        if(a&&(a.id==='inputtext'||a.id==='pfind')) a.blur();
      }
    });
  }
  // Back in the box means done choosing: fold the drawer away.
  document.getElementById('inputtext').addEventListener('focus',closeDrawer);
  document.getElementById('pfind').addEventListener('keydown',e=>{
    if(e.key==='Escape'){ closeDrawer(); document.getElementById('inputtext').focus(); return; }
    // Return takes the first match: the list is searched in order to be used, not browsed.
    if(e.key==='Enter'&&!e.isComposing){
      e.preventDefault();
      const first=document.querySelector('#presets button.nrow');
      if(first) first.click();
    }
  });
})();

/* ---------- headers that get out of the way ----------
   Reading down hides the bar; any scroll back up, or being near the top, brings it back. Only
   scrolls a person made count. The poll landing new messages, jumpLatest and the keyboard
   re-measure all move the pane too — and opening a conversation lands at its bottom — so a bar
   that followed every scroll would vanish whenever the agent said something, and on every open. */
function autoHide(scroller,target,cls,limit,skip){
  let lastY=0, acc=0, userUntil=0;
  const y=()=>scroller===window?window.scrollY:scroller.scrollTop;
  const view=()=>scroller===window?window.innerHeight:scroller.clientHeight;
  /* "Yours" is a chain, not a window: input starts it, and every scroll frame after it keeps it alive
     for another 150ms. A glide after the finger lifts is a frame every ~16ms, so it stays yours; a
     jump landed half a second later by the poll or jumpLatest does not. A flat second after touchend
     was long enough to let those through, and the bar hid itself on "take me to the latest". */
  const mine=()=>{ userUntil=performance.now()+150; };
  /* A tap is not a scroll. Counting touchend on its own let a tapped button's consequence — "Open"
     jumping the board to the project it just added — pass for the finger's own scroll and hide the
     header you were about to use. Only a finger that moved, and the glide after it, count. */
  let moved=false;
  scroller.addEventListener('touchstart',()=>{ moved=false; },{passive:true});
  scroller.addEventListener('touchmove',()=>{ moved=true; mine(); },{passive:true});
  scroller.addEventListener('touchend',()=>{ if(moved) mine(); },{passive:true});
  scroller.addEventListener('wheel',mine,{passive:true});
  const set=hide=>{
    if(target.classList.contains(cls)===hide) return;
    target.classList.toggle(cls,hide);
    if(scroller!==window) updateStickyPrompt();
  };
  scroller.addEventListener('scroll',()=>{
    const cur=y(), dy=cur-lastY; lastY=cur;
    if(skip&&skip()){ acc=0; return; }
    if(cur<limit()){ acc=0; set(false); return; }
    const now=performance.now();
    if(now>userUntil){ acc=0; return; }
    userUntil=now+150;
    if(Math.abs(dy)>view()){ acc=0; return; }       // a jump, not a scroll: no finger moves a screen a frame
    if((dy>0)!==(acc>0)) acc=0;
    acc+=dy;
    // A little travel first, so the jitter at the end of a flick cannot flap the bar.
    if(acc>28) set(true); else if(acc<-28) set(false);
  },{passive:true});
  return ()=>{ acc=0; target.classList.remove(cls); };
}
const showTermHead=autoHide(document.getElementById('chat'),document.getElementById('term'),'headhide',
  ()=>document.getElementById('thead').offsetHeight,
  ()=>curView!=='chat');
const showBoardHead=autoHide(window,document.querySelector('body > header'),'hide',
  ()=>document.getElementById('panel').offsetHeight+document.querySelector('body > header').offsetHeight,
  // Parked behind the overlay, dragging a card, or with the files tray open under it: stay put.
  ()=>document.body.classList.contains('locked')||dragging||
      document.getElementById('tray').classList.contains('on')||
      document.getElementById('projs').classList.contains('on'));
/* The transcript starts below the bar, however tall the bar is today — a notch, a wrapped title. */
if(window.ResizeObserver){
  new ResizeObserver(()=>{
    document.getElementById('term').style.setProperty('--headh',document.getElementById('thead').offsetHeight+'px');
    updateStickyPrompt();
  }).observe(document.getElementById('thead'));
}

/* ---------- composer size ----------
   Two states, one number: 0 is the auto-growing three-line bar, anything else is an explicit height
   in pixels and turns the bar into the expanded editor (see #inputbar.big). The grip drags between
   them, the ⤢ button jumps. Both are remembered per device — how tall a box you want to write in is
   a property of the thing you are typing on, not of the fleet. */
const BAR_MIN=170;
let barH=parseInt(localStorage.getItem('fv_barh')||'',10)||0;
/* The composer's own font size, and the floor under it. On a touch device that floor is 16px for
   the reason the stylesheet gives: below it, focusing the box zooms the whole page and the overlay
   stops fitting the screen. It has to be applied to this number too — an inline font-size beats the
   rule — and applied on the way in, so a 14px left in localStorage from before doesn't survive. */
const TA_MIN=matchMedia('(pointer:coarse)').matches?16:11;
let taFontPx=Math.min(30,Math.max(TA_MIN,parseInt(localStorage.getItem('fv_tafont')||'',10)||14));
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
  const ex=document.getElementById('expand');
  ex.innerHTML=ic(barH?'minimize-2':'maximize-2'); ex.title=tr(barH?'composer.collapseEditor':'composer.expandEditor');
  document.getElementById('bigLabel').textContent=tr(barH?'common.collapse':'more.editor');
  autoGrow(document.getElementById('inputtext'));
  placeJump();                      // the bar just changed height; the ↓ rides on top of it
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
  /* Clearing the height is what "one row" means here: `rows="1"` and the CSS min-height already
     draw an empty box, and scrollHeight must not be allowed to argue with them. Two ways it did.
     Empty, Chromium measures the *placeholder* rather than the value, and this placeholder is a
     sentence — on a phone it wraps to three lines, so an untouched composer opened three rows tall.
     Hidden, everything measures 0, and applyTaFont runs at load while #term is still display:none:
     that 0 was written back as an inline height and nothing recomputed it until the first
     keystroke, so every conversation opened with a box 22px tall and its placeholder clipped
     through the middle. */
  if(!ta.value){ ta.style.height=''; return; }
  ta.style.height='auto';
  const h=ta.scrollHeight;
  if(!h){ ta.style.height=''; return; }
  ta.style.height=Math.min(120,h)+'px';
}
/* The placeholder is a sentence, and a one-row box on a phone shows the first third of it with the
   rest wrapped and clipped — which reads as a broken control rather than as a hint. The half that
   goes is the half that does not apply there anyway: a touch keyboard has no Shift+Enter. Same
   560px line the expanded composer uses, so "this is a phone" is decided in one place. */
const NARROW=matchMedia('(max-width:560px)');
function fitPlaceholder(){
  document.getElementById('inputtext').placeholder=tr(NARROW.matches?'composer.placeholderShort':'composer.placeholder');
}
NARROW.addEventListener('change',fitPlaceholder);
fitPlaceholder();
function applyTaFont(){
  const ta=document.getElementById('inputtext');
  ta.style.fontSize=taFontPx+'px';
  autoGrow(ta);
}
function taFont(d){
  taFontPx=Math.min(30,Math.max(TA_MIN,taFontPx+d));
  localStorage.setItem('fv_tafont',String(taFontPx));
  applyTaFont(); toast(taFontPx+'px');
}
applyTaFont();
(function(){
  const g=document.querySelector('#grip .gbar');
  let y0=0,h0=0,down=false,live=false;
  /* Nothing resizes until the finger has actually travelled. Without this any contact that moved a
     pixel was a drag, and since setBarHeight clamps up to BAR_MIN the bar jumped from 114px to
     170px and into the expanded grid — from a brush on the way to the textarea. */
  const SLOP=10;
  g.addEventListener('pointerdown',e=>{
    down=true; live=false; y0=e.clientY; h0=document.getElementById('inputbar').offsetHeight;
    g.setPointerCapture(e.pointerId); e.preventDefault();
  });
  g.addEventListener('pointermove',e=>{
    if(!down)return;
    if(!live){ if(Math.abs(e.clientY-y0)<SLOP) return; live=true; }
    setBarHeight(h0+(y0-e.clientY));
  });
  const end=()=>{
    if(!down)return;
    down=false;
    if(!live)return;                 // a tap, or a brush that never passed SLOP: leave the height alone
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
  closeDrawer();
  const owner=curId;
  ta.value='';autoGrow(ta);saveDraft();pendingPos=null;
  showSent(t);                       // don't wait a round trip to acknowledge the send
  stickBottom=true; jumpLatest();    // follow your own message down, wherever you were reading
  markSent();                       // the hook is a beat behind; don't sit on 'idle' meanwhile
  /* wait=1: the Mac answers once it has seen the prompt leave the agent's input box, pressing Enter
     again if it had not — Codex takes text followed at once by Enter as a paste and turns that Enter
     into a newline. "stuck" is the one case that needs you: the text is typed but never ran, which
     on the board looks exactly like an agent ignoring you. An older Mac answers without "submit". */
  const req=fetch('/type?id='+encodeURIComponent(curId)+'&enter=1&wait=1&text='+encodeURIComponent(t),{timeout:0});
  setTimeout(loadChat,400);
  try{
    const r=await (await req).json();
    if(r&&r.submit==='stuck'){ sentAt=0; renderInfo(curInfo);
      toast(tr('toast.stuck'),5000); }
  }catch(e){
    // Back to the card it was written for, which may no longer be the one on screen.
    if(curId===owner){ ta.value=t; autoGrow(ta); saveDraft(); sentAt=0; renderInfo(curInfo);
                       if(sentGhost){ sentGhost.node.remove(); sentGhost=null; } }
    else cardPut(DRAFT_KEY,owner,{v:t});
  }
}
/* ---------- files an agent sent (the outbox) ----------
   The mirror of the attach button: `fleetview-send` drops a file in ~/.fleetview/outbox and it
   turns up here, one tap from opening on the phone. Polled with the rest of the dashboard, so a
   file that lands while you are looking appears on its own. */
let trayFiles=[];
function fileIcon(ext){
  if(['png','jpg','jpeg','gif','webp','heic','avif','svg'].includes(ext))return ic('image');
  if(ext==='pdf')return ic('file-text');
  if(['csv','xlsx','xls'].includes(ext))return ic('sheet');
  if(['zip','tar','gz','tgz'].includes(ext))return ic('archive');
  if(['mp4','mov','mp3','wav','m4a'].includes(ext))return ic('film');
  if(['txt','log','md','json','yml','yaml'].includes(ext))return ic('file-text');
  return ic('file');
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
/* When a file was sent, in this device's time: 今天 14:15 / Today 14:15, 昨天 21:03, 9月26日 22:15 /
   Sep 26 22:15, and the year only once it is not this one. `ts` is UTC as fleetview-send writes it. */
function fileWhen(ts){
  const d=new Date(ts||'');
  if(isNaN(d)) return '';
  const p=n=>String(n).padStart(2,'0'), now=new Date(), hm=p(d.getHours())+':'+p(d.getMinutes());
  const day=x=>x.getFullYear()+'-'+x.getMonth()+'-'+x.getDate();
  const yest=new Date(now); yest.setDate(now.getDate()-1);
  if(day(d)===day(now)) return tr('time.today',{time:hm});
  if(day(d)===day(yest)) return tr('time.yesterday',{time:hm});
  const v={y:d.getFullYear(),m:d.getMonth()+1,d:d.getDate(),mon:d.toLocaleString(LOCALE,{month:'short'}),time:hm};
  return tr(d.getFullYear()===now.getFullYear()?'time.date':'time.dateYear',v);
}
function renderTray(){
  const el=document.getElementById('traylist');
  if(!trayFiles.length){ el.innerHTML='<div class="tnone">'+tr('tray.empty')+'</div>'; return; }
  /* `from` is a terminal id — the server deliberately leaves naming to us, since the dashboard
     already knows every terminal from /state. */
  const names={};
  for(const t of (state?.terminals||[])) names[t.id]=t.name;
  // Newest first. The server sends them in that order already; an older FleetView does not.
  const files=[...trayFiles].sort((a,b)=>(b.ts||'').localeCompare(a.ts||'')||(a.name||'').localeCompare(b.name||''));
  el.innerHTML=files.map(f=>{
    const when=fileWhen(f.ts);
    const facts=[kb(f.bytes||0), names[f.from]||''].filter(Boolean).join(' · ');
    const full=[when&&new Date(f.ts).toLocaleString(), f.note||''].filter(Boolean).join('\n');
    return '<a class="f" href="/file?id='+encodeURIComponent(f.id)+'" target="_blank" rel="noopener" title="'+att(full)+'">'
      +'<span class="fi">'+fileIcon((f.ext||'').toLowerCase())+'</span>'
      +'<span class="fb"><span class="fn">'+esc(f.name||f.id)+'</span>'
      +'<span class="fm">'+(when?'<span class="fd">'+esc(when)+'</span>'+(facts?' · ':''):'')+esc(facts)+'</span>'
      +(f.note?'<span class="fnote">'+esc(f.note)+'</span>':'')
      +'</span></a>';
  }).join('');
}
function toggleTray(){
  const t=document.getElementById('tray');
  t.classList.toggle('on');
  if(t.classList.contains('on')){ closeProjects(); renderTray(); loadFiles(); }
}

/* ---------- open a project ----------
   The phone could only make terminals in projects already on the board; this adds any folder in
   ~/PycharmProjects to it — the server refuses anything else (AppState+Workspace). */
let wsFolders=[];
async function toggleProjects(){
  const el=document.getElementById('projs');
  if(el.classList.contains('on')){ closeProjects(); return; }
  document.getElementById('tray').classList.remove('on');
  el.classList.add('on'); document.getElementById('projbtn').classList.add('on');
  const q=document.getElementById('pquery'); q.value='';
  q.focus();                                   // inside the tap, so a phone raises its keyboard
  document.getElementById('projlist').innerHTML='<div class="tnone">'+tr('common.loading')+'</div>';
  try{ wsFolders=(await(await fetch('/workspace',{cache:'no-store'})).json()).folders||[]; }
  catch(e){ wsFolders=[]; }
  renderProjects();
}
function closeProjects(){
  document.getElementById('projs').classList.remove('on');
  document.getElementById('projbtn').classList.remove('on');
  const q=document.getElementById('pquery'); if(document.activeElement===q) q.blur();
}
function renderProjects(){
  const q=(document.getElementById('pquery').value||'').trim().toLowerCase();
  const list=q?wsFolders.filter(f=>f.name.toLowerCase().includes(q)):wsFolders;
  const el=document.getElementById('projlist');
  if(!list.length){ el.innerHTML='<div class="tnone">'+tr(q?'proj.noMatch':'proj.none')+'</div>'; return; }
  el.innerHTML=list.map((f,i)=>{
    const when=f.modified?ago(Math.round(Date.now()/1000-f.modified)):'';
    const meta=[f.git?'git':'', when].filter(Boolean).join(' · ');
    return '<div class="prow"><span class="pn"><b>'+esc(f.name)+(f.projectId?'<span class="onb">'+tr('proj.onBoard')+'</span>':'')+
      '</b><span>'+esc(meta)+'</span></span>'+
      '<button onclick="openProject('+i+',false)">'+tr(f.projectId?'proj.go':'proj.open')+'</button>'+
      '<button class="go" onclick="openProject('+i+',true)">'+tr('common.newTerm')+'</button></div>';
  }).join('');
}
/* Open it (a no-op if it is already on the board), then take the board there — and with the second
   button, start a terminal in it and go straight into that. */
async function openProject(i,withTerm){
  const q=(document.getElementById('pquery').value||'').trim().toLowerCase();
  const f=(q?wsFolders.filter(x=>x.name.toLowerCase().includes(q)):wsFolders)[i]; if(!f)return;
  let pid=f.projectId;
  try{
    if(!pid){
      const r=await fetch('/project/open?path='+encodeURIComponent(f.path));
      if(!r.ok){ toast(tr('toast.cantOpen',{name:f.name})); return; }
      pid=(await r.json()).id;
    }
    closeProjects();
    if(withTerm&&pid){
      const t=await(await fetch('/new?projectId='+encodeURIComponent(pid))).json();
      await tick();
      if(t.id){ openTerm(t.id,f.name); return; }
    }
    await tick();
    // A project that has been quiet for two hours is a one-line row rather than a section.
    const sec=document.querySelector('.proj[data-pid="'+pid+'"]');
    if(sec) sec.scrollIntoView({block:'start',behavior:'smooth'});
    showBoardHead();
    toast(f.projectId?f.name:tr('toast.opened',{name:f.name}));
  }catch(e){ toast(tr('toast.cantOpen',{name:f.name})); }
}

/* Files: an agent reads a file by opening it, so getting one out of a phone and into a prompt means
   putting the bytes on the Mac and typing the path. The upload answers with the absolute path it
   wrote, which is inserted at the cursor — the same thing you would do by hand after AirDropping
   the file, minus the AirDrop. */
function fmtBytes(n){
  if(n<1024) return Math.round(n)+' B';
  if(n<1048576) return (n/1024).toFixed(0)+' KB';
  return (n/1048576).toFixed(1)+' MB';
}

/* The upload readout. Sits above the toast rather than replacing it: a toast is a thing that
   happened, this is a thing still happening, and a phone upload over a slow link is long enough
   that "did it freeze?" is a real question. */
function uprogBox(){
  let p=document.getElementById('uprog');
  if(p) return p;
  p=document.createElement('div');p.id='uprog';
  p.style.cssText='position:fixed;left:50%;bottom:112px;transform:translateX(-50%);z-index:71;'+
    'pointer-events:none;background:var(--inverseSurface);color:var(--inverseOnSurface);'+
    'padding:10px 14px;border-radius:8px;font-size:12px;line-height:16px;box-shadow:0 6px 20px rgba(0,0,0,.35);'+
    'min-width:200px;max-width:78vw;opacity:0;transition:opacity .15s';
  p.innerHTML='<div id="uprogtext" style="margin-bottom:6px;white-space:nowrap;overflow:hidden;'+
    'text-overflow:ellipsis"></div>'+
    '<div style="height:4px;background:color-mix(in srgb,var(--inverseOnSurface) 24%,transparent);border-radius:2px;overflow:hidden">'+
    '<div id="uprogbar" style="height:100%;width:0;background:var(--accent);transition:width .12s">'+
    '</div></div>';
  document.body.appendChild(p);
  return p;
}
function uprogHide(){ const p=document.getElementById('uprog'); if(p) p.style.opacity='0'; }

/* XHR, not fetch: fetch has no hook for request-body progress, so the percentage and the rate can
   only come from XMLHttpRequest's upload events. The server reads the whole body before it writes
   anything, so this is the only place a progress figure exists at all. */
function uploadOne(f,label){
  return new Promise((resolve,reject)=>{
    const box=uprogBox();
    const txt=document.getElementById('uprogtext'), bar=document.getElementById('uprogbar');
    const name=f.name||tr('upload.file');
    bar.style.width='0';
    txt.textContent=label+name;
    box.style.opacity='1';
    const t0=Date.now(); let lastT=t0, lastL=0, rate=0;
    const x=new XMLHttpRequest();
    x.open('POST','/upload?name='+encodeURIComponent(f.name||''));
    x.setRequestHeader('Content-Type',f.type||'application/octet-stream');
    x.upload.onprogress=e=>{
      if(!e.lengthComputable) return;
      const now=Date.now();
      /* Rate from the last ~300ms, smoothed, rather than an average since the start: an average
         goes on reporting the speed of a stall long after the stall has cleared. */
      if(now-lastT>300){
        const inst=(e.loaded-lastL)*1000/(now-lastT);
        rate=rate?rate*0.6+inst*0.4:inst;
        lastT=now; lastL=e.loaded;
      }else if(!rate && now>t0){
        /* Before the first window closes there is no sample to smooth, so fall back to the average
           since the start. Without this a transfer that finishes inside 300ms — which on a LAN is
           most of them — never shows a rate at all. */
        rate=e.loaded*1000/(now-t0);
      }
      const pct=Math.round(e.loaded/e.total*100);
      bar.style.width=pct+'%';
      txt.textContent=label+name+' · '+pct+'% · '+fmtBytes(e.loaded)+'/'+fmtBytes(e.total)+
                      (rate>0?' · '+fmtBytes(rate)+'/s':'');
    };
    x.onload=()=>{
      let j=null; try{ j=JSON.parse(x.responseText); }catch(_){}
      if(j&&j.path){ bar.style.width='100%'; resolve(j.path); }
      else reject(new Error((j&&j.error)||('HTTP '+x.status)));
    };
    x.onerror=()=>reject(new Error(tr('upload.netError')));
    x.onabort=()=>reject(new Error(tr('upload.cancelled')));
    x.send(f);
  });
}

async function attachFiles(files){
  const list=[...files];
  if(!list.length)return;
  const owner=curId;                 // an upload outlasts a switch to another card
  const btn=document.getElementById('imgbtn');
  // The attach control is a tile now; only its label changes, or the icon would be wiped with it.
  const lab=btn.querySelector('.tl')||btn;
  const was=lab.textContent; btn.disabled=true; lab.textContent='…';
  const paths=[];
  for(let i=0;i<list.length;i++){
    const f=list[i];
    /* Only worth saying which one when there is more than one. */
    const label=list.length>1?('('+(i+1)+'/'+list.length+') '):'';
    try{
      /* The name rides along in the query so the server can keep the extension — an agent keys off
         .csv or .pdf, and the basename it writes is still its own uuid. */
      paths.push(await uploadOne(f,label));
    }catch(e){
      lab.textContent='✕';
      setTimeout(()=>{lab.textContent=was;},1400);
      toast(tr('toast.uploadFailed',{err:e.message}));
    }
  }
  uprogHide();
  btn.disabled=false;
  if(lab.textContent==='…') lab.textContent=was;
  if(!paths.length) return;
  const text=paths.join(' ')+' ';
  if(curId===owner){ insertAtCursor(document.getElementById('inputtext'),text); saveDraft(); return; }
  const d=(cardMap(DRAFT_KEY)[owner]||{}).v||'';
  cardPut(DRAFT_KEY,owner,{v:d+(d&&!/\s$/.test(d)?' ':'')+text});
  const term=((state&&state.terminals)||[]).find(x=>x.id===owner);
  toast(tr('toast.attachedTo',{name:term?term.name:owner.slice(0,8)}),2400);
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
document.getElementById('imgbtn').addEventListener('click',()=>{
  document.getElementById('imgfile').click();   // first, while this is still the tap that allows it
  closeDrawer();
});
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
document.getElementById('inputtext').addEventListener('input',e=>{autoGrow(e.target);syncSendBtn();saveDraft();});

/* ---------- project file browser ----------
   The project's own directory, walked from the phone. What it is for: an agent cites a file, and
   until now the only way to look at it was to be at the Mac. Every path is confined to a project
   root by the server (see WebServer.confine); the one thing it writes is a markdown file opened in
   the editor below, and only through /save. */
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
   http on the LAN, so the old selection trick is not a fallback — it is the normal path.
   `quiet` is for a caller that says "copied" where the tap was (the card's id chip): it only hears
   about a failure, and that in words that do not tell you to long-press a path. */
async function copyText(s,quiet){
  try{
    if(navigator.clipboard&&window.isSecureContext){
      await navigator.clipboard.writeText(s); if(!quiet) toast(tr('toast.copied')); return true; }
  }catch(e){}
  const failed=tr(quiet?'toast.copyFailed':'toast.copyFailedLong');
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
    if(!ok) toast(failed); else if(!quiet) toast(tr('toast.copied'));
    return ok;
  }catch(e){ toast(failed); return false; }
}
function fbOpen(path){
  document.getElementById('fb').classList.add('show');
  lockBoard();
  fbList(path);
}
/* A folder or a file, from a link (`/#fb=<path>`, what ↗ opens): /browse says which, since a folder
   may have a dot in its name and a file need not. */
async function fbOpenPath(p){
  document.getElementById('fb').classList.add('show');
  lockBoard();
  if(await fbList(p)) return;
  if(await fbList(p.replace(/\/+$/,'').split('/').slice(0,-1).join('/')||'/')) fbShow(p);
}
function fbClose(){
  if(!fbLeaveOk()) return;
  document.getElementById('fb').classList.remove('show');
  unlockBoard('');
  fbDir=fbRoot=fbFile=''; fbDoc=null;
  fbSyncHash();
}
/* Up: out of a preview back to its directory first, then one level towards the project root —
   which is where it stops, because that is where the server's confinement stops too. */
function fbUp(){
  if(fbFile){ if(fbLeaveOk()) fbList(fbDir); return; }
  if(!fbDir||fbDir===fbRoot) return;
  fbList(fbDir.replace(/\/+$/,'').split('/').slice(0,-1).join('/')||'/');
}
function fbCopyHere(){ copyText(fbFile||fbDir); }
function fbHead(){
  const full=fbFile||fbDir;
  document.getElementById('fbname').textContent=fbBase(full);
  document.getElementById('fbup').disabled=!fbFile&&(!fbDir||fbDir===fbRoot);
  fbSyncHash();
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
  body.innerHTML='<div class="fbnote">'+tr('common.loading')+'</div>';
  let j;
  try{
    const r=await fetch('/browse?path='+encodeURIComponent(dir),{cache:'no-store'});
    j=await r.json();
    if(!r.ok) throw new Error(j.error||('HTTP '+r.status));
  }catch(e){ body.innerHTML='<div class="fbnote">'+esc(e.message||tr('fb.listFailed'))+'</div>'; return false; }
  fbFile=''; fbDir=j.path; fbRoot=j.root; fbDoc=null;
  fbHead();
  let html='';
  if(j.truncated) html+='<div class="fbnote">'+tr('fb.truncated',{n:j.entries.length})+'</div>';
  for(const e of j.entries){
    html+='<div class="fbrow" data-p="'+att(fbJoin(j.path,e.name))+'" data-d="'+(e.dir?1:0)+'">'
        + '<span class="fbi">'+(e.dir?ic('folder'):fileIcon(extOf(e.name)))+'</span>'
        + '<span class="fbn">'+esc(e.name)+'</span>'
        + '<span class="fbs">'+(e.dir?'':kb(e.size||0))+'</span>'
        + '<button class="fbc" title="'+tr('fb.copyPath')+'" aria-label="'+tr('fb.copyPath')+'">'+ic('copy','s16')+'</button></div>';
  }
  if(!j.entries.length) html+='<div class="fbnote">'+tr('fb.emptyDir')+'</div>';
  body.innerHTML=html;
  body.scrollTop=0;
  return true;
}
async function fbShow(path){
  fbFile=path; fbDoc=null; fbHead();
  const body=document.getElementById('fbbody');
  const e=extOf(path), url='/read?path='+encodeURIComponent(path);
  if(MDEXT.includes(e)) return fbLoadMd(path,'view');
  if(IMGEXT.includes(e)){ body.innerHTML='<img class="fbimg" src="'+att(url)+'">'; body.scrollTop=0; return; }
  if(e==='pdf'){ body.innerHTML='<iframe class="fbpdf" src="'+att(url)+'"></iframe>'; return; }
  body.innerHTML='<div class="fbnote">'+tr('common.loading')+'</div>';
  try{
    const r=await fetch(url,{cache:'no-store'});
    const type=r.headers.get('content-type')||'';
    if(!r.ok){
      // 415 is the server saying "this is binary" — the answer to that is a download, not an error.
      const msg=esc(await r.text());
      body.innerHTML='<div class="fbnote">'+msg+(r.status===415
        ?'<br><a href="'+att(url)+'&dl=1">'+tr('fb.download')+'</a>':'')+'</div>';
      return;
    }
    if(type.startsWith('image/')){ body.innerHTML='<img class="fbimg" src="'+att(url)+'">'; return; }
    const t=await r.text();
    body.innerHTML='<pre class="fbtext"></pre>';
    body.querySelector('pre').textContent=t;      // textContent, so a file of HTML stays a file
  }catch(err){ body.innerHTML='<div class="fbnote">'+tr('fb.readFailed')+'</div>'; }
  body.scrollTop=0;
}
document.getElementById('fbbody').addEventListener('click',e=>{
  const row=e.target.closest('.fbrow'); if(!row)return;
  if(e.target.closest('.fbc')){ copyText(row.dataset.p); return; }
  if(row.dataset.d==='1') fbList(row.dataset.p); else fbShow(row.dataset.p);
});
document.getElementById('fbcrumbs').addEventListener('click',e=>{
  const b=e.target.closest('b'); if(b&&fbLeaveOk()) fbList(b.dataset.p);
});

/* ↻ is "what is on disk now": the folder listed again, or the file read again — an agent may have
   just written it. Over unsaved edits it asks first, since reading the disk replaces them. */
function fbRefresh(){
  if(fbDoc){ if(fbDirty()&&!confirm(tr('fb.confirmReload'))) return;
    const top=document.getElementById('fbbody').scrollTop;
    fbLoadMd(fbDoc.path,fbDoc.mode,top); return; }
  if(fbFile){ fbShow(fbFile); return; }
  if(fbDir) fbList(fbDir);
}
/* ↗: what the browser shows better on its own — a page rendered (its stylesheets and scripts
   resolve beside it, through /raw), an image, a PDF, a video — opens as itself. A folder, a
   markdown file and source open as this browser in a tab of their own, where markdown can still be
   edited and a folder still walked. */
const RAWEXT=['html','htm','pdf','svg','mp4','mov','mp3'];
function fbNewTab(){
  const p=fbFile||fbDir; if(!p) return;
  const e=extOf(p);
  const raw=fbFile&&(RAWEXT.includes(e)||IMGEXT.includes(e));
  window.open(raw?'/raw'+p.split('/').map(encodeURIComponent).join('/')
                 :'/#fb='+encodeURIComponent(p),'_blank','noopener');
}
/* Where the browser is, kept in the address bar — so reloading the tab, or a tab opened by ↗,
   comes back to the same folder or file. replaceState: walking a folder is not history. */
function fbSyncHash(){
  const p=document.getElementById('fb').classList.contains('show')?(fbFile||fbDir):'';
  const want=p?'#fb='+encodeURIComponent(p):(curId?'#t='+curId:'');
  if(location.hash!==want) history.replaceState(null,'',location.pathname+location.search+want);
}

/* ---------- markdown editor ----------
   Rendered by default; ✎ swaps in a plain textarea over the same text. Undo is ours, not the
   textarea's: a phone has no ⌘Z, and the field's own history dies the first time a script sets its
   value — which undo, redo and reload all do. A step is taken when typing pauses, so one undo takes
   back a burst of typing rather than a single character.
   Saving sends the version /read handed out (X-FV-Version). If the file changed on disk meanwhile —
   an agent writing the same plan — the server refuses, and the choice to overwrite is yours. */
const MDEXT=['md','markdown'];
let fbDoc=null, fbSnapT=0;
const FB_WHY={large:tr('fb.whyLarge'),encoding:tr('fb.whyEncoding'),readonly:tr('fb.whyReadonly')};
async function fbLoadMd(path,mode,scrollTo){
  const body=document.getElementById('fbbody');
  if(!fbDoc) body.innerHTML='<div class="fbnote">'+tr('common.loading')+'</div>';
  let r,text;
  try{ r=await fetch('/read?path='+encodeURIComponent(path),{cache:'no-store',timeout:60000}); text=await r.text(); }
  catch(e){ body.innerHTML='<div class="fbnote">'+tr('fb.readFailed')+'</div>'; return; }
  if(fbFile!==path) return;                      // walked away while it loaded
  if(!r.ok){ body.innerHTML='<div class="fbnote">'+esc(text)+'</div>'; return; }
  const ed=r.headers.get('X-FV-Editable')||'';
  // The textarea hands back \n whatever the file used; a CRLF file is written back as CRLF.
  const lf=text.replace(/\r\n/g,'\n');
  fbDoc={path,disk:lf,crlf:lf!==text,version:r.headers.get('X-FV-Version')||'',
         editable:ed==='1',why:ed==='1'?'':(FB_WHY[ed]||tr('fb.whyDefault')),mode:'view',hist:[lf],hi:0};
  fbRenderMd(fbDoc.editable&&mode==='edit'?'edit':'view');
  if(scrollTo) body.scrollTop=scrollTo;
}
const fbTA=()=>document.querySelector('#fbbody textarea.fbedit');
function fbCur(){ const ta=fbDoc&&fbDoc.mode==='edit'&&fbTA(); return ta?ta.value:fbDoc.hist[fbDoc.hi]; }
function fbDirty(){ return !!fbDoc&&fbCur()!==fbDoc.disk; }
function fbLeaveOk(){ return !fbDirty()||confirm(tr('fb.confirmLeave')); }
function fbRenderMd(mode){
  fbDoc.mode=mode;
  const body=document.getElementById('fbbody'), d=fbDoc;
  body.innerHTML='<div class="fbtools">'
    +'<button data-a="view"'+(mode==='view'?' class="on"':'')+'>'+tr('md.preview')+'</button>'
    +'<button data-a="edit"'+(mode==='edit'?' class="on"':'')+(d.editable?'':' disabled')+'>'+ic('pencil')+tr('md.edit')+'</button>'
    +'<button data-a="undo" title="'+tr('md.undoTitle')+'">'+ic('undo-2')+tr('md.undo')+'</button>'
    +'<button data-a="redo" title="'+tr('md.redoTitle')+'">'+ic('redo-2')+tr('md.redo')+'</button>'
    +'<span class="fbstate"></span>'
    +'<button data-a="save" class="save" title="'+tr('md.saveTitle')+'">'+tr('md.save')+'</button></div>'
    +(mode==='edit'?'<textarea class="fbedit" spellcheck="false" autocapitalize="off" autocomplete="off"></textarea>'
                   :'<div class="md fbmd">'+(md(d.hist[d.hi])||'<div class="fbnote">'+tr('md.emptyFile')+'</div>')+'</div>');
  const ta=fbTA();
  if(ta){ ta.value=d.hist[d.hi]; ta.addEventListener('input',()=>{ clearTimeout(fbSnapT); fbSnapT=setTimeout(fbSnap,500); fbSync(); }); }
  fbSync();
}
/* The text in the field as one undo step, if it differs from the last one. Capped, because each
   step is the whole document. */
function fbSnap(){
  clearTimeout(fbSnapT);
  const d=fbDoc, ta=fbTA(); if(!d||!ta) return;
  const v=ta.value; if(v===d.hist[d.hi]) return;
  d.hist=d.hist.slice(0,d.hi+1); d.hist.push(v);
  if(d.hist.length>100) d.hist.shift();
  d.hi=d.hist.length-1; fbSync();
}
function fbStep(by){
  const d=fbDoc; if(!d) return;
  if(d.mode==='edit') fbSnap();                 // typing not yet a step becomes one, then is undone
  const to=d.hi+by; if(to<0||to>=d.hist.length) return;
  const was=d.hist[d.hi]; d.hi=to;
  const ta=fbTA();
  if(ta){
    const v=d.hist[to]; ta.value=v;
    // Put the caret where the change was, which is where the eye already is.
    let i=0; while(i<v.length&&i<was.length&&v[i]===was[i]) i++;
    ta.focus(); ta.setSelectionRange(i,i);
  }else fbRenderMd('view');
  fbSync();
}
function fbSync(){
  const d=fbDoc, bar=document.querySelector('#fbbody .fbtools'); if(!d||!bar) return;
  const dirty=fbDirty(), ta=fbTA();
  const pending=ta&&ta.value!==d.hist[d.hi];
  bar.querySelector('[data-a=undo]').disabled=!(d.hi>0||pending);
  bar.querySelector('[data-a=redo]').disabled=pending||d.hi>=d.hist.length-1;
  bar.querySelector('[data-a=save]').disabled=!d.editable||!dirty;
  const st=bar.querySelector('.fbstate');
  st.textContent=!d.editable?d.why:tr(dirty?'md.unsaved':'md.saved');
  st.classList.toggle('dirty',dirty);
}
async function fbSave(force){
  const d=fbDoc; if(!d||!d.editable) return;
  if(d.mode==='edit') fbSnap();
  const text=fbCur();
  if(!force&&text===d.disk) return;
  let r,j={};
  try{
    r=await fetch('/save?path='+encodeURIComponent(d.path)+'&base='+encodeURIComponent(d.version)+(force?'&force=1':''),
                  {method:'POST',headers:{'Content-Type':'text/plain; charset=utf-8'},
                   body:d.crlf?text.replace(/\n/g,'\r\n'):text,timeout:0});
    j=await r.json().catch(()=>({}));
  }catch(e){ toast(tr('toast.saveNoMac')); return; }
  if(fbDoc!==d) return;
  if(r.status===409){
    if(confirm(tr('fb.confirmOverwrite')))
      return fbSave(true);
    return;
  }
  if(!r.ok){ toast(tr('toast.saveFailed',{err:j.error||('HTTP '+r.status)})); return; }
  d.version=j.version||''; d.disk=text; fbSync(); toast(tr('md.saved'));
}
document.getElementById('fbbody').addEventListener('click',e=>{
  const b=e.target.closest('.fbtools button'); if(!b||b.disabled||!fbDoc) return;
  const a=b.dataset.a;
  if(a==='view'&&fbDoc.mode!=='view'){ fbSnap(); fbRenderMd('view'); }
  else if(a==='edit'&&fbDoc.mode!=='edit'){ fbRenderMd('edit'); const ta=fbTA(); if(ta) ta.focus(); }
  else if(a==='undo') fbStep(-1);
  else if(a==='redo') fbStep(1);
  else if(a==='save') fbSave(false);
});
// On the document, not the overlay: in preview nothing inside #fb has focus, and ⌘S there is the
// browser's "save page" otherwise.
document.addEventListener('keydown',e=>{
  if(!fbDoc||!(e.metaKey||e.ctrlKey)||e.altKey||!document.getElementById('fb').classList.contains('show')) return;
  const k=e.key.toLowerCase();
  if(k==='s'){ e.preventDefault(); fbSave(false); }
  else if(fbDoc.mode==='edit'&&(k==='z'||k==='y')){ e.preventDefault(); fbStep(k==='y'||e.shiftKey?1:-1); }
});
window.addEventListener('beforeunload',e=>{ if(fbDirty()){ e.preventDefault(); e.returnValue=''; } });

// ---------- triggers ----------
/* What will make one terminal's agent act on its own (GET /triggers): the Mac's TriggersPanel,
   as a sheet. Re-read every few seconds while it is open, so a cancellation sent to the agent
   is seen to land. Times arrive as seconds from now and are turned into this device's clock. */
let trigId=null, trigItems=[], trigTimer=null, trigOpen=new Set();
function openTrig(id){
  trigId=id; trigItems=[]; trigOpen=new Set();
  const t=((state&&state.terminals)||[]).find(x=>x.id===id);
  document.getElementById('trigname').textContent=t?t.name:'';
  document.getElementById('triglist').innerHTML='<div class="tnote">'+tr('common.loading')+'</div>';
  document.getElementById('trig').classList.add('on');
  loadTrig();
  clearInterval(trigTimer); trigTimer=poll(loadTrig,5000,false);
}
function closeTrig(){
  trigId=null; clearInterval(trigTimer); trigTimer=null;
  document.getElementById('trig').classList.remove('on');
}
document.addEventListener('keydown',e=>{ if(e.key==='Escape'&&trigId){ e.preventDefault(); closeTrig(); } });
async function loadTrig(){
  const id=trigId; if(!id)return;
  let j=null;
  try{ const r=await fetch('/triggers?id='+encodeURIComponent(id),{cache:'no-store'}); j=await r.json(); }catch(e){}
  if(trigId!==id||!j)return;
  renderTrig(j);
}
function trigClock(d){
  const p=n=>String(n).padStart(2,'0'), now=new Date();
  const hm=p(d.getHours())+':'+p(d.getMinutes());
  return d.toDateString()===now.toDateString()?hm:(d.getMonth()+1)+'-'+d.getDate()+' '+hm;
}
function trigAt(sec){ return trigClock(new Date(Date.now()+sec*1000)); }
function trigAgo(sec){ return trigClock(new Date(Date.now()-sec*1000)); }
function trigSpan(s){
  s=Math.max(0,Math.round(s)); if(s<60)return s+'s';
  const m=Math.floor(s/60); if(m<60)return m+'m';
  const h=Math.floor(m/60); if(h<24)return m%60?h+'h'+(m%60)+'m':h+'h';
  return Math.floor(h/24)+'d';
}
function trigWords(it){
  const s=it.shape, p=n=>String(n).padStart(2,'0');
  if(s){
    if(s.k==='every')return tr('trig.every',{n:s.n});
    if(s.k==='hourly')return tr('trig.hourly',{m:s.m.map(x=>':'+p(x)).join(' ')});
    if(s.k==='daily')return tr('trig.daily',{t:p(s.h)+':'+p(s.m)});
    if(s.k==='weekdays')return tr('trig.weekdays',{t:p(s.h)+':'+p(s.m)});
    if(s.k==='once')return tr('trig.once',{t:s.mo+'-'+s.d+' '+p(s.h)+':'+p(s.m)});
  }
  if(it.schedule)return it.schedule;
  if(it.interval)return tr('trig.interval',{t:trigSpan(it.interval)});
  return it.type||it.id;
}
function trigRow(it,i){
  const icon=it.kind==='cron'?(it.wakeup?'rotate-cw':(it.recurring===false?'alarm-clock':'repeat'))
    :it.kind==='launchd'?'calendar-clock':(it.type==='monitor'?'activity':it.type==='subagent'?'users':'hourglass');
  const tags=it.kind==='cron'?[it.wakeup?tr('trig.wakeup'):tr(it.recurring===false?'trig.oneShot':'trig.recurring')]
    :(it.kind==='background'&&it.status?[it.status]:[]);
  const idl=it.kind==='cron'?[it.schedule,it.id].filter(Boolean).join('  ·  '):it.id;
  const meta=[];
  if(it.next>=0) meta.push(tr(it.lag>0?'trig.nextAbout':'trig.next',{t:trigAt(it.next)+' ('+trigSpan(it.next)+')'}));
  if(it.kind==='cron'){
    meta.push(it.fires>0&&it.lastFire>=0?tr('trig.fired',{n:it.fires,t:trigAgo(it.lastFire)}):tr('trig.neverFired'));
    if(it.created>=0) meta.push(tr('trig.created',{t:trigAgo(it.created)}));
    if(it.expires>=0) meta.push(tr('trig.expires',{t:trigAt(it.expires)}));
  }
  const code=it.kind!=='cron'&&it.command&&it.command!==it.text?it.command:'';
  const act=it.cancelling
    ?''
    :`<button class="tdel" onclick="delTrig(${i})" title="${tr(it.kind==='background'?'trig.stop':'trig.del')}">${ic(it.kind==='background'?'circle-stop':'trash','s16')}</button>`;
  return `<div class="trow${it.cancelling?' busy':''}"><span class="ti">${ic(icon,'s16')}</span><div class="tm">`+
    `<div class="tt"><b>${esc(trigWords(it))}</b>${tags.map(x=>`<span class="tg">${esc(x)}</span>`).join('')}</div>`+
    `<div class="tid">${esc(idl)}</div>`+
    (meta.length?`<div class="tmeta">${esc(meta.join(' · '))}</div>`:'')+
    (it.reason?`<div class="tmeta">${esc(tr('trig.reason',{t:it.reason}))}</div>`:'')+
    (it.text||code?`<div class="tbody${trigOpen.has(it.key)?' open':''}" onclick="trigToggle(${i},this)">${it.text?`<div class="ttext">${esc(it.text)}</div>`:''}${code?`<div class="tcode">${esc(code)}</div>`:''}</div>`:'')+
    (it.cancelling?`<div class="tbusy">${tr(it.kind==='launchd'?'trig.removing':'trig.cancelling')}</div>`:'')+
    `</div>${act}</div>`;
}
/* ---------- FleetView's own triggers ----------
   Not a card's (that is the sheet above): these the FleetView process runs, on a schedule, a file
   change or a condition, whatever happens to the cards — see FleetTriggerEngine. Each row says
   which card set it up, and "restore" brings that card back in its latest conversation. */
let ftrigItems=[], ftrigTimer=null, ftrigOpen=new Set(), ftrigConfirm=null;
function openFtrig(){
  ftrigConfirm=null;
  document.getElementById('ftriglist').innerHTML='<div class="tnote">'+tr('common.loading')+'</div>';
  document.getElementById('ftrig').classList.add('on');
  loadFtrig();
  clearInterval(ftrigTimer); ftrigTimer=poll(loadFtrig,5000,false);
}
function closeFtrig(){
  clearInterval(ftrigTimer); ftrigTimer=null; ftrigConfirm=null;
  document.getElementById('ftrig').classList.remove('on');
}
async function loadFtrig(){
  try{
    const r=await fetch('/fleet-triggers',{cache:'no-store'});
    const j=await r.json(); ftrigItems=j.triggers||[]; renderFtrig();
  }catch(e){}
}
function ftrigDur(s){
  s=Math.round(s||0);
  for(const [n,u] of [[86400,'d'],[3600,'h'],[60,'m']]) if(s>=n&&s%n===0) return (s/n)+u;
  return s+'s';
}
function ftrigTime(iso){ const d=new Date(iso); return isNaN(d)?'':trigClock(d); }
function ftrigWhen(t){
  const w=t.when||{};
  switch(w.kind){
    case 'cron': return tr('ftrig.cron',{c:w.cron||''});
    case 'every': return tr('ftrig.every',{d:ftrigDur(w.every)});
    case 'at': return tr('ftrig.at',{t:ftrigTime(w.at)});
    case 'watch': return tr('ftrig.watch',{p:w.path||''});
    case 'check': return tr('ftrig.check',{c:w.check||''});
    default: return tr('ftrig.manual');
  }
}
function ftrigRow(t,i){
  const kind=(t.when||{}).kind;
  const icon={cron:'calendar-clock',at:'alarm-clock',every:'repeat',watch:'file',check:'activity'}[kind]||'zap';
  const meta=[ftrigWhen(t)];
  if(t.paused) meta.push(tr('ftrig.paused'));
  else if(t.due) meta.push(tr('trig.next',{t:ftrigTime(t.due)}));
  else if(kind==='at'&&t.last) meta.push(tr('ftrig.done'));
  let st='';
  if(t.running) st=`<span class="tg run">${esc(tr('ftrig.running'))}</span>`;
  else if(t.last){
    const ok=t.last.exit===0&&!t.last.note;
    const words=t.last.exit==null?(t.last.note||'?'):tr(ok?'ftrig.ok':'ftrig.exit',{t:ftrigTime(t.last.at),n:t.last.exit});
    st=`<span class="tg${ok?'':' bad'}" title="${esc(t.last.note||'')}">${esc(words)}</span>`;
  }
  const card=t.sourceCard||{};
  const fate=card.state==='removed'?' ('+tr('ftrig.removed')+')':card.state==='gone'?' ('+tr('ftrig.gone')+')':'';
  const src=t.source
    ?`<div class="fsrc">${esc(tr('ftrig.source'))} · <b>${esc(card.name||t.sourceName||'')}</b>${esc(fate)}<br><code>${esc(t.source.toLowerCase())}</code></div>`
    :`<div class="fsrc">${esc(tr('ftrig.noSource'))}</div>`;
  const open=ftrigOpen.has(t.id);
  const tail=open&&t.last&&t.last.tail?`<div class="ttext">${esc(t.last.tail)}</div>`:'';
  const acts=`<div class="facts">`+
    (t.source?`<button onclick="ftrigRestore(${i})">${esc(tr('ftrig.restore'))}</button>`:'')+
    `<button ${t.running?'disabled':''} onclick="ftrigAct('fire',${i})">${esc(tr('ftrig.fire'))}</button>`+
    `<button onclick="ftrigAct('pause',${i},'&on=${t.paused?0:1}')">${esc(tr(t.paused?'ftrig.resume':'ftrig.pause'))}</button>`+
    (ftrigConfirm===t.id
      ?`<button class="danger" onclick="ftrigAct('rm',${i})">${esc(tr('ftrig.confirmRm'))}</button>`
      :`<button onclick="ftrigConfirm=ftrigItems[${i}].id;renderFtrig()">${esc(tr('ftrig.rm'))}</button>`)+
    `</div>`;
  return `<div class="trow${t.paused?' busy':''}"><span class="ti">${ic(icon,'s16')}</span><div class="tm">`+
    `<div class="tt"><b>${esc(t.name)}</b><span class="tg">${esc(t.id)}</span>${st}</div>`+
    `<div class="tmeta">${esc(meta.join(' · '))}</div>`+
    `<div class="tbody${open?' open':''}" onclick="ftrigToggle(${i},this)"><div class="tcode">$ ${esc(t.run)}</div>${tail}</div>`+
    src+acts+`</div></div>`;
}
function renderFtrig(){
  const el=document.getElementById('ftriglist');
  el.innerHTML=ftrigItems.length?ftrigItems.map(ftrigRow).join(''):`<div class="tnote">${esc(tr('ftrig.empty'))}</div>`;
}
function ftrigToggle(i){
  const t=ftrigItems[i]; if(!t) return;
  if(ftrigOpen.has(t.id)) ftrigOpen.delete(t.id); else ftrigOpen.add(t.id);
  renderFtrig();
}
async function ftrigAct(act,i,extra){
  const t=ftrigItems[i]; if(!t) return;
  ftrigConfirm=null;
  try{
    const r=await fetch('/fleet-triggers/'+act+'?id='+encodeURIComponent(t.id)+(extra||''),{method:'POST'});
    const j=await r.json().catch(()=>({}));
    if(!r.ok) toast(j.error||('HTTP '+r.status),3000);
  }catch(e){ toast(e.message||String(e),3000); }
  loadFtrig();
}
/* Restoring lands you in the card: that is what you came back for. */
async function ftrigRestore(i){
  const t=ftrigItems[i]; if(!t) return;
  try{
    const r=await fetch('/fleet-triggers/restore?id='+encodeURIComponent(t.id),{method:'POST',timeout:30000});
    const j=await r.json().catch(()=>({}));
    if(!r.ok||!j.id){ toast(j.error||('HTTP '+r.status),3000); return; }
    closeFtrig(); await refreshState(); openTerm(j.id,j.name||'');
  }catch(e){ toast(e.message||String(e),3000); }
}
function renderTrig(j){
  document.getElementById('trigname').textContent=j.name||'';
  trigItems=j.items||[];
  const note=j.agent==='codex'?tr('trig.codexNote')
    :!j.agentRunning?(j.agent==='claude'?tr('trig.notRunning'):'')
    :j.reported<0?tr('trig.neverReported'):tr('trig.reportedAt',{t:trigAgo(j.reported)});
  let out=note?`<div class="tnote">${esc(note)}</div>`:'';
  if(!trigItems.length){
    out+=`<div class="tempty"><b>${tr('trig.none')}</b>${tr('trig.noneDetail')}</div>`;
  }else{
    for(const [kind,key] of [['cron','trig.secCron'],['background','trig.secBg'],['launchd','trig.secLaunchd']]){
      const rows=trigItems.map((it,i)=>[it,i]).filter(([it])=>it.kind===kind);
      if(!rows.length)continue;
      out+=`<div class="tsec">${tr(key)}<span>${rows.length}</span></div>`+rows.map(([it,i])=>trigRow(it,i)).join('');
    }
  }
  document.getElementById('triglist').innerHTML=out;
}
/* A prompt opened to be read stays open across the refresh, so it is remembered by key. */
function trigToggle(i,el){
  const it=trigItems[i]; if(!it)return;
  if(trigOpen.has(it.key)) trigOpen.delete(it.key); else trigOpen.add(it.key);
  el.classList.toggle('open',trigOpen.has(it.key));
}
async function delTrig(i){
  const it=trigItems[i], id=trigId; if(!it||!id)return;
  if(!confirm(tr(it.kind==='launchd'?'trig.confirmLaunchd':'trig.confirmAgent')))return;
  try{
    const r=await fetch('/trigger/cancel?id='+encodeURIComponent(id)+'&key='+encodeURIComponent(it.key)+(it.wakeup?'&wakeup=1':''),{cache:'no-store'});
    const j=await r.json();
    toast(j.error?j.error:tr(it.kind==='launchd'?'trig.removed':'trig.sent'),2400);
  }catch(e){ toast(tr('trig.failed'),2400); }
  loadTrig();
}

// ---------- create / actions ----------
async function newTerm(pid){try{await fetch('/new?projectId='+encodeURIComponent(pid));setTimeout(tick,300);}catch(e){}}
async function doAction(id,act,extra,params){
  let u='/action?id='+encodeURIComponent(id)+'&do='+act;
  if(extra)u+='&name='+encodeURIComponent(extra);
  for(const k in (params||{})) u+='&'+k+'='+encodeURIComponent(params[k]);
  try{await fetch(u);setTimeout(tick,200);}catch(e){}
}

// ---------- drag-to-act ----------
let drag={id:null,name:null,cluster:false,x:0,y:0,sx:0,sy:0,active:false,
          touch:false,armed:false,holdTimer:0,live:false};
/* How long a finger has to rest on a card before it picks the card up. It was 220ms, which is
   shorter than a finger rests before most scrolls begin — so reading down the board kept lifting
   cards. 450 is the platform long-press, the delay people already expect a hold to take. */
const HOLD_MS=450;
function endDrag(){
  clearTimeout(drag.holdTimer);
  markDrop(null); drag.drop=null; drag.hotAct=null; drag.sayKey=null;
  if(scrollRaf){ cancelAnimationFrame(scrollRaf); scrollRaf=0; }
  window.removeEventListener('pointermove',onMove);
  window.removeEventListener('pointerup',onUp);
  window.removeEventListener('pointercancel',endDrag);
  if(drag.card)drag.card.classList.remove('armed');
  if(drag.card)drag.card.classList.remove('dragging');
  drag.active=false;drag.armed=false;drag.live=false;dragging=false;
  document.getElementById('chip').style.display='none';
  document.getElementById('dock').style.display='none';
}
function zonesFor(cluster,done,win){
  // The same words the Mac's dock and card menu use, so one action has one name on both.
  const z=[{k:'done',t:tr(done?'dock.unmark':'dock.mark'),i:done?'bookmark-x':'bookmark'},
           {k:'duplicate',t:tr('dock.duplicate'),i:'copy-plus'},{k:'rename',t:tr('dock.rename'),i:'pencil'}];
  /* The Mac's window for this terminal, not anything on this page: hiding keeps the agent running
     with nothing drawing it on the desktop; showing puts the window back there. */
  if(win==='open')z.push({k:'hide',t:tr('dock.hide'),i:'eye-off'});
  if(win==='hidden')z.push({k:'show',t:tr('dock.show'),i:'eye'});
  if(cluster)z.push({k:'leaveCluster',t:tr('dock.leave'),i:'log-out'});
  z.push({k:'remove',t:tr('dock.remove'),i:'trash',danger:true});
  return z;
}
function buildDock(cluster,done,win){
  const dock=document.getElementById('dock');
  dock.innerHTML=zonesFor(cluster,done,win).map(z=>`<div class="zone${z.danger?' danger':''}" data-zone="${z.k}" data-label="${z.t}">${ic(z.i)}<span>${z.t}</span></div>`).join('');
}
function zoneAt(x,y){
  for(const el of document.querySelectorAll('#dock .zone')){
    const r=el.getBoundingClientRect();
    if(x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom)return el;
  }return null;
}
/* ---------- dropping on the board, as on the Mac ----------
   Away from the dock a card can land on another card (the two become a group), inside a group (it
   joins), in another project — its section, or any card or group of it — (it moves there, history
   and all), or on empty board when it is in a group (it leaves). The same rules, in the same order,
   as the Mac's `clusterTarget`; the page says what it was over and the Mac decides again on the
   drop (`do=drop`), so a board drawn a poll ago cannot do something the Mac would not. */
const byId=(list,id)=>(list||[]).find(x=>x.id===id);
function clusterEl(cid){ return document.querySelector('.cluster[data-cid="'+cid+'"]'); }
function sectionEl(pid){ return document.querySelector('section.proj[data-pid="'+pid+'"]'); }
function boardDrop(x,y){
  /* The dock's whole footprint, gaps and padding included: a card lying under the panel must not
     light up through a gap between two zones. */
  const dk=document.getElementById('dock').getBoundingClientRect();
  if(x>=dk.left-14&&x<=dk.right+14&&y>=dk.top-14&&y<=dk.bottom+14) return null;
  const src=state&&byId(state.terminals,drag.id); if(!src) return null;
  const el=document.elementFromPoint(x,y);
  if(!el||!el.closest('#root')||el.closest('header')) return null;
  // A group box wins over the cards in it: the task is what is being aimed at.
  const cl=el.closest('.cluster');
  if(cl){
    if(cl.dataset.cid===src.clusterId) return null;          // already in it
    return cl.dataset.pid===src.projectId?{k:'cluster',id:cl.dataset.cid,el:cl}
                                         :{k:'project',id:cl.dataset.pid,el:sectionEl(cl.dataset.pid)||cl};
  }
  const cd=el.closest('.card');
  if(cd&&cd.dataset.id!==drag.id){
    // A card in 进行中 stands outside its project's section; a foreign one names its project.
    if(cd.dataset.pid!==src.projectId) return {k:'project',id:cd.dataset.pid,el:sectionEl(cd.dataset.pid)||cd};
    if(cd.dataset.cid) return cd.dataset.cid===src.clusterId?null:{k:'cluster',id:cd.dataset.cid,el:clusterEl(cd.dataset.cid)||cd};
    return {k:'card',id:cd.dataset.id,el:cd};
  }
  const sec=el.closest('section.proj');
  if(sec&&sec.dataset.pid!==src.projectId) return {k:'project',id:sec.dataset.pid,el:sec};
  if(src.clusterId) return {k:'leave',id:src.clusterId,el:clusterEl(src.clusterId)};
  return null;
}
let dropEl=null, leaveEl=null;
function markDrop(d){
  const want=d&&d.k!=='leave'?d.el:null, leave=d&&d.k==='leave'?d.el:null;
  if(dropEl!==want){ if(dropEl)dropEl.classList.remove('droptarget'); if(want)want.classList.add('droptarget'); dropEl=want; }
  if(leaveEl!==leave){ if(leaveEl)leaveEl.classList.remove('leaving'); if(leave)leave.classList.add('leaving'); leaveEl=leave; }
}
/* What letting go would do, in the words of the thing it lands on — and for a move, the second line
   the Mac gives it: a move restarts the agent, which is more than the gesture looks like. */
function dropSay(d){
  const s=state, src=byId(s.terminals,drag.id)||{};
  const group=id=>{const c=byId(s.clusters,id);return c&&c.name?c.name:tr('drop.group');};
  if(d.k==='card'){const t=byId(s.terminals,d.id);return [tr('drop.groupWith',{name:t?t.name:''}),''];}
  if(d.k==='cluster') return [tr('drop.join',{name:group(d.id)}),''];
  if(d.k==='leave') return [tr('drop.leave',{name:group(d.id)}),''];
  const p=byId(s.projects,d.id);
  const note=src.status==='working'?tr('drop.noteWorking'):src.agent==='codex'?tr('drop.noteCodex')
            :!src.transcript?tr('drop.noteNoHistory'):tr('drop.noteMove');
  return [tr('drop.moveTo',{name:p?p.name:''}),note];
}
/* Near the top or just above the dock the board scrolls under a held card, so another project can
   be reached on a phone — the touch that is dragging cannot also scroll. */
let scrollRaf=0;
function autoScroll(){
  scrollRaf=0;
  if(!drag.active) return;
  const head=document.querySelector('header'), top=head?Math.max(0,head.getBoundingClientRect().bottom):0;
  const dockTop=document.getElementById('dock').getBoundingClientRect().top, EDGE=64;
  let v=0;
  if(drag.y<top+EDGE) v=-Math.ceil((top+EDGE-drag.y)/5);
  else if(drag.y>dockTop-EDGE&&drag.y<dockTop) v=Math.ceil((drag.y-(dockTop-EDGE))/5);
  if(!v) return;
  const before=window.scrollY; window.scrollBy(0,v);
  if(window.scrollY===before) return;                      // at the end: nothing more to reveal
  aim(drag.x,drag.y);
  scrollRaf=requestAnimationFrame(autoScroll);
}
/* Work out the target under (x,y) and say so: the zone or the ring, the chip, and a tick on a phone
   that can give one each time the target changes. */
function aim(x,y){
  const chip=document.getElementById('chip');
  document.querySelectorAll('#dock .zone').forEach(z=>z.classList.remove('hot'));
  const hot=zoneAt(x,y);
  drag.hotAct=hot?hot.dataset.zone:null;   // remember target NOW; the dock is hidden before onUp reads it
  if(hot)hot.classList.add('hot');
  drag.drop=hot?null:boardDrop(x,y);
  markDrop(drag.drop);
  const [say,note]=hot?[tr('drag.drop',{action:hot.dataset.label}),'']:drag.drop?dropSay(drag.drop):[drag.name,''];
  const key=say+'|'+note;
  if(drag.sayKey!==key){
    chip.textContent=say;
    if(note){ const n=document.createElement('span'); n.className='note'; n.textContent=note; chip.appendChild(n); }
    if(drag.sayKey&&(hot||drag.drop)&&navigator.vibrate) navigator.vibrate(6);
    drag.sayKey=key;
  }
}
function onDown(e){
  // The id chip is neither a drag handle nor a way in: a tap on it copies the id and nothing
  // else. It has to be refused here rather than in its own click handler — the card is driven from
  // pointerdown, so by the time a click fires the tap has already been taken as "open this
  // terminal", and stopPropagation on the click is too late to call it back.
  if(e.target.closest('.uid'))return;
  if(e.target.closest('.trig'))return;           // the same for the trigger chip: it opens its list
  const card=e.target.closest('.card');if(!card)return;
  drag.id=card.dataset.id;drag.name=card.dataset.name;drag.cluster=card.dataset.cluster==='1';
  drag.done=card.dataset.done==='1';drag.canopen=card.dataset.canopen==='1';drag.win=card.dataset.win;drag.card=card;
  drag.sx=e.clientX;drag.sy=e.clientY;drag.active=false;drag.live=true;drag.y0=window.scrollY;
  // A finger can't both scroll the list and drag a card, so touch has to say which it means:
  // hold still for a moment and the card arms for dragging, otherwise the swipe stays a scroll.
  drag.touch=e.pointerType==='touch';
  drag.armed=!drag.touch;
  clearTimeout(drag.holdTimer);
  if(drag.touch){
    drag.holdTimer=setTimeout(()=>{
      // The page moved under a finger that "held still": that was a scroll, not a hold.
      if(!drag.live||Math.abs(window.scrollY-drag.y0)>3){ endDrag(); return; }
      drag.armed=true;
      if(drag.card)drag.card.classList.add('armed');
      if(navigator.vibrate)navigator.vibrate(8);
    },HOLD_MS);
  }
  window.addEventListener('pointermove',onMove);
  window.addEventListener('pointerup',onUp);
  /* The missing half of the old version. When the browser takes a touch for scrolling it sends
     pointercancel — and then no more pointermoves and no pointerup. Nothing listened for it, so the
     hold timer ran on and armed the card mid-scroll, and the pointerup listener stayed behind to
     fire on the NEXT tap anywhere, which opened the card the scroll had started on. */
  window.addEventListener('pointercancel',endDrag);
}
function onMove(e){
  const dx=e.clientX-drag.sx,dy=e.clientY-drag.sy;
  // Moved before the hold completed → the user is scrolling; let the browser have the gesture.
  if(!drag.armed){
    if(Math.hypot(dx,dy)>8){ clearTimeout(drag.holdTimer); endDrag(); }
    return;
  }
  if(!drag.active&&Math.hypot(dx,dy)<9)return;
  if(!drag.active){
    drag.active=true;dragging=true;drag.card.classList.add('dragging');
    buildDock(drag.cluster,drag.done,drag.win);
    document.getElementById('dock').style.display='flex';
    const chip=document.getElementById('chip');chip.textContent=drag.name;chip.style.display='block';
  }
  const chip=document.getElementById('chip');chip.style.left=e.clientX+'px';chip.style.top=e.clientY+'px';
  drag.x=e.clientX; drag.y=e.clientY;
  // The label by the finger says what letting go will do, not just what is being carried.
  aim(e.clientX,e.clientY);
  if(!scrollRaf) scrollRaf=requestAnimationFrame(autoScroll);
}
function onUp(e){
  clearTimeout(drag.holdTimer);
  window.removeEventListener('pointermove',onMove);
  window.removeEventListener('pointerup',onUp);
  window.removeEventListener('pointercancel',endDrag);
  if(drag.card)drag.card.classList.remove('armed');
  const heldStill=drag.touch&&drag.armed&&!drag.active;
  drag.live=false;
  const wasActive=drag.active;
  const act=wasActive?drag.hotAct:null;   // captured during onMove, while zones still had layout
  const drop=wasActive&&!act?drag.drop:null;
  markDrop(null); drag.drop=null; drag.sayKey=null; drag.active=false;
  if(scrollRaf){ cancelAnimationFrame(scrollRaf); scrollRaf=0; }
  document.getElementById('chip').style.display='none';
  document.getElementById('dock').style.display='none';
  if(drag.card)drag.card.classList.remove('dragging');
  dragging=false;
  // Picked up and put back down where it was: the hold was the start of a drag that did not
  // happen, not a slow tap. Opening the terminal there surprised people who had only paused.
  if(heldStill) return;
  if(!wasActive){ // a tap, not a drag
    if(drag.canopen)openTerm(drag.id,drag.name);else toast(tr('toast.openOnMac'));
    return;
  }
  if(drop){
    if(drop.k==='leave') doAction(drag.id,'leaveCluster');
    else doAction(drag.id,'drop',null,{[drop.k]:drop.id});
    return;
  }
  if(!act)return;
  if(act==='rename'){const n=prompt(tr('prompt.rename'),drag.name);if(n)doAction(drag.id,'rename',n);}
  else doAction(drag.id,act);
}
document.getElementById('root').addEventListener('pointerdown',onDown);
/* Non-passive: touch-action is evaluated when the gesture begins, so the only way to stop a scroll
   that a long press has turned into a drag is to cancel the touch moves themselves. Two jobs, both
   needing touch events because pointer events stop once the browser scrolls:
   - once a card is armed the gesture is the drag's, from the first move — waiting for `active` let
     that first move start a scroll, which cancelled the drag before it began;
   - before it is armed, a finger that travels is scrolling, so the hold is off. */
document.addEventListener('touchmove',e=>{
  if(!drag.live||!drag.touch) return;
  if(drag.armed){ e.preventDefault(); return; }
  const p=e.touches[0];
  if(p&&Math.hypot(p.clientX-drag.sx,p.clientY-drag.sy)>8) endDrag();
},{passive:false});
window.addEventListener('scroll',()=>{ if(drag.live&&!drag.armed) endDrag(); },{passive:true});

let toastT=null;
function toast(msg,ms){
  let t=document.getElementById('toast');
  if(!t){t=document.createElement('div');t.id='toast';
    /* pointer-events:none, because it is only ever faded out and never removed: an invisible node
       parked 70px off the bottom at z-index 70 otherwise goes on swallowing every tap that lands on
       it — which is precisely where the composer's key row sits. */
    // Material's snackbar: inverse surface, so it reads as on top of whatever is under it.
    t.style.cssText='position:fixed;left:50%;bottom:70px;transform:translateX(-50%);z-index:70;pointer-events:none;background:var(--inverseSurface);color:var(--inverseOnSurface);padding:10px 16px;border-radius:8px;font-size:14px;line-height:20px;max-width:min(560px,calc(100vw - 32px));box-shadow:0 6px 20px rgba(0,0,0,.35)';
    document.body.appendChild(t);}
  t.textContent=msg;t.style.opacity='1';
  clearTimeout(toastT);toastT=setTimeout(()=>{t.style.opacity='0';},ms||1600);
}

// ---------- render ----------
/* One card, the Mac's three rows: the status shape, the name and the clock (or how long ago); the
   last prompt, always two lines tall so every card in a grid is the same height; the agent's mark
   and its tokens. No status word and no agent chip — the shape and the mark say both, and the word
   is the shape's title. The fill is the state, wherever the card is drawn; whether it is in its first
   ten seconds is left out of the markup on purpose (see paintFresh). */
/* The same split as the Mac's NameText (TerminalNames.split): cut at the end, two cards called
   "review (2)" and "review (3)" would read the same. */
function nameHTML(name){
  const m=name.match(/^(.+?)( \(\d+\)| · \d\d-\d\d \d\d:\d\d(?::\d\d)?(?: #\d+)?)$/);
  if(!m) return `<span class="nm ts">${esc(name)}</span>`;
  return `<span class="nm ts split"><span class="nb">${esc(m[1])}</span><span class="ns">${esc(m[2])}</span></span>`;
}
function card(t){
  const ended=t.status==='exited'||t.status==='closed';
  const cls='card'+(t.status==='working'?' tint run':t.status==='needsYou'?' tint need':t.status==='idle'?' idle':'')
    +(ended?' ghost':'')+(t.canOpen?'':' locked');
  const time=t.running>=0
    ? `<span class="when clock lm" data-run="${t.id}"></span>`
    : (t.idle>=0?`<span class="when lm" title="${t.lastRun>=0?tr('card.lastRun',{time:clockText(t.lastRun*1000)}):tr('card.lastActivity')}">${rel(t.idle)}</span>`:'');
  const extra=(t.done?`<span class="mk" title="${tr('card.marked')}">${ic('bookmark','s14')}</span>`:'')+
    (t.window==='hidden'?`<span class="hid" title="${tr('card.hidden')}">${ic('eye-off','s14')}</span>`:'');
  const tok=t.tokens>0?`<span class="ls" title="${tr('common.tokens',{n:t.tokens})}">${short(t.tokens)}</span>`:'';
  const trig=t.trig>0?`<span class="trig" role="button" title="${tr('trig.chip',{n:t.trig})}" onclick="event.stopPropagation();openTrig('${t.id}')">${ic(t.trigTimed>0?'alarm-clock':'hourglass','s12')}${t.trig}</span>`:'';
  const uid=t.id.toLowerCase();
  return `<div class="${cls}" data-id="${t.id}" data-pid="${t.projectId}" data-cid="${t.clusterId||''}" data-name="${esc(t.name)}" data-cluster="${t.clusterId?'1':'0'}" data-canopen="${t.canOpen?'1':'0'}" data-done="${t.done?'1':'0'}" data-win="${t.window||'none'}">
    <div class="hd">${cardGlyph(t.status)}${nameHTML(t.name)}${extra}${time}</div>
    <div class="pr bs"><span class="sig">${t.status==='shell'?'$':'›'}</span><span class="tx">${t.prompt?esc(t.prompt):'—'}</span></div>
    <div class="ft"><span class="uid" role="button" data-short="${uid.slice(0,4)}…" onclick="event.stopPropagation();uidTap(this,'${t.id}')"
      title="${tr('card.idTitle',{id:uid.slice(0,8)})}">${uid.slice(0,4)}…</span>${agentMark(t.agent)}${tok}${trig}</div>
  </div>`;
}
/* The id chip, as on the Mac card: a click copies the terminal's id (what `project-manager` takes),
   a second click straight after copies its conversation file's path instead.
   The double is counted here rather than left to `dblclick`, which iOS Safari never sends. And the
   first click copies at once rather than waiting to see whether a second follows: over plain http
   the copy only works inside the tap that asked for it, and a timer would carry it out of that tap.
   So a double-click copies the id and then overwrites it with the path, which ends in the same
   clipboard. What happened is said on the chip itself for a second, where the eye already is. */
let uidLast={id:'',at:0};
async function uidTap(el,id){
  const now=performance.now(), second=uidLast.id===id&&now-uidLast.at<400;
  uidLast=second?{id:'',at:0}:{id:id,at:now};
  if(!second){ if(await copyText(id.toLowerCase(),true)) uidFlash(el,tr('card.idCopied')); return; }
  const term=((state&&state.terminals)||[]).find(x=>x.id===id);
  if(!term||!term.transcript){ uidFlash(el,''); toast(tr('toast.noTranscript')); return; }
  if(await copyText(term.transcript,true)) uidFlash(el,tr('card.idPath'));
}
/* '' puts the id straight back. The board rebuilds only when its markup changes, so the chip being
   rewritten under it does not trigger a rebuild — and if one happens anyway, the new chip is simply
   the id again. */
function uidFlash(el,text){
  clearTimeout(el._flash);
  el.textContent=text||el.dataset.short;
  if(text) el._flash=setTimeout(()=>{ el.textContent=el.dataset.short; },1000);
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
/* The same for the end of a run: `finished` is seconds since the last run came back to the prompt,
   and it is what decides how long a card wears the "just finished" look. */
const endStart={};
function anchorAt(map,id,sec,now){
  const st=now-sec*1000;
  // Re-anchor only on a real disagreement: each poll's value is a fraction of a second staler than
  // the last, and following that exactly makes the seconds digit stutter. An earlier reading is the
  // exception — the Mac truncates to whole seconds, so the earliest anchor is the closest to the
  // truth, and moving only that way cannot oscillate. It is what lets the ten-second line land on
  // time rather than up to a second late.
  if(!map[id]||Math.abs(map[id]-st)>2000) map[id]=st;
  else if(st<map[id]) map[id]=st;
}
/* Before the board is built, not after: the order of 进行中 is read from these anchors. */
function syncRuns(terms){
  const now=Date.now(), run={}, end={};
  for(const t of terms){
    if(t.running>=0){ run[t.id]=1; anchorAt(runStart,t.id,t.running,now); }
    // An older Mac sends no `finished`; nothing is ever fresh-finished then, which is the old board.
    if(t.status==='idle'&&t.finished>=0){ end[t.id]=1; anchorAt(endStart,t.id,t.finished,now); }
  }
  for(const id in runStart){ if(!run[id]) delete runStart[id]; }
  for(const id in endStart){ if(!end[id]) delete endStart[id]; }
}
/* `[data-run]` only, and the card's own class: `.run` also names a pending tool card in the
   conversation, and a blind sweep would write a clock into that. The figure is bare, "2:12", as on
   the Mac — the shape beside it already says it is running. */
function paintRuns(){
  for(const el of document.querySelectorAll('.clock[data-run]')){
    const st=runStart[el.dataset.run];
    const v=st?clockText(Date.now()-st):'';
    if(el.textContent!==v) el.textContent=v;
  }
}
setInterval(paintRuns,1000);
/* ---------- the first ten seconds, and the motion of a change ----------
   A card's look is its status plus, for running and finished, whether that began under ten seconds
   ago. The status is in the markup; the ten seconds are not. In the markup they would change it on a
   poll where nothing happened and rebuild the board for it, and a rebuilt card cannot ease from one
   colour to the next — there is no old colour left to ease from. So the line is crossed in place, by
   a class, on one timer aimed at the next card due to cross, and no timer at all when nothing is
   fresh. Ages are the Mac's seconds plus this device's time since they arrived (runStart, endStart),
   so a card turns between polls, on time, and the phone's clock is never read against the Mac's. */
const FRESH_MS=10000;
function lookOf(id,status,now){
  if(status==='working') return runStart[id]&&now-runStart[id]<FRESH_MS?'runFresh':'run';
  if(status==='needsYou') return 'need';
  if(status==='idle') return endStart[id]&&now-endStart[id]<FRESH_MS?'done':'idle';
  return status==='exited'||status==='closed'?'ended':'plain';
}
let freshT=0, easeT=0;
/* `rebuilt`: the cards were made this frame, so there is no old colour to ease from — they simply
   start in the right one. */
function paintFresh(rebuilt){
  clearTimeout(freshT);
  const now=Date.now();
  let next=Infinity, eased=false;
  for(const el of document.querySelectorAll('#root .card.run,#root .card.idle')){
    const idle=el.classList.contains('idle'), st=(idle?endStart:runStart)[el.dataset.id];
    const left=st?FRESH_MS-(now-st):0, on=left>0;
    if(on) next=Math.min(next,left);
    if(el.classList.contains('fresh')===on) continue;
    if(!rebuilt){ el.classList.add('ease'); eased=true; }
    el.classList.toggle('fresh',on);
    // The shape changes between the check and the dot, so its word has to follow it.
    if(idle){
      const g=el.querySelector('.hd > .g'), w=on?DONE_TEXT:STATUS_TEXT.idle, ti=g&&g.querySelector('title');
      if(g) g.setAttribute('aria-label',w);
      if(ti) ti.textContent=w;
    }
  }
  if(eased){
    clearTimeout(easeT);
    easeT=setTimeout(()=>{ for(const el of document.querySelectorAll('#root .card.ease')) el.classList.remove('ease'); },1300);
  }
  // A few ms past the line, so the card is on the far side of it when this runs. The clock is
  // repainted with it, so the colour turns as the card reads 0:10 rather than up to a second apart.
  if(next<Infinity) freshT=setTimeout(()=>{ paintRuns(); paintFresh(false); },next+20);
}
/* What moves when 进行中 changes, done the FLIP way: measure the keyed boxes, rebuild, measure again,
   and start each box where it was. Keys are `data-flip`: zh for the zone's heading, n:<id> for a
   card in it, p:<pid> and dorm for the sections below. Only the zone's own boxes enter and leave; a
   section only ever slides — which is all "the board does not jump when the zone comes or goes"
   takes, and a whole project scaling in would be a lot of motion for a row that merely moved. */
const REDUCE=matchMedia('(prefers-reduced-motion: reduce)');
const SPRING='cubic-bezier(.2,.9,.3,1.12)', STANDARD='cubic-bezier(.2,0,0,1)', EXIT='cubic-bezier(.3,0,1,1)';
const inZone=k=>k==='zh'||k.startsWith('n:');
function boardRects(root){
  const m=new Map();
  for(const el of root.querySelectorAll('[data-flip]')){
    const r=el.getBoundingClientRect();
    m.set(el.dataset.flip,{x:r.left,y:r.top,w:r.width,el:el});
  }
  return m;
}
function flipBoard(before,root){
  const after=boardRects(root), still=REDUCE.matches;
  let leaving=false;
  for(const k of before.keys()) if(inZone(k)&&!after.has(k)) leaving=true;
  for(const [k,a] of after){
    const b=before.get(k);
    if(b){
      const dx=b.x-a.x, dy=b.y-a.y;
      // Held back while anything is leaving, so the gap is visibly emptied before it closes.
      // Reduced motion: no translation at all — a box that moved is simply where it now is.
      if(!still&&(Math.abs(dx)>.5||Math.abs(dy)>.5))
        a.el.animate([{transform:'translate('+dx+'px,'+dy+'px)'},{transform:'none'}],
          {duration:400,easing:STANDARD,delay:leaving?160:0,fill:'backwards'});
    }else if(inZone(k)){
      a.el.animate(still?[{opacity:0},{opacity:1}]:[{opacity:0,transform:'scale(.92)'},{opacity:1,transform:'none'}],
        {duration:400,easing:still?'ease':SPRING,delay:k==='zh'?200:80,fill:'backwards'});
    }
  }
  if(still) return;                         // leaving cards just vanish
  // Read after the rebuild: the boxes above were measured against the viewport, so the copies go
  // where they were on screen, whatever the scroll did while the board was replaced.
  const layer=document.getElementById('ghosts'), sx=window.scrollX, sy=window.scrollY;
  for(const [k,b] of before){
    if(!inZone(k)||after.has(k)) continue;
    const g=b.el.cloneNode(true);
    // A picture of a card, not a card: unlockBoard takes the last .card[data-id] it finds, and
    // paintRuns writes into every clock.
    for(const e of [g,...g.querySelectorAll('[data-id],[data-run],[data-flip]')]){
      e.removeAttribute('data-id'); e.removeAttribute('data-run'); e.removeAttribute('data-flip');
    }
    g.style.left=(b.x+sx)+'px'; g.style.top=(b.y+sy)+'px'; g.style.width=b.w+'px';
    layer.appendChild(g);
    g.animate([{opacity:1,transform:'none'},{opacity:0,transform:'scale(.92)'}],
      {duration:200,easing:EXIT,fill:'forwards'}).onfinish=()=>g.remove();
  }
}
/* A status change, once, on every copy of the card: a ring in the new status's colour, the shape
   popping in, and the fill crossfading from the old look. The crossfade only where that copy was
   already on screen — one arriving in 进行中 has its entrance instead. Colours are read off the
   stylesheet at the moment, so they are the current appearance's. */
const LOOK_FILL={runFresh:'--runFresh',run:'--runSettled',need:'--warnContainer',done:'--tertiaryContainer',idle:'--card',plain:'--card'};
const LOOK_RING={runFresh:'--accent',run:'--accent',need:'--amber',done:'--tertiary'};
function rgba(hex,a){
  const m=/^#([0-9a-f]{6})$/i.exec(hex);
  if(!m) return hex;
  const n=parseInt(m[1],16);
  return 'rgba('+(n>>16)+','+(n>>8&255)+','+(n&255)+','+a+')';
}
function playChanges(changed,had){
  const css=getComputedStyle(document.documentElement), v=n=>css.getPropertyValue(n).trim();
  const fill=l=>LOOK_FILL[l]?v(LOOK_FILL[l]):'rgba(0,0,0,0)', still=REDUCE.matches;
  for(const c of changed){
    const ring=v(LOOK_RING[c.to]||'--outline'), from=fill(c.from), to=fill(c.to);
    for(const el of document.querySelectorAll('#root .card[data-id="'+c.id+'"]')){
      if(had.has((el.closest('.rc')?'n:':'p:')+c.id))
        el.animate([{backgroundColor:from},{backgroundColor:to}],{duration:450,easing:'ease'});
      const h=document.createElement('i');
      h.className='halo'; el.appendChild(h);
      // Reduced motion: the ring fades where it stands instead of spreading.
      h.animate(still?[{boxShadow:'0 0 0 3px '+rgba(ring,.7)},{boxShadow:'0 0 0 3px '+rgba(ring,0)}]
                     :[{boxShadow:'0 0 0 0 '+rgba(ring,.7)},{boxShadow:'0 0 0 14px '+rgba(ring,0)}],
        {duration:900,easing:'cubic-bezier(.2,.6,.4,1)'}).onfinish=()=>h.remove();
      const g=el.querySelector('.hd > .g');
      if(g) g.animate(still?[{opacity:0},{opacity:1}]
          :[{opacity:0,transform:'scale(.3)'},{opacity:1,transform:'scale(1.15)',offset:.6},{opacity:1,transform:'scale(1)'}],
        {duration:380,easing:'ease-out',delay:60,fill:'backwards'});
    }
  }
}
/* The board, top to bottom, in the Mac's order of priority:
   1. 进行中 — what needs you, then what is running, newest run first, lifted out of their projects;
   2. every project touched in the last two hours — or with something live in it, or with nothing in
      it yet — each under a full-width rule;
   3. 两小时内没动过 — the rest, each folded to its header, opened in place with its chevron.
   Ended terminals stay in their project as outlined cards. The Mac's 最近使用 tray has no
   counterpart here: the board has never had one, and it is not invented for the sake of matching. */
const DORMANT_AFTER=2*3600;
/* Dormant projects opened from their row. Not stored: it is a look, not a setting, and the next
   visit should fold them again — the Mac's `wokenProjects`. */
const woken=new Set();
/* `idle` is seconds since a terminal was last really used, -1 if never. Any one terminal being used
   brings the whole project back; a project with no terminals is never dormant, because its empty row
   is the way to start one. */
function lastIdle(all){ const v=all.filter(t=>t.idle>=0).map(t=>t.idle); return v.length?Math.min(...v):-1; }
function isDormant(all){
  if(!all.length) return false;
  if(all.some(t=>t.status==='working'||t.status==='needsYou')) return false;
  const last=lastIdle(all);
  return last<0||last>DORMANT_AFTER;
}
function wake(pid){ if(woken.has(pid)) woken.delete(pid); else woken.add(pid); if(state) render(state); }
/* Ordinary projects folded on this device, as the Mac's project headers fold. Kept in the browser
   rather than sent to the Mac: a phone and the desk want different things open, and the Mac's folds
   are its own. Storage can be missing or refuse (private mode), and then folds last the visit. */
const folded=(()=>{ try{ return new Set(JSON.parse(localStorage.getItem('fv_folded')||'[]')); }catch(e){ return new Set(); } })();
function foldProj(pid){
  if(folded.has(pid)) folded.delete(pid); else folded.add(pid);
  try{ localStorage.setItem('fv_folded',JSON.stringify([...folded])); }catch(e){}
  if(state) render(state);
}
/* The name, as on the Mac: folded, it opens the project — the obvious thing to click to see it;
   open, it copies the path, the one thing about a project that gets pasted elsewhere. */
function nameTap(pid,path,closed,dorm){
  if(closed){ if(dorm) wake(pid); else foldProj(pid); }
  else copyText(path,true).then(ok=>{ if(ok) toast(tr('toast.pathCopied')); });
}
/* `fold`: 'closed' — nothing below the header — or 'open'. `dorm`: the project sits in the dormant
   zone, where the chevron wakes it for this visit instead of folding it on this device. */
function projSection(s,p,all,terms,fold,dorm){
  const tot=all.reduce((a,t)=>a+t.tokens,0), last=lastIdle(all);
  const chev=`<button class="icb chev${fold==='open'?' open':''}" onclick="${dorm?'wake':'foldProj'}('${p.id}')" `+
    `title="${tr(fold==='open'?'common.collapse':'common.expand')}" aria-label="${tr(fold==='open'?'common.collapse':'common.expand')}">${ic('chevron-right','s16')}</button>`;
  // Only a top-level section slides on its own; one inside the dormant zone moves with that zone.
  let h=`<section class="proj${fold==='closed'?' folded':''}" data-pid="${p.id}"${dorm?'':` data-flip="p:${p.id}"`}><div class="ph">`+chev+
    `<span class="pname tm" role="button" data-path="${att(p.path)}" `+
    `onclick="nameTap('${p.id}',this.dataset.path,${fold==='closed'},${!!dorm})" `+
    `title="${att(p.path+'\n'+tr(fold==='closed'?'proj.nameFolded':'proj.nameOpen'))}">${esc(p.name)}</span>`+
    // Same rule as the cluster header: the project's real size, and what is on screen of it.
    `<span class="meta lm"><span title="${tr('count.terminals',{n:all.length})}">${ic('square-terminal','s14')}${terms.length===all.length?all.length:terms.length+' / '+all.length}</span>`+
    (tot>0?`<span title="${tr('common.tokens',{n:tot})}">${ic('sigma','s14')}${short(tot)}</span>`:'')+
    (last>=0?`<span title="${tr('proj.lastActivity')}">${rel(last)}</span>`:'')+`</span>`+
    `<span class="acts">`+
    // The path rides in a data attribute rather than in the handler's text: it is arbitrary user
    // data, and a project directory with a quote in it would otherwise end the attribute.
    `<button class="icb" data-path="${att(p.path)}" onclick="fbOpen(this.dataset.path)" title="${tr('proj.browse')}" aria-label="${tr('proj.browse')}">${ic('folder')}</button>`+
    `<button class="icb" onclick="newTerm('${p.id}')" title="${tr('proj.newTerm')}" aria-label="${tr('proj.newTerm')}">${ic('plus')}</button>`+
    `</span></div>`;
  if(fold==='closed') return h+'</section>';
  if(!all.length) h+=`<button class="emptyrow" onclick="newTerm('${p.id}')">${ic('plus','s16')}${tr('common.newTerm')}</button>`;
  const cids=[...new Set(terms.filter(t=>t.clusterId).map(t=>t.clusterId))];
  for(const cid of cids){
    const c=s.clusters.find(x=>x.id===cid), mem=terms.filter(t=>t.clusterId===cid);
    // The cluster's real size, and what is being shown of it — the header must not claim a
    // two-terminal task when the task has six and four are filtered out.
    const memAll=all.filter(t=>t.clusterId===cid);
    const size=mem.length===memAll.length?`${memAll.length}`:`${mem.length} / ${memAll.length}`;
    h+=`<div class="cluster" data-cid="${cid}" data-pid="${p.id}"><div class="chead">${ic('square-stack','s14')}<span class="cname ts">${esc(c?c.name:'')}</span>`+
       `<span class="ts" title="${tr('count.terminals',{n:memAll.length})}">${size}</span></div>`+
       `<div class="grid">${mem.map(t=>card(t)).join('')}</div></div>`;
  }
  const solo=terms.filter(t=>!t.clusterId);
  if(solo.length) h+=`<div class="grid">${solo.map(t=>card(t)).join('')}</div>`;
  return h+'</section>';
}
/* Each terminal's status as last drawn, and 进行中's ids in order — what a poll is compared with to
   decide whether anything is to move. null until the first board, which arrives without motion. */
let prevStatus=null, lastLive=null;
/* `poll`: this is a fresh /state. Only then does anything animate — the same board drawn again for
   a chevron or the mark filter is a different view, not a change in the fleet. */
function render(s,poll){
  const cnt=document.getElementById('counts');
  const cntText=tr('count.projects',{n:s.projects.length})+' · '+tr('count.terminals',{n:s.terminals.length});
  if(cnt.textContent!==cntText) cnt.textContent=cntText;
  let pills='';
  if(s.needs>0)pills+=`<span class="badge need" title="${tr('badge.needs',{n:s.needs})}">${glyph('needsYou')}${s.needs}</span>`;
  if(s.working>0)pills+=`<span class="badge run" title="${tr('badge.running',{n:s.working})}">${glyph('working')}${s.working}</span>`;
  const pillEl=document.getElementById('pills');
  if(pillEl.innerHTML!==pills) pillEl.innerHTML=pills;
  // The mark filter is this device's, not the fleet's: it is kept in localStorage rather than sent
  // to the Mac, so filtering on the phone does not empty the board you are working at.
  const marked=s.terminals.filter(t=>t.done).length;
  const mb=document.getElementById('markbtn');
  mb.style.display=(marked||onlyMarked)?'':'none';
  mb.classList.toggle('on',onlyMarked);
  document.getElementById('markcount').textContent=marked?marked:'';
  // FleetView's own triggers: shown once there are any, lit while one runs.
  const fb=document.getElementById('ftrigbtn'), fn=s.fleetTriggers||0;
  fb.style.display=fn?'':'none';
  fb.classList.toggle('on',(s.fleetTriggersRunning||0)>0);
  document.getElementById('ftrigcount').textContent=fn?fn:'';
  // What each card that changed status looked like until now — read before the anchors move under it.
  const now=Date.now(), changed=[];
  if(prevStatus) for(const t of s.terminals){
    const was=prevStatus[t.id];
    if(was&&was!==t.status) changed.push({id:t.id,status:t.status,from:lookOf(t.id,was,now)});
  }
  syncRuns(s.terminals);
  for(const c of changed) c.to=lookOf(c.id,c.status,now);
  let html='';
  if(!s.remoteOK)html+=`<div class="banner">${tr('board.banner',{cmd:'<b>'+esc(s.remoteHint)+'</b>'})}</div>`;
  /* What wants you and what is moving, before what exists. The board below is grouped by project
     because that is how work is organised; this answers the other question, which otherwise means
     scanning every section for a shape. Same cards — a second place to see a terminal, not a second
     kind — each tagged with the project it came from, since this zone cannot say it by grouping.
     Absent rather than empty when nothing qualifies. A run that ends simply leaves: its card says
     "just finished" in its project, and a group for it here would be a second place to look.
     Newest run first, since what has just started is what you are most likely after. Sorted on the
     local anchor rather than the seconds as sent: two runs begun in the same second tie on one poll
     and not the next, and the pair would swap back and forth. */
  const vis=onlyMarked?s.terminals.filter(t=>t.done):s.terminals;
  const live=[...vis.filter(t=>t.status==='needsYou'),
              ...vis.filter(t=>t.status==='working').sort((a,b)=>(runStart[b.id]||0)-(runStart[a.id]||0))];
  if(live.length){
    const pname=id=>{const p=s.projects.find(x=>x.id===id);return p?p.name:'—';};
    html+=`<section class="now"><div class="zh" data-flip="zh"><span class="ts">${tr('zone.now')}</span><span class="ts n">${live.length}</span></div>`
        + `<div class="grid">${live.map(t=>
            `<div class="rc" data-flip="n:${t.id}"><div class="from ls">${ic('folder','s12')}<span>${esc(pname(t.projectId))}</span></div>${card(t)}</div>`
          ).join('')}</div></section>`;
  }
  const dorm=[];
  for(const p of s.projects){
    const all=s.terminals.filter(t=>t.projectId===p.id);
    const terms=onlyMarked?all.filter(t=>t.done):all;
    // A project with nothing marked is left out whole, the way the Mac's board does it — the point
    // of the filter is a board with only the work you are tracking on it.
    if(!terms.length&&onlyMarked) continue;
    if(isDormant(all)){ dorm.push([p,all,terms]); continue; }
    html+=projSection(s,p,all,terms,folded.has(p.id)?'closed':'open',false);
  }
  if(dorm.length){
    html+=`<section class="dorm" data-flip="dorm"><div class="zh"><span class="ts">${tr('zone.dormant')}</span><span class="ts n">${dorm.length}</span></div>`;
    for(const [p,all,terms] of dorm)
      html+=projSection(s,p,all,terms,woken.has(p.id)?'open':'closed',true);
    html+='</section>';
  }
  // Every 1.5s this used to replace the whole board, which forces a layout in the middle of a
  // flick and shows up as a stall at the end of a scroll. Almost every tick is identical, so the
  // rebuild only happens when the markup actually differs.
  const out=html||(onlyMarked
    ? '<div class="empty">'+ic('bookmark')+'<span class="et ts">'+tr('empty.noMarked')+'</span>'
      +'<span class="bs">'+tr('empty.noMarkedSub')+'</span>'
      +'<button class="tonal" onclick="toggleOnlyMarked()">'+tr('mark.showAll')+'</button></div>'
    : '<div class="empty"><span class="et ts">'+tr('empty.noProjects')+'</span><span class="bs">'+tr('empty.noProjectsSub')+'</span></div>');
  /* Motion only when the fleet moved: a status changed, or 进行中 gained, lost or reordered a card.
     Most rebuilds are a token count ticking over, and those measure nothing and animate nothing. */
  const liveKey=live.map(t=>t.id).join(' ');
  const motion=!!poll&&lastLive!==null&&(liveKey!==lastLive||changed.length>0);
  lastLive=liveKey;
  prevStatus={};
  for(const t of s.terminals) prevStatus[t.id]=t.status;
  const root=document.getElementById('root'), rebuilt=out!==lastBoard;
  let before=null, had=null;
  if(rebuilt){
    if(motion){
      before=boardRects(root);
      had=new Set([...root.querySelectorAll('.card[data-id]')].map(el=>(el.closest('.rc')?'n:':'p:')+el.dataset.id));
    }
    lastBoard=out; root.innerHTML=out;
  }
  paintRuns();             // after any rebuild, so fresh clocks are filled in the same frame
  paintFresh(rebuilt);     // and the first-ten-seconds look, before anything measures the new cards
  if(before){ flipBoard(before,root); if(changed.length) playChanges(changed,had); }
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
  toast(tr(onlyMarked?'toast.onlyMarked':'toast.showAll'));
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
  if(b&&b.dataset.s!==scheme){            // runs on every poll; only touch the button on a change
    b.dataset.s=scheme;
    b.innerHTML=ic(scheme==='auto'?'monitor':(scheme==='dark'?'moon':'sun'));
    b.title=tr(scheme==='auto'?'scheme.btnAuto':(scheme==='dark'?'scheme.btnDark':'scheme.btnLight'));
    b.setAttribute('aria-label',b.title);
  }
}
function cycleScheme(){
  scheme=scheme==='auto'?'dark':(scheme==='dark'?'light':'auto');
  localStorage.setItem('fv_scheme',scheme);
  applyScheme();
  toast(tr(scheme==='auto'?'scheme.toastAuto':(scheme==='dark'?'scheme.toastDark':'scheme.toastLight')));
}
/* Before the first /state lands, so a saved choice is on the page it paints rather than one poll
   later — and so the button carries the right glyph from the start. */
applyScheme();
/* Connection state for the signal indicator; filled by ping() and tick() (see renderNet). */
const net={rtts:[],fails:0,via:null,stateAt:0};
async function tick(){
  if(dragging)return;
  try{
    const r=await fetch('/state',{cache:'no-store'});state=await r.json();
    // The appearance is the one thing worth keeping current while a conversation is open — for a
    // browser that is following the Mac, flipping the Mac's theme and watching the phone stay dark
    // reads as broken. Redrawing the board behind the overlay is not: that is the guard below.
    applyScheme(state.dark);
    net.stateAt=Date.now();
    if(termOpen()){watchTermAlive(state);return;}
    render(state,true);
    openPendingTerm(state);
    reportLocation(state);   // once per browser; no-op until the page is served over HTTPS
  }catch(e){}                // the signal indicator says offline; ping() is what decides that
}
/* A link straight to one terminal's conversation: #t=<terminal id>. The Mac's "在手机上打开" hands
   these out, so scanning one lands exactly where tapping that card here would — the chat, not the
   raw terminal it used to be. Acted on after a /state, because until then the page cannot tell a
   terminal that is attachable from one that is closed or gone. */
let pendingT=null;
function readTermHash(){
  const m=location.hash.match(/^#t=([0-9A-Fa-f-]{36})$/);
  pendingT=m?m[1].toUpperCase():null;
}
function openPendingTerm(s){
  if(!pendingT||!s) return;
  const id=pendingT; pendingT=null;
  const t=(s.terminals||[]).find(x=>x.id===id);
  if(!t){ toast(tr('toast.gone')); termSyncHash(); return; }
  if(t.canOpen) openTerm(t.id,t.name); else { toast(tr('toast.openOnMac')); termSyncHash(); }
}
/* The address bar follows the open conversation, so a reload or a shared link comes back to it.
   replaceState: opening a terminal is not a page of history. The file browser owns the hash while
   it is up (see fbSyncHash). */
function termSyncHash(){
  if(document.getElementById('fb').classList.contains('show')) return;
  const want=curId?'#t='+curId:'';
  if(location.hash!==want) history.replaceState(null,'',location.pathname+location.search+want);
}
readTermHash();
window.addEventListener('hashchange',()=>{
  readTermHash();
  if(!pendingT) return;
  if(termOpen()) closeTerm();
  if(state) openPendingTerm(state);
});
poll(tick,1500);
// A tab opened by the file browser's ↗, or one reloaded while it was open, lands on that folder or file.
{ const m=location.hash.match(/^#fb=(.+)$/); if(m){ try{ fbOpenPath(decodeURIComponent(m[1])); }catch(e){} } }

/* ---------- connection: signal bars and latency ----------
   A tiny request every 2 s, answered off the Mac's main thread, so the number is the network's and
   not the board's (a /state round trip includes the Mac drawing the board). The bars follow the
   median of the last five round trips, so one slow sample does not make them flicker; two failures
   in a row read as offline. The answer also says how this device reaches the Mac — same machine,
   LAN, or Tailscale direct or through a relay — which is most of what explains a slow number. */
async function ping(){
  if(document.hidden) return;              // nothing is on screen to update
  const ctl=new AbortController(), timer=setTimeout(()=>ctl.abort(),5000);
  const t0=performance.now();
  try{
    const r=await fetch('/ping',{cache:'no-store',signal:ctl.signal});
    const j=await r.json();
    net.rtts.push(performance.now()-t0); if(net.rtts.length>5) net.rtts.shift();
    const wasOff=net.fails>=2;
    net.fails=0; net.via=j;
    if(wasOff) recovered();
  }catch(e){
    // Gone: what the line was like before says nothing about it once it is back.
    if(++net.fails>=2) net.rtts=[];
  }
  finally{ clearTimeout(timer); }
  renderNet();
}
function netMedian(){
  if(!net.rtts.length) return null;
  const s=[...net.rtts].sort((a,b)=>a-b); return s[Math.floor(s.length/2)];
}
function netRoute(){
  const v=net.via||{};
  if(v.scope==='loopback') return tr('net.local');
  if(v.scope==='lan') return tr('net.lan');
  if(v.scope==='tailscale') return v.direct===true?tr('net.tsDirect')
    :v.direct===false?(v.relay?tr('net.tsRelayVia',{relay:v.relay}):tr('net.tsRelay')):'Tailscale';
  if(v.scope==='public') return tr('net.public');
  return '';
}
function renderNet(){
  const off=net.fails>=2, ms=netMedian();
  const lvl=off||ms==null?0:ms<80?4:ms<200?3:ms<500?2:1;
  const text=off?tr('net.offline'):ms==null?'…':Math.round(ms)+'ms';
  const html='<span class="bars l'+lvl+'"><i></i><i></i><i></i><i></i></span><span class="ms">'+text+'</span>';
  for(const id of ['netsig','tnetsig']){
    const el=document.getElementById(id); if(!el) continue;
    el.innerHTML=html; el.classList.toggle('off',off);
    el.title=netRoute()+(ms==null?'':' · '+Math.round(ms)+' ms');
  }
}
/* Tapping the bars reconnects, then says what they mean (a phone has no hover for the title).
   Reconnecting on every tap rather than only when they read offline: the terminal tab is ttyd's
   own connection, to another port, and it can be dead — "Press ⏎ to Reconnect", with no ⏎ a phone
   can reach — while every ping here is fine. */
function netToast(){
  // Read before reconnecting, which starts the latency samples over.
  const off=net.fails>=2, ms=netMedian(), route=netRoute(), rtts=[...net.rtts];
  reconnect(true);
  if(off){ toast(tr('net.reconnecting'),3500); return; }
  const parts=[tr('net.reconnected'),route||tr('net.aria')];
  if(ms!=null){
    const lo=Math.round(Math.min(...rtts)), hi=Math.round(Math.max(...rtts));
    parts.push(rtts.length>1?tr('net.latencyRange',{ms:Math.round(ms),n:rtts.length,lo:lo,hi:hi})
                            :tr('net.latency',{ms:Math.round(ms)}));
  }
  if(net.via&&net.via.node) parts.push(tr('net.node',{node:net.via.node}));
  if(net.stateAt) parts.push(tr('net.refreshed',{s:Math.max(0,Math.round((Date.now()-net.stateAt)/1000))}));
  toast(parts.join(' · '),4500);
}
/* Everything in flight is dropped, so nothing new waits behind a request stuck on a dead
   connection, and what the page shows is asked for again now rather than at the next beat. */
let manualAt=0;
function reconnect(manual){
  abortAll();
  if(manual){ manualAt=Date.now(); net.rtts=[]; renderNet(); }
  ping(); tick();
  if(termOpen()){
    if(curView==='chat') loadChat();
    else if(manual) retryTerm();       // a fresh ttyd page, which connects again on load
  }
}
/* The line came back by itself. ttyd may have given up on its socket while it was gone, and a
   fresh page is the only reliable way back in, so the terminal tab is reloaded too. */
function recovered(){
  abortAll(); tick();
  if(termOpen()){ if(curView==='chat') loadChat(); else retryTerm(); }
  if(Date.now()-manualAt<20000) toast(tr('net.back'),2500);
}
/* A phone that slept or changed networks comes back with every connection it had dead, and none of
   them says so. Reconnecting costs one round of requests; waiting costs up to the deadline. */
let hiddenAt=0;
document.addEventListener('visibilitychange',()=>{
  if(document.hidden){ hiddenAt=Date.now(); return; }
  if(hiddenAt&&Date.now()-hiddenAt>5000) reconnect(false); else ping();
});
window.addEventListener('online',()=>reconnect(false));
renderNet();poll(ping,2000);

// ---------- agent-authored dynamic panel (top region) ----------
let panelMtime=-1;
function togglePanel(){
  const el=document.getElementById('panel');el.classList.toggle('min');
  const min=el.classList.contains('min');
  el.querySelector('.pcollapse').innerHTML=ic(min?'chevron-down':'chevron-up','s16')+'<span>'+tr(min?'common.expand':'common.collapse')+'</span>';
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
poll(pollPanel,1500);
/* On its own timer, not inside tick(): tick() stops while a conversation is open, and a file that
   arrives while you are reading one is exactly when you want to be told. Slower, because handing a
   file over is a human-paced event. */
poll(loadFiles,4000);
</script>
</body>
</html>
"""#
}
