---
name: fleetview-peers
description: >-
  Reach the OTHER FleetView instances on this network — the ones running on different Macs — with
  the `project-manager` CLI. Use whenever the task spans machines: "what is the other Mac working
  on", "check the fleet on my laptop", "is anything stuck on the studio machine", "tell the agent
  over there to continue", "find every FleetView on the network". Also use before assuming a
  terminal is missing: it may simply be on another instance.
---

# Controlling other FleetView instances

Each FleetView serves an HTTP API on all interfaces, and `project-manager` speaks it. So the same
CLI that drives the local fleet drives any instance you can reach — no agent, no relay, nothing to
install on the other machine.

## Find them

```bash
project-manager peers
```

```
URL                    USER         TERMS WORKING   PROJECTS
http://192.168.2.2:8080 tianyi       9     1         cosy voice, FleetView
http://192.168.2.6:8080 puzhen       26    2         FleetView, datagen_vision2web  ←self
```

It probes every address on your subnets (netmask-aware; a network wider than 4096 addresses is cut
to the local /24, and it says so) plus the online peers Tailscale reports, on ports 8080–8082
(`--ports` to change), and identifies an instance by whether `/state` answers with the right shape.
Tailnet hosts get a longer timeout — a tailnet hop can take two seconds to answer. A whole subnet
takes a few seconds. FleetView binds the next free port from 8080 up, so
a machine whose 8080 was busy appears on 8081 — and **one machine can show up twice**, which means
two instances are running there and they are fighting over the same hook events. That is worth
reporting, not working around.

`USER` is **inferred, not reported** — `/state` has no user field, so it is read off the `/Users/<name>`
prefix of any project path, terminal cwd or transcript path the instance exposes. An instance with no
projects and no terminals hands over no path at all and shows `-`; that means "nothing to read it from",
not "no user". Say which machine you mean by URL anyway — a username is a hint, not an address.

## Drive one

```bash
project-manager -u http://192.168.2.2:8080 ls
project-manager -u http://192.168.2.2:8080 show cosy -l 40
project-manager -u http://192.168.2.2:8080 send cosy "继续"
```

`-u` applies to every subcommand; `FLEETVIEW_URL` does the same thing if you would rather export it
once. Every command in the [[project-manager]] skill works against a remote instance — the terminal
ones (`ls`, `watch`, `show`, `tail`, `send`, `key`, `choose`, `check`, `new`, `rename`, `rm`,
`notes`, `open` for a folder in *that* Mac's `~/PycharmProjects`, `restore` for a conversation on
*that* Mac) through the HTTP API, and the ones that read files through `/pm`, below. A peer whose
FleetView predates `restore` says so instead of restoring.

`send` reports whether the prompt actually left the agent's input box. A peer running an older
FleetView cannot answer that, so the CLI checks the pane itself — same verdicts, same exit codes.

`notes` crossing the network is worth knowing: the other machine's sidebar notes (and the quick-command
chips on its web dashboard) are readable *and* writable from here, so `notes add` is a way to leave a
path or a command where someone at that Mac will see it. An empty list means that instance has no
notes — not that the notes could not be read.

## Reading another machine's history and files

`projects`, `history`, `session` (with `-t` and `--files`), `search`, `memory`, `log` and `cat` read
files — transcripts, the search index, memory notes. Against another instance they run **on that
machine**: FleetView's `GET /pm` starts the same `project-manager` script there and hands back what it
printed. So the answer is that Mac's history, byte for byte what you would see at its keyboard, and the
`next:` hints already carry the `-u` to follow them.

```bash
project-manager -u http://100.109.51.92:8080 projects
project-manager -u http://100.109.51.92:8080 session 23f989d7 --files
project-manager -u http://100.109.51.92:8080 cat '~/PycharmProjects/ml_data_gen/README.md'
project-manager -u http://100.109.51.92:8080 log 4d7e4c21 -f      # follows the transcript over there
```

- **`cat` is how you open what history points at.** A path from `--files` or `memory` is on the other
  disk; `cat <file>` prints it (1 MB cap, `--max` for more), `cat <folder>` lists it. Quote a `~` path
  — your own shell would expand it to *your* home before it left.
- **`log -c` / `-f` read the transcript there**, in pieces cut at line ends; `-f` holds back a line the
  agent is still writing, so you never see half a record.
- **"Your project" is decided here.** `history`/`memory` with no project, and `subagent` with no `-p`,
  mean the project with your project's name on that machine; if it has none, the command says so.
- **`whoami` ignores `-u`.** It is about the card *you* run on, which lives on this Mac.
- **`ask`** forks an agent process on the remote machine. It works, but it spends that machine's API
  budget and you cannot see it start. Prefer `show` unless you specifically want the agent's own
  reading of its context.
- **An older FleetView has no `/pm`** and the CLI says so; the terminal commands still work against it.
- **The live terminal view** (the dashboard's Terminal tab, HTTP `/open`) hands back a ttyd port on
  that machine; the web page rebuilds the URL from its own host, a CLI just gets a number. Use
  `show`/`tail` from the CLI. (Not the CLI's `open`, which puts a project on the board.)

## A FleetView with no screen (headless)

A Mac reached only over SSH — the Mac mini is one — has no window server for FleetView to draw on, and
the app used to start there as a process that never finished launching. It now runs headless there:
the board is its web dashboard, terminals are tmux sessions nobody is attached to, and everything above
works against it unchanged. It turns itself on when there is no GUI session, or with `--headless`.

Start it **from an SSH login**, in a tmux session so it outlives the connection:

```bash
tmux new-session -d -s fleetview-app "~/Applications/FleetView.app/Contents/MacOS/FleetView --headless 2>&1 | tee -a ~/fleetview-headless.log"
```

Not from launchd. macOS checks the files an agent opens against the process responsible for it; from
SSH that is the remote-login service, which on the mini has Full Disk Access (measured: a FleetView
terminal there reads the system TCC database), while a launchd job would be FleetView itself — and
granting FleetView anything takes a screen. Stop it with `kill -TERM` (or Ctrl-C in its tmux window):
it saves and leaves the terminals running, and the next start reattaches them. It does not come back
by itself after a reboot.

## There is no authentication

Anything that can reach the port can inject prompts, press keys, and remove terminals — and, through
`/pm`, read that machine's conversation history and any file its user can (`cat`). There is no token,
no password, and the agents on the other side usually run with permissions bypassed. That is a
deliberate choice for a home LAN and a private tailnet; it is not safe on a network you share.

What follows from that, for you:

- **You are driving someone's live work.** A prompt you inject lands in a real session that may be
  mid-task. `ls` and `show` first; know what it is doing before you send anything.
- **Say which instance you touched.** Report the URL alongside the terminal name, always. "Sent
  继续 to `cosy voice-1`" is ambiguous across machines; "…on `192.168.2.2:8080`" is not.
- **Never `rm` on a remote instance without being asked to.** Removing a terminal destroys its tmux
  session and whatever was running in it. On your own machine that is recoverable knowledge; on
  another one you cannot see what you took. `restore <session-id>` can bring the conversation back,
  not the work that was in flight when it was killed.
- **Do not scan networks you were not asked to.** `peers` looks at the local subnet, which is fine
  at home and is not fine on a café or office network. If the user is somewhere shared, ask first.

## Conventions

- **Read before write, every time.** `peers` → `ls` → `show` → only then `send`.
- **A terminal selector is per-instance.** `8f904256` on one machine means nothing on another, and
  name substrings collide across fleets. Resolve the id against the instance you are targeting.
- **If a peer disappears mid-task, say so.** A laptop closing its lid takes its whole fleet with it;
  that is not an error to retry through.
