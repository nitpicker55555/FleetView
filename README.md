# FleetView

[English](README.md) · [简体中文](README.zh-CN.md)

A macOS app for managing Claude Code and Codex terminals.

FleetView puts your agent sessions on a board, grouped by project. You can see which agents are
working, which are waiting for input, and what you last asked each one to do. It also lets you
browse and resume conversation branches, create custom Generative UI panels, and access your
sessions from a phone.

![FleetView desktop board showing running and recently used agent terminals](docs/screenshots/desktop-board.png)

*Project names, terminal names, and paths in the screenshots are anonymized.*

## Conversation history and branches

The session tree shows the prompts and branches in your Claude Code and Codex conversations,
including earlier branches you have moved on from. Select a node to read it, or open it in a new
terminal to continue from that point. You can also duplicate a running session and take it in a
different direction with the same context.

![Session tree with conversation branches and a preview of the selected node](docs/screenshots/session-tree.png)

Opening a past node leaves the original transcript intact. FleetView resumes an existing session
where possible, or creates a new session file with the history leading up to that node. Claude
support is built in, using a Swift port of
[treeflow](https://github.com/nitpicker55555/Agent-Treeflow)'s branching logic. Opening past Codex
nodes requires treeflow to be installed.

Press **⌘K** to search local Claude Code and Codex history. **Tab** switches the scope between
terminals on the board, the current conversation, and all history. Drag a search result onto the
board to continue the conversation from that point.

The search index retains indexed conversations even after their source transcripts have been
deleted. Those conversations remain searchable and readable, and can be rebuilt into sessions.

## Managing terminals

Each terminal has a card showing its status, last prompt, token usage, and run time. Cards are
grouped by project. Drag one card onto another to group related terminals into a cluster, or move
a card to another project with its conversation.

The included `project-manager` CLI uses FleetView's HTTP API to list terminals, read their output,
and send input. An agent can use it to check another agent's progress, respond to a permission
prompt, or pass on the next task. The repository includes skills for these workflows in
`.claude/skills/`.

```bash
project-manager ls                   # List terminals, status, tokens, and last prompts
project-manager ls -p FleetView       # Filter by project
project-manager show <sel> -l 60      # Read a terminal's recent output
project-manager send <sel> "continue" # Send an instruction
project-manager whoami               # Identify the current terminal
project-manager check                # Find sessions that ended in an error
```

You can use the same commands with FleetView on another Mac. `project-manager peers` discovers
instances on the network; `-u <url>` selects the instance a command should use.

## Generative UI panels

An agent can build a custom panel for the task at hand: a progress board, a chart, a test summary,
or an overview of running agents. It writes a self-contained HTML page to
`~/.fleetview/ui/panel.html`, and FleetView displays it above the board on both desktop and mobile.
Changes to the page are picked up automatically.

Panels can update as the work runs, using either task data or live data from FleetView's API:

- **Task data:** the agent writes progress or results to `~/.fleetview/ui/panel.json`. The panel
  polls `GET /panel-data` and updates the relevant parts of the page.
- **Agent activity:** the panel calls `GET /state` to fetch current terminal states, last prompts,
  token usage, time since last activity, and run durations. It can show how many agents are working,
  idle, or waiting for input, with breakdowns by project.

The panel is served by FleetView itself, so its JavaScript can call these endpoints directly with
`fetch('/state')` or `fetch('/panel-data')`. The included
[example panel](examples/fleet-panel.html) polls `/state` every 1.5 seconds to refresh its status
counts and token charts. You can use it as a starting point for your own panel.

There is one shared panel per FleetView instance. Writing a new `panel.html` replaces the current
view; removing the file hides it.

![Generative UI panel with live agent status counts and token usage by project](docs/screenshots/generative-ui.png)

*The example panel reading live FleetView data through `/state`.*

## Access from your phone

FleetView serves a web dashboard from your Mac, accessible over your LAN or Tailscale without an
account or a separate server.

Conversations appear as chat, so you can read an agent's work, respond to permission prompts, and
send replies from a small screen. You can also open the live terminal to use a CLI picker, inspect
a diff, or type directly into the TUI.

Files can be sent in both directions. Attach a photo or file from your phone to a prompt, or run
`fleetview-send report.pdf` on the Mac to make an agent's output available in the dashboard's
file tray.

<p>
  <img src="docs/screenshots/mobile-board.png" width="320" alt="FleetView web dashboard showing agent status on a mobile viewport">
  <img src="docs/screenshots/mobile-chat.png" width="320" alt="FleetView chat view with conversation history and a reply field on a mobile viewport">
</p>

*The web dashboard and a conversation excerpt, captured at a phone-sized viewport.*

## Requirements

- macOS 14+
- Claude Code and/or Codex CLI
- `tmux` and `ttyd` for remote terminal access (`brew install tmux ttyd`). Local terminals work
  without them.
- [treeflow](https://github.com/nitpicker55555/Agent-Treeflow) for opening Codex conversations at a
  past node. The build script offers to install it; Claude support is built in.

## Install

Download `FleetView.app` from [Releases](../../releases), or build it from source:

```bash
git clone https://github.com/nitpicker55555/FleetView.git
cd FleetView
./scripts/package_app.sh --install  # Build and copy to /Applications
```

## Local data and sessions

FleetView stores its state, search index, logs, transferred files, and custom panel in
`~/.fleetview/`. It reads conversation history from `~/.claude/projects/` and `~/.codex/sessions/`.
Forking a conversation creates a separate session without modifying the original transcript.

By default, tmux sessions keep running when you quit FleetView and reconnect when you open it
again. Closing a terminal stops its running session. You can also enable the option to close all
terminals when quitting.

FleetView installs status hooks for Claude Code and Codex. To remove them, use
**FleetView → Uninstall Status Hooks**.

## Network access

The dashboard and API listen on all network interfaces and use plain HTTP without authentication.
Anyone who can reach the port can read conversations and send input to terminals. Use them on a
trusted network or through Tailscale, and keep the port off public networks. This also applies to
access through `project-manager`.

FleetView checks GitHub Releases for updates at most once every six hours. Set `"updates": false`
in `~/.fleetview/logging.json` to disable the check.
