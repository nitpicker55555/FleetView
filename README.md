# FleetView

[English](README.md) · [简体中文](README.zh-CN.md)

Mission control for a fleet of coding-agent terminals on macOS.

You end up running more than one Claude Code or Codex session at a time, and then you lose track of
them: which one is waiting on you, which one is still working, what you asked the one you started an
hour ago — and, once a conversation has branched a few times, which version of it you are even
looking at. FleetView puts every session on a board, gives you the whole tree behind each one, lets
the terminals work together, and serves the lot to your phone.

<!-- SCREENSHOT 1 — the board: several project sections, a card mid-run with its clock ticking,
     one card showing "needs you". This is the hero image; everything else is a detail of it. -->

---

## 1. Every session, as a tree you can walk

This is the part the official CLIs do not give you. A conversation is not a line — rewinding a
prompt, editing one, or forking a session starts a new branch, and the old one stays on disk with no
way back to it. `claude --resume` can only address a whole session by id, and `codex fork` only
branches from the tip. Everything in between is on disk and unreachable.

**Read the whole history.** The session tree panel shows every node of a conversation, including the
branches you abandoned, for both Claude Code and Codex. Claude's tree comes from `parentUuid` links,
Codex's from `forked_from_id` — two different formats, one panel.

**Restart from any point.** Open any node in a fresh terminal. The original session is never
modified: a node that some session already resolves to resumes natively, and anything else gets a
synthesised session file containing that node's ancestry, so Claude picks up exactly there. This is
[treeflow](https://github.com/nitpicker55555/Agent-Treeflow)'s algorithm, ported to Swift for Claude
and shelled out to for Codex.

**Duplicate a running session.** Fork a live terminal into a second one that shares its context and
diverges from there — native `--fork-session` where the CLI supports it, a synthesised branch where
it does not.

**Search everything you have ever said.** ⌘K searches all local Claude Code and Codex transcripts —
12.9 GB of them on this machine, indexed to 249 MB and answered in single-digit milliseconds. Tab
widens the scope in three steps: the terminals on the board, the conversation you have open, then all
of history. Drag a result onto the board and that conversation opens *at that point*, ready to
continue.

The index also outlives the files. Claude Code deletes transcripts after 30 days by default; the
index here still holds 5,857 files' worth of conversation while only 3,153 remain on disk. A
conversation the CLI has already cleaned up is still searchable, still readable, and can still be
rebuilt into a session you can resume.

<!-- SCREENSHOT 2 — the session tree panel next to a card, with a branch point visible, and
     ideally the ⌘K search overlay in a second shot. -->

---

## 2. Terminals that work together

**A board, not a tab bar.** One card per terminal, grouped by project, each showing whether it is
working, idle, or waiting for you, plus its last prompt and token burn. Drag a card onto another to
cluster them; clusters are how a group of terminals on one task stays together as a unit. Drag a
card into another project and its conversation goes with it.

**Agents can drive each other.** `project-manager` speaks to a running FleetView over HTTP, so an
agent inside one terminal can list the fleet, read another terminal's output, answer a permission
prompt for it, or hand it a new instruction — by terminal, by project, or by what it was last doing.
It ships as a skill in `.claude/skills/`, so an agent finds it without being told.

```bash
project-manager ls                  # every terminal, status, tokens, last prompt
project-manager ls -p FleetView     # just one project
project-manager show <sel> -l 60    # what a terminal is doing right now
project-manager send <sel> "继续"    # give it an instruction
project-manager whoami              # which card am I running on?
project-manager check               # sessions that ended in an error
```

**Across machines.** Every FleetView serves its API on all interfaces, so the same CLI drives an
instance on another Mac. `project-manager peers` scans the LAN and hands you the URL; `-u <url>`
points any command at it. Nothing to install on the other side — a fleet on your laptop is readable
and drivable from your desktop, and vice versa.

<!-- SCREENSHOT 3 — a cluster on the board (two or three cards boxed together), or the
     `project-manager peers` output next to a board showing another machine's terminals. -->

---

## 3. The whole fleet, from your phone

**A dashboard on your LAN** (and over Tailscale), served by the app itself — no account, no cloud,
nothing leaves the machine.

**Conversations render as chat**, with native scrolling, rather than a mirrored terminal. That is
what makes them readable on a small screen: you can follow what an agent did, answer a permission
prompt with real buttons, and type a reply.

**The raw terminal is there too.** When you want the actual TUI — a full-screen picker, a diff, a
progress bar — the card opens the live terminal itself, scrollable and typeable from the phone.

**Files move both ways.** Attach a photo or a file from your phone straight into a prompt, and
`fleetview-send report.pdf` on the Mac puts a file in the dashboard's tray, one tap from opening on
the phone. Useful for exactly the thing that is otherwise awkward: an agent produced a chart, a CSV
or a build, and you are not at the desk.

**A panel your agents can draw on.** An agent can publish a self-contained web page to the top of
the dashboard — a progress board, a live chart, a countdown — and it shows up on both the desktop
board and the phone.

<!-- SCREENSHOT 4 — the phone view: a conversation rendered as chat, and ideally a second shot of
     the file tray or the raw terminal view. Portrait, real device frame if you have one. -->

---

## Requirements

- macOS 14+
- `tmux` and `ttyd` for remote access (`brew install tmux ttyd`) — without them terminals still run,
  they just can't be served to other devices
- Claude Code and/or Codex CLI
- [treeflow](https://github.com/nitpicker55555/Agent-Treeflow) for opening Codex sessions at a past
  node (`pip install`; the installer offers it). Claude's side is built in.

## Install

Download the latest `FleetView.app` from [Releases](../../releases), or build it:

```bash
git clone https://github.com/nitpicker55555/FleetView.git
cd FleetView
./scripts/package_app.sh --install     # builds and copies to /Applications
```

## On disk

Nothing runtime lives in this repo. FleetView keeps its state in `~/.fleetview/`: `state.json`, the
search index, logs, uploads, and the panel an agent published. Your conversations stay where the
agents already put them (`~/.claude/projects/`, `~/.codex/sessions/`) — FleetView reads them and
never rewrites them, including when it forks one.

Quitting FleetView does not stop your agents: the tmux sessions keep running and reattach when you
open it again. Closing a terminal is the only thing that ends one.

Status comes from hooks FleetView installs into Claude Code and Codex, fenced by sentinel comments
and removed cleanly on uninstall (**FleetView → Uninstall Status Hooks**).

## A note on the network

The dashboard is served over plain HTTP with no authentication, so anything that can reach the port
can read your conversations and type into your agents. That is fine on a home network or a Tailscale
tailnet, and it is not fine on a café Wi-Fi. The same applies to the cross-machine CLI: there is no
token, and an instance you can reach is an instance you can drive.

There is one outbound call — an update check against GitHub's releases endpoint, at most every six
hours — which you can turn off with `"updates": false` in `~/.fleetview/logging.json`.

## Status

0.4, used daily to run a real fleet. The parts that touch Codex are newer than the parts that touch
Claude: both trees work, but Codex branches are read through treeflow rather than natively, and
opening a Codex node needs it installed.
