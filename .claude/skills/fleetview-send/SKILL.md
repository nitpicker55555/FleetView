---
name: fleetview-send
description: >-
  Hand a file you produced to the person reading the FleetView web dashboard on their phone, using
  the `fleetview-send` CLI. Use whenever you have made something the user should LOOK AT rather than
  read in the terminal — a chart or screenshot, a report, a CSV or spreadsheet, a PDF, a log excerpt,
  a built artifact — and especially when the user is away from the Mac ("send me the chart", "put
  that on my phone", "I'm not at my desk", "show me the file", "give me the report"). Also use to
  list or withdraw what you have already sent.
---

# fleetview-send — give a file to the phone

FleetView's web dashboard is what the user reads when they are away from the Mac. It can already
send files *to* you: they attach one on the phone and its path is typed into the prompt. This is the
return trip. A file you offer shows up in the dashboard's file tray (the 📥 button in the header),
one tap from opening.

Reach for it whenever the answer is something to be *seen* rather than pasted into a terminal.
Printing a 200-line CSV into the conversation is worse than sending the file.

## Invoking it

```bash
fleetview-send report.pdf
# or, if it isn't on PATH:
python3 ~/PycharmProjects/FleetView/scripts/fleetview-send report.pdf
```

It writes straight into `~/.fleetview/outbox/` — no HTTP, no size limit, and it works even if
FleetView is not running (the file is simply waiting when it is). It only ever works on this Mac;
there is no remote mode.

## Commands

| | |
|---|---|
| `fleetview-send <file>...` | offer one or more files |
| `fleetview-send -m "note" <file>` | offer with a note shown beside it in the tray |
| `fleetview-send --list` | what is currently on offer |
| `fleetview-send --rm <id>...` | withdraw (an 8-char id prefix is enough) |
| `fleetview-send --clear` | withdraw everything |
| `fleetview-send --link` | print the dashboard URL to give the user |

## What to expect

```
$ fleetview-send -m "5 failures, all timeouts" runs/summary.csv out/chart.png
sent summary.csv  4.2KB  0d38537c
sent chart.png    413.7KB  9c259c46
→ open http://192.168.2.4:8080/ and use the file tray
```

- Each file is **copied** in under a generated uuid, so sending the same name twice never collides
  and later edits to your original do not change what was sent. The original name is kept as
  metadata and is what the phone sees when it saves the file.
- The sending terminal is recorded automatically (from `FLEETVIEW_TERM_ID`), so the tray says which
  agent produced it. Nothing to pass.
- Images, PDFs, text, CSV and video open in the browser; anything else downloads.

## Conventions

- **Say what you sent.** The tray is not on screen unless the user opens it, so name the file in
  your reply: "sent `summary.csv` to your phone — it's in the file tray."
- **Send the artifact, not a wall of text.** A chart, a diff, a report — attach it and summarise in
  one or two lines.
- **A note earns its keep.** `-m` is the one-line "why am I looking at this", and it is shown next
  to the filename. Use it.
- **Withdraw superseded files.** If you send a corrected version of something, `--rm` the old one so
  the tray does not accumulate near-identical files the user has to tell apart.
- **Don't send secrets.** The dashboard is served over plain HTTP on the LAN (and Tailscale) with no
  auth — anything in the tray is readable by anything that can reach the port. Credentials, `.env`
  files and private keys do not go here.
- **Don't send what is already visible.** If the user is at the Mac and the file is in the repo they
  are looking at, a path is enough.
