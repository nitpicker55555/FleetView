# FleetView

Mission control for a fleet of coding-agent terminals on macOS.

You end up running more than one Claude Code or Codex session at a time, and then you lose track of
them: which one is waiting on you, which one is still working, what you asked the one you started an
hour ago. FleetView puts them on a board — one card per terminal, live status, last prompt, token
burn — and lets you read and drive any of them from your phone.

<!-- A screenshot belongs here. -->

## What it does

**A board of terminals.** Every agent session is a card grouped by project, showing whether it is
working, idle, or waiting for you. Drag a card onto the action zones to mark, duplicate, rename or
remove it; drop one onto another to cluster them.

**Read and drive it from a phone.** FleetView serves a dashboard on your LAN (and over Tailscale).
Conversations render as chat with native scrolling rather than a mirrored TUI, so they are actually
readable on a small screen. You can type, answer a permission prompt with real buttons, attach a
file from your phone into the prompt, and receive files an agent sends back.

**Search every conversation you have ever had.** ⌘K searches all local Claude Code and Codex
transcripts — 12 GB across ~4,800 files here, indexed to ~180 MB in about 15 seconds, queried in
single-digit milliseconds. Search widens in three steps with Tab: the terminals on the board, the
conversation you have open, then all of history. Results group by project, and dragging one onto the
board opens that conversation at that point.

**Open any past node, including abandoned branches.** A conversation is a tree — rewinding or
editing a prompt starts a new branch and the old one stays on disk. The session tree panel shows all
of them and can open any node in a fresh terminal, without touching the original session. This is
[treeflow](https://github.com/nitpicker55555/Agent-Treeflow)'s algorithm, ported for Claude and shelled
out to for Codex.

**A panel your agents can draw on.** An agent can publish a self-contained web page to the top of
the dashboard — a progress board, a live chart, whatever it wants to show you while it works.

## Requirements

- macOS 14+
- `tmux` and `ttyd` for remote access (`brew install tmux ttyd`) — without them terminals still run,
  they just can't be served to other devices
- Claude Code and/or Codex CLI

## Install

Download the latest `FleetView.app` from [Releases](../../releases), or build it:

```bash
git clone https://github.com/nitpicker55555/FleetView.git
cd FleetView
./scripts/package_app.sh --install     # builds and copies to /Applications
```

## Command line

`project-manager` drives a running FleetView over its HTTP API, locally or across the network:

```bash
project-manager ls                  # every terminal, status, tokens, last prompt
project-manager show <sel> -l 60    # one terminal's recent output
project-manager send <sel> "继续"    # inject a prompt
project-manager check               # find sessions that ended in an error
```

`fleetview-send report.pdf` hands a file to whoever is reading the dashboard — it appears in the
file tray, one tap from opening on a phone.

Both have companion skills in `.claude/skills/`, so an agent running inside FleetView can use them
without being told how.

## On disk

Nothing runtime lives in this repo. FleetView keeps its state in `~/.fleetview/`: `state.json`, the
search index, logs, uploads, and the panel an agent published. Your conversations stay where the
agents already put them (`~/.claude/projects/`, `~/.codex/sessions/`) — FleetView reads them and
never rewrites them.

Status comes from hooks FleetView installs into Claude Code and Codex, fenced by sentinel comments
and removed cleanly on uninstall (**FleetView → Uninstall Status Hooks**).

## A note on the network

The dashboard is served over plain HTTP with no authentication, so anything that can reach the port
can read your conversations and type into your agents. That is fine on a home network or a Tailscale
tailnet, and it is not fine on a café Wi-Fi. There is one outbound call — an update check against
GitHub's releases endpoint, at most every six hours — which you can turn off with `"updates": false`
in `~/.fleetview/logging.json`.

## Status

0.1. It is used daily to run a real fleet, but it is early: the parts that touch Codex are newer
than the parts that touch Claude, and the session tree does not understand Codex branches yet.
