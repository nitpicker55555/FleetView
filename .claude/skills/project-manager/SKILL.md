---
name: project-manager
description: >-
  Inspect and control the OTHER running FleetView agent terminals from the shell via the `project-manager`
  CLI: list every agent's live status/tokens/last prompt, read a terminal's recent output or locate
  its conversation transcript, inject a prompt, answer a Claude/Codex permission or menu prompt,
  and detect sessions that ended in an error. Use whenever asked to monitor, supervise, coordinate,
  or drive other agents/terminals in the FleetView fleet — e.g. "check on the other agents", "is any
  session stuck or errored", "tell the X terminal to…", "approve/answer the prompt in Y", "what is
  the fleet doing", "where is agent Z's chat log".
---

# project-manager — control the FleetView agent fleet

FleetView runs many terminals (each usually a Claude Code or Codex session) under tmux and exposes an
HTTP API. `project-manager` is a thin CLI over that API, so it works on this Mac and remotely (Tailscale).

## Invoking it

Prefer `project-manager` if it's on `PATH`; otherwise call the script directly:

```bash
project-manager ls        # or:  python3 ~/PycharmProjects/FleetView/scripts/project-manager ls
```

- **zsh gotcha (this bit me):** do NOT stash the invocation in a shell variable and expand it —
  `PM="python3 …/project-manager"; $PM ls` fails with `command not found … (exit 127)`, because zsh
  (unlike bash) does **not** word-split an unquoted `$PM`, so the whole string is treated as one
  command name. Call the script path literally each time (or use an alias/function, or `${=PM}`).
- The server is auto-discovered from `~/.fleetview/web-port`. To target a different/remote instance,
  pass `-u <url>` (applies to every subcommand) or export `FLEETVIEW_URL`, e.g.
  `project-manager -u http://192.168.2.2:8080 ls`. To *discover* remote instances, run
  `project-manager peers` (below) — don't hand-grep logs or guess IPs.
- **`<id>`** in every command is a terminal selector: an id prefix (the 8-char code shown by `ls`,
  e.g. `7233abcc`) or a case-insensitive name substring. Names can repeat — **prefer the id prefix**.
  If a selector is ambiguous, `project-manager` prints the matches; re-run with a longer/id selector.
- If a command says it can't reach FleetView, the app isn't running — say so; do not guess.

## Commands

| Command | What it does |
|---|---|
| `project-manager ls` | Table of all terminals: id, name, cluster, project, agent, idle, tokens, status, last prompt |
| `project-manager watch [-n SEC]` | Live-refreshing `ls` (Ctrl-C to stop) |
| `project-manager show <id> [-l N]` | One terminal: status, cwd, transcript path, and the last N lines of output |
| `project-manager tail <id> [-l N]` | Just the recent output (default 200 lines) |
| `project-manager send <id> <text…>` | Inject a prompt and submit it (Enter). `-N` sends the text without Enter |
| `project-manager key <id> <key>` | Send one key: `esc enter up down left right tab bspace c-c c-d …` |
| `project-manager choose <id> <n>` | Answer a numbered menu: sends digit `<n>` then Enter |
| `project-manager check [<id>]` | Flag sessions that look error-terminated (API errors, tracebacks, exited, …) |
| `project-manager ask <id> <q…>` | **"BTW" side-query**: ask the agent a question using its current context **without** touching/interrupting its live session (forked print-mode query; the answer is thrown away after printing). Takes ~10-40s |
| `project-manager log <id> [-p\|-c\|-f]` | Locate the agent's transcript file; `-p` path only, `-c` cat, `-f` follow (tail -f) |
| `project-manager new <project>` | Open a new terminal in a project (matched by name) |
| `project-manager rm <id>` | Remove a terminal (kills its session) |
| `project-manager peers` | Scan the LAN and list every FleetView instance with its URL (for `-u`) |

## How to answer an agent's prompt

Both Claude Code and Codex show **numbered select lists** (e.g. `❯ 1. Yes  2. No`). Always **look
first**, then act:

```bash
project-manager show 7233abcc          # read the prompt + options the agent is waiting on
project-manager choose 7233abcc 1      # pick option 1 (sends "1" + Enter)
```

- **Arrow-key menus**: `project-manager key <id> down` (repeat) then `project-manager key <id> enter`.
- **Letter prompts** (e.g. Codex `t`/`y`/`n`): `project-manager send <id> -N y`.
- **Interrupt / cancel** a stuck turn: `project-manager key <id> esc` (or `c-c`).
- **Give a fresh instruction**: `project-manager send <id> "your new prompt"`.

## Asking without interrupting (BTW)

To ask a *working* agent something without disturbing its turn, use `ask` — never `send` (which
queues into the live task):

```bash
project-manager ask 7233abcc "which files have you changed so far?"
```

It forks a throwaway copy of the agent's session, answers from the same context, and leaves the live
session running untouched. Note: it re-processes the session context, so it costs tokens and takes a
few seconds; use it for genuine questions, not routine polling (use `ls`/`show` for status).

## Typical workflows

- **Survey the fleet**: `project-manager ls` — look for `needs you` (waiting on you) and `working` statuses,
  and the `IDLE` column (how long since real activity).
- **Triage errors**: `project-manager check` — then `project-manager show <id>` on anything flagged to read what
  failed before deciding to resend, interrupt, or restart it.
- **Unblock a waiting agent**: `project-manager show <id>` to see the question → `choose`/`key`/`send`.
- **Read/locate a conversation**: `project-manager log <id>` (path to the Claude/Codex `.jsonl`), or
  `project-manager show <id> -l 400` to read recent turns inline.

## Reaching a terminal on another machine (LAN)

A target id that's missing from the local `ls` is usually **on another FleetView instance**, not gone.
FleetView serves its API on all interfaces, so the same CLI drives any instance you can reach. Correct,
fast path:

```bash
project-manager peers                                 # scan the LAN → table of every instance + URL
project-manager -u http://192.168.2.2:8080 ls         # that instance's terminals
project-manager -u http://192.168.2.2:8080 show 8f904256 -l 40   # read before you drive
project-manager -u http://192.168.2.2:8080 send 8f904256 "…"
```

Pitfalls I hit doing it the hard way — avoid them:
- **Don't hand-discover.** Grepping `~/.fleetview/remote.log` for IPs and probing guesses is slow and
  misleading — a busy-looking IP returned `Connection refused` (wrong instance) before I found the
  right one; `arp -a` also hangs on reverse-DNS. Just run `peers`.
- **Peers aren't necessarily on Tailscale.** `tailscale status` showed only this Mac + phones, yet the
  other FleetView was a plain-LAN host (`192.168.2.2`). `peers` scans the local /24, so it finds it.
- **A selector is per-instance.** `8f904256` on `192.168.2.2` means nothing locally — pass the same
  `-u`/`FLEETVIEW_URL` to *every* command in the sequence, and report the URL alongside the name.

See the [[fleetview-peers]] skill for the full remote rules (what `open`/`log`/`ask` can't do across the
network, and the safety notes — there's no auth, so `send` lands in someone's live, permission-bypassed
session).

## Cautions

- `send`/`choose`/`key` **inject real keystrokes** into a live session. Before acting on a terminal
  that is `working`, prefer to `show` it first — don't interrupt an in-progress turn unless asked.
- **Confirm a `send`/`choose` actually landed** — check the exit status and re-`show` the terminal (an
  empty input box `❯` means it didn't). Don't write `send … && echo ok` and trust it: a failed send
  just skips the `&&`, so it looks silent. (This is how the zsh `$PM` bug above hid — the send returned
  127 and nothing was injected.)
- A terminal must have a live tmux session to inspect/drive it (`ls` shows it; closed ones can't be
  read). `send`/`choose` do nothing useful on a closed terminal.
- `check` is heuristic (it scans recent output). Confirm by reading `show <id>` before concluding a
  session truly failed. A user Ctrl-C is deliberately **not** treated as an error.
- Don't `rm` a terminal unless explicitly asked — it ends that agent's session.
