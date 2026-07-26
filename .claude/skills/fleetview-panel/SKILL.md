---
name: fleetview-panel
description: >-
  Render a live, custom UI in FleetView's dynamic panel — the full-width region at the very top of the
  FleetView desktop app and web dashboard. Use when the user wants you to SHOW something visual and
  updating while you work: a progress dashboard, a live chart/metrics, a status board, a countdown, a
  build/test monitor, a table that refreshes, etc. You author a self-contained web page; FleetView
  displays it. Triggers: "show a dashboard/progress bar at the top", "put a live UI in FleetView",
  "visualize this while it runs", "render a panel", "display progress in the fleet view".
---

# FleetView dynamic panel

FleetView shows one **global** panel in a full-width region at the very top (desktop + web). You
create it by writing a normal web page to a file; FleetView renders it and auto-reloads when it
changes. Read-only (the panel displays; it can't send input back).

## The contract

1. **Write your page** to `~/.fleetview/ui/panel.html` (create the dir first):
   ```bash
   mkdir -p ~/.fleetview/ui
   cat > ~/.fleetview/ui/panel.html <<'HTML'
   …your full HTML document…
   HTML
   ```
2. **Viewport**: full width × **~240px tall**. Design for that height; if your content is taller it
   scrolls inside the panel. Style it to sit on a dark app (or set your own background).
3. **Networking is allowed** — you may load external CDNs (Chart.js, etc.), fetch external APIs, and
   fetch the same-origin data file below. No "self-contained only" restriction.
4. **Live updates — two ways:**
   - *Preferred (smooth):* write fast-changing data as JSON to `~/.fleetview/ui/panel.json`, and have
     your page poll it with `fetch('/panel-data')` on a timer, updating the DOM. No reload, no flicker.
   - *Simple:* just rewrite `panel.html`. FleetView reloads the panel within ~1.5s of any change.
5. **One global panel** — writing `panel.html` replaces whatever was there (last writer wins). Don't
   assume you're the only writer; overwrite intentionally.
6. To **remove** your panel: `rm ~/.fleetview/ui/panel.html` (the region hides automatically).

## Template — a live progress dashboard

Write this once, then just update `panel.json` as you work:

```bash
mkdir -p ~/.fleetview/ui
cat > ~/.fleetview/ui/panel.html <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><style>
  body{margin:0;font:14px -apple-system,system-ui,sans-serif;color:#ebedf2;background:#14171c;
    height:240px;box-sizing:border-box;padding:16px 20px;overflow:auto}
  h1{font-size:15px;margin:0 0 12px} .row{margin:8px 0}
  .bar{height:14px;background:#25282f;border-radius:7px;overflow:hidden}
  .fill{height:100%;background:linear-gradient(90deg,#5cd18c,#7a9eff);width:0;transition:width .4s}
  .sub{color:#99a1b0;font-size:12px}
</style></head><body>
  <h1 id="title">Working…</h1>
  <div class="row"><div class="bar"><div class="fill" id="fill"></div></div></div>
  <div class="row sub" id="detail"></div>
<script>
  async function tick(){
    try{
      const d = await (await fetch('/panel-data',{cache:'no-store'})).json();
      document.getElementById('title').textContent = d.title || 'Working…';
      document.getElementById('fill').style.width = ((d.progress||0)*100).toFixed(0) + '%';
      document.getElementById('detail').textContent =
        (d.detail||'') + '  ·  ' + Math.round((d.progress||0)*100) + '%';
    }catch(e){}
  }
  tick(); setInterval(tick, 1000);
</script></body></html>
HTML
```

Then, as work progresses, update the data (FleetView serves it at `/panel-data`):

```bash
echo '{"title":"Running tests","progress":0.42,"detail":"42/100 passed"}' > ~/.fleetview/ui/panel.json
```

That's it — the bar animates live in FleetView's top region, on desktop and phone, with no reloads.

## Notes

- The panel is served from FleetView's own web server, so `/panel-data` (and any same-origin path) is
  reachable from your page on both desktop and web.
- Keep it lightweight — it polls and repaints; avoid heavy per-frame work.
- Don't put secrets in the panel: anyone viewing FleetView (incl. the LAN/Tailscale web) sees it.
