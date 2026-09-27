---
name: project-manager
description: >-
  Inspect and control the OTHER running FleetView agent terminals from the shell via the `project-manager`
  CLI: list every agent's live status/tokens/last prompt, read a terminal's recent output or locate
  its conversation transcript, inject a prompt, answer a Claude/Codex permission or menu prompt,
  and detect sessions that ended in an error. Also the way into the user's PAST work on this Mac:
  which projects they worked on recently, each project's Claude/Codex conversations with their
  transcript paths, what a conversation covered turn by turn, and search across all of it. Use
  whenever asked to monitor, supervise, coordinate, or drive other agents/terminals in the FleetView
  fleet — e.g. "check on the other agents", "is any session stuck or errored", "tell the X terminal
  to…", "approve/answer the prompt in Y", "what is the fleet doing", "where is agent Z's chat log" —
  and whenever the user refers to earlier work: "what was I doing lately", "我最近做了 X 项目",
  "find the conversation where we…", "where is the session file for…".
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
- **`<id>`** in the terminal commands is a terminal selector: an id prefix (the 8-char code shown by
  `ls`, e.g. `7233abcc`) or a case-insensitive name substring. Names can repeat — **prefer the id
  prefix**. If a selector is ambiguous, `project-manager` prints the matches; re-run with a longer one.
- **`session <id>` is different: it names a conversation**, not a terminal — a session-id prefix as
  `history` prints it, a FleetView card id (live or removed), or a transcript path. A live terminal's
  own conversation is reachable either way: `session <its card id>`.
- If a command says it can't reach FleetView, the app isn't running — say so; do not guess.

## Commands

| Command | What it does |
|---|---|
| `project-manager whoami` | Which card *this* agent is on: terminal, project, project path, cwd. `-p`/`--path`/`--id` print one value for scripts |
| `project-manager ls [-p PROJ] [-g] [-m]` | Table of all terminals: id, name, cluster, project, agent, idle, tokens, status, last prompt. `-p` narrows to one project, `-g` groups by project, `-m` only marked cards (in full detail) |
| `project-manager watch [-n SEC] [-p PROJ] [-g] [-m]` | Live-refreshing `ls` (Ctrl-C to stop) |
| `project-manager show <id> [-l N]` | One terminal: status, cwd, transcript path, and the last N lines of output |
| `project-manager tail <id> [-l N]` | Just the recent output (default 200 lines; blank padding at the bottom of a TUI is not counted) |
| `project-manager send <id> <text…>` | Inject a prompt, submit it, and **confirm it left the input box** (see below). `-N` types without Enter |
| `project-manager key <id> <key>` | Send one key: `esc enter up down left right tab bspace c-c c-d …` |
| `project-manager choose <id> <n>` | Answer a numbered menu: sends digit `<n>` then Enter |
| `project-manager check [<id>]` | Flag sessions that look error-terminated (API errors, tracebacks, exited, …) |
| `project-manager ask <id> <q…>` | **"BTW" side-query**: ask the agent a question using its current context **without** touching/interrupting its live session (forked print-mode query; the answer is thrown away after printing). Takes ~10-40s |
| `project-manager log <id> [-p\|-c\|-f]` | Locate the agent's transcript file; `-p` path only, `-c` cat, `-f` follow (tail -f) |
| `project-manager new <project> [label]` | Open a terminal in a project. `--claude` starts a permission-bypassed Claude session in it, `-c CMD` runs any other command |
| `project-manager subagent <task…>` | Open a new agent terminal and hand it a task. `--codex` for Codex, `-p` for another project, `-n` to name the card, `--id` for the bare uuid on stdout, `--no-wait` to start the agent without sending the task |
| `project-manager rename <id> <name…>` | Relabel a terminal |
| `project-manager rm <id>` | Remove a terminal (kills its session) |
| `project-manager notes [-f Q] [-p]` | The sidebar Notes list — also the web dashboard's quick-command chips. `-f` filters, `-p` prints raw text for copying |
| `project-manager notes add <text…>` | Append a note (newlines and quotes survive; use single quotes in zsh) |
| `project-manager notes rm <note>` | Delete a note, selected by its number, id prefix, or a text substring. It prints the note back — that's the only undo |
| `project-manager peers [--ports P] [--timeout S]` | Scan your subnets and online Tailscale peers; list every FleetView instance with its URL (for `-u`) |
| `project-manager projects [-n N] [--days D] [-a]` | **History L0**: projects on this Mac by last activity, 2 lines each. `-a` adds scratch dirs and non-interactive runs |
| `project-manager history [<project>] [-n N] [-a]` | **History L1**: a project's conversations — title, span, turns, transcript path (default: your own project) |
| `project-manager session <id> [--all]` | **History L2**: one conversation, one line per turn, plus how it ended and how to resume it |
| `project-manager session <id> -t N[-M] [--full]` | **History L3**: one turn (up to 5) in full — your prompt and the agent's answer |
| `project-manager search <words…> [-p PROJ] [-n N] [--prompts\|--replies] [-a]` | Which conversations mention something, grouped by conversation, with turn numbers. `--prompts` only what the user typed, `--replies` only what agents said |
| `project-manager session <id> --files` | The files a conversation **wrote/edited** (and, for Claude, read), grouped by folder; plus paths its shell commands created |
| `project-manager memory [<project>]` | Notes earlier agents left about a project (Claude's per-project memory) — read these first |
| `project-manager open <folder> [-t\|--claude\|--codex] [-n NAME]` | Put a folder from `~/PycharmProjects` on the board (the web's 📂), optionally with a terminal/agent in it. Needs a FleetView new enough to have `/workspace` — an older one says so |

## Knowing which project you are in

An agent inside a FleetView terminal can ask which card it is running on:

```bash
$ project-manager whoami
● FleetView-2   [running]  8632f30a
    project: FleetView
    path:    /Users/puzhen/PycharmProjects/FleetView
    cwd:     /Users/puzhen/PycharmProjects/FleetView
    agent=claude  tokens=314.8k
```

`-p` prints just the project name, `--path` just its directory, `--id` just your own terminal id —
one bare value each, so they compose:

```bash
project-manager ls -p "$(project-manager whoami -p)"     # my siblings in this project
project-manager show "$(project-manager whoami --id)"    # my own card, as others see it
```

It identifies itself from `FLEETVIEW_TERM_ID`, exported into every terminal FleetView creates (the
same handle the status hooks report under), falling back to the `fv_<uuid>` tmux session name if that
variable was lost. Outside a FleetView terminal it exits non-zero and says so.

**Ask, don't cache.** A terminal can be dragged into another project, which changes the answer with
no shell restart — a project name captured once goes stale with nothing to signal it.

**`cwd` is not the project.** `whoami` prints both because they diverge: agents `cd` around, while a
terminal's project is whichever card holds it. Anything that should be per-project keys off
`project`, not `pwd`.

## Listing one project's terminals

```bash
project-manager ls -p FleetView       # only that project
project-manager ls -g                 # every project, grouped
project-manager watch -p FleetView    # ...the same, live
```

`-p` resolves a project by **exact name first**, then name substring, then id prefix, all
case-insensitive — so `-p fancy_web` is that project alone, while `-p fancy` also brings in
`qwen_fancy_web`. It composes with `-m`, and `watch` takes both flags too. `new` resolves its
project argument the same way.

`-g` groups by project, dropping the now-redundant PROJECT column and heading each group with
`(total, n live)`. That is the view that puts a project's **closed** cards next to its live ones —
the flat list interleaves them with every other project.

Ids printed by either view are exactly the selectors `show`/`send`/`choose` take, so the normal way
in is `ls -p FleetView` → pick an id → `project-manager show <id>`.

**Don't grep the table for a project.** It used to be quietly wrong: the PROJECT column was
hard-truncated to 12 characters, so `ls | grep Benchmark_COWORK` matched nothing against a row that
read `Benchmark_CO`. The column is now sized to what is actually on screen, but `-p` is still the
answer — it filters on the real `projectId`, not on rendered text.

Two field behaviours behind all of this:

- **`projectId` is the grouping key, not `cwd`.** A terminal's `cwd` can be anywhere (agents `cd`
  around); its project is whichever card it lives on.
- **A terminal's `name` drifts.** FleetView renames cards from the conversation, so today's
  `VC-SPEC-CH` was `⌕ 核查通过，版本号已改并提` an hour ago. Match on the id, never on a remembered name.

## Opening a terminal, and starting an agent in it

```bash
project-manager new FleetView                         # empty shell in that project
project-manager new FleetView "audit pass"            # ...labelled
project-manager new FleetView "audit pass" --claude   # ...running Claude, permissions bypassed
project-manager new FleetView -c codex                # ...running something else
project-manager rename 3bb1633d "a better name"       # relabel any terminal, new or old
```

The label is a positional argument or `-n`, whichever reads better at the call site. `--claude`
expands to `claude --dangerously-skip-permissions` — the fleet runs that way by convention, so it is
one flag rather than a string every caller retypes. `-c` takes any other command; the two are
mutually exclusive.

**`new` waits for the tmux session before it types.** `/new` returns as soon as the *card* exists,
but keystrokes go to the session, which comes up a moment later — type into that gap and the command
vanishes with no error. It polls `canOpen` (the snapshot's authoritative "this instance has the
session" flag) and then leaves a beat for the shell to draw its first prompt. If the session never
arrives it reports that the card was created and nothing was typed, rather than implying both.

Renaming is safe to do at any time: `name` is display-only, and every selector that matters (`show`,
`send`, `choose`) also takes the id, which does not change.

## Handing work to a subagent

```bash
project-manager subagent "重跑 07 号任务的评分并汇报差异"      # in your own project, Claude
project-manager subagent --codex "把这个目录的 CSV 合并"        # Codex instead
project-manager subagent -p FleetView "..." -n "scoring"      # elsewhere, named
```

It opens a card, starts the agent, waits for it, and delivers the task. The project defaults to
**your own** — a subagent belongs to the work that spawned it — and the card is named after the task,
because a board of `FleetView-7` says nothing about which subagent is which.

**It prints the new terminal's full uuid**, on every path including the failures — the card exists
either way, and one you cannot name is one nobody can finish by hand. That uuid is what `show`,
`send`, `check` and the HTTP API all take, so a subagent is addressable the moment it is made:

```bash
SUB=$(project-manager subagent --id "重跑 07 号任务的评分")   # uuid alone on stdout
project-manager show "$SUB" -l 40                            # watch it
project-manager send "$SUB" "改用 v2 的 rubric"               # steer it
```

With `--id` the uuid is the only thing on stdout and the status line moves to stderr, so `$(...)`
captures it cleanly. Without it, the uuid is in the status line.

**Delivery is verified, not assumed**, and that is the whole difficulty. Three things go wrong
between "opened a terminal" and "the agent is working on it", all of them silent:

- **The readiness signal fires too early.** FleetView flips a card off `shell` when the agent's
  SessionStart hook arrives (~2.7s for Claude), but the TUI is still drawing its banner then and
  drops keystrokes. A task sent on that signal alone vanishes — measured: the prompt never appeared.
- **Codex never leaves `shell` at all.** It skips hooks it has not been told to trust, so waiting for
  a status change hangs for the full timeout while Codex sits visibly idle at its prompt.
- **`/type` can lose the Return.** Codex mid-banner takes the text and drops the Enter, leaving the
  task typed in the composer and never run — which on the board looks like an agent ignoring you.

So the command types the task, reads the pane back to confirm it arrived, retypes it if not, and
presses Enter again if it is sitting unsent. It checks before each retry, so a slow start does not
become the same task queued five times — a delivered task appears exactly once in the transcript.

If it still cannot land it, it says so and gives you the command to finish by hand rather than
leaving a card that looks like it was briefed.

## Sending, and knowing it arrived

`send` does not just type: it waits for FleetView to confirm the prompt **left the agent's input box**
and prints which of these happened —

| Output | Meaning |
|---|---|
| `sent to X — submitted` | seen in the composer, then seen leave it: the agent has it |
| `sent to X — Enter pressed, not verified` | short text (a menu digit), a plain shell, or the text never showed up to be checked |
| `sent to X — another input reached it before…` | something else typed into that terminal meanwhile; check with `show` |
| *exit 1:* `typed into X but it did NOT submit` | the text is sitting in its input box. `project-manager key <id> enter` |

Why it needs checking: text followed at once by Enter reads to **Codex** as a paste, and its
paste-burst guard turns that Enter into a newline — the prompt sits in the composer looking sent.
Claude drops it too on long text. FleetView leaves a gap, looks, and presses Enter again if the text is
still there (up to 4 times); against an older FleetView (a peer on another Mac) the CLI does the same
check itself. So a `send` that exits 0 has either landed or says plainly that it could not tell.

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
  `project-manager show <id> -l 400` to read recent turns inline. For a *past* conversation or one
  whose terminal is gone, use the history commands below (`session <card id>` works too).
- **Pick up earlier work**: `projects` → `history <project>` → `memory <project>` → `session <id>`
  → `--files` (see below).

## Looking back: the user's project history

When the user refers to earlier work — "我最近做了 qwen fancy web", "find the chat where we fixed
the rubric", "where's that session file" — read it **one level at a time**. Each level is capped and
ends with the command for the next one down. Do not `cat` transcripts: one is often 40 MB.

```bash
project-manager projects                     # L0  which projects, most recent first
project-manager history qwen_fancy_web       # L1  its conversations + transcript paths
project-manager session 01a0da0b-e436        # L2  that conversation, one line per turn
project-manager session 01a0da0b-e436 -t 19  # L3  turn 19 in full
project-manager search rubric 权重 -p qwen   # or jump straight to where something was said
```

- **Stop at the level that answers the question.** "What was I working on" is L0. "What did we do in
  project X" is L1 plus maybe one L2. Only go to L3 for what was actually said in a turn.
- **Projects come from where conversations ran**, not from the FleetView board: a project removed from
  the board still has its history, and conversations started in a plain terminal are included. Names
  are forgiving — `history "qwen facy web"` finds `qwen_fancy_web` and says so.
- **Ids**: L1 prints a short id per conversation (Claude: 8 characters; Codex: 13, since Codex ids
  share their first 8 across a batch started in the same minute). `session` also takes a FleetView
  card id — live or removed — or a transcript path.
- **Turn numbers** count what the user typed, not injected messages (task notifications,
  continuation summaries), and are the same in `session`, `search` and `-t`, so `search`'s `t19` is
  `session <id> -t 19`.
- `history` and `projects` hide subagent threads (folded into their parent's count), `claude -p` /
  `codex exec` runs and `/tmp` scratch dirs; `-a` shows them.
- A conversation whose file Claude has since deleted still reads from FleetView's index; `session`
  marks it `[deleted]` and gives no resume command. Otherwise it prints the exact `claude --resume` /
  `codex resume` line.
- **Local only**: this reads the transcripts and FleetView's search index on *this* Mac, so it refuses
  `-u`. For another Mac's history, run it there.
- Transcripts hold whatever the user typed, secrets included. Quote only what the task needs.

### Coming back to earlier work: finding the actual files

"The files are in some old project" is the usual shape of the request, and the conversation is the
map to them. What worked, in order, when asked to compare two past projects' task sets:

```bash
project-manager projects                                # spot both projects
project-manager history "agent last exam"               # its conversations — and whether it has memory notes
project-manager memory "agent last exam"                # notes a previous agent left: data locations, known gaps
project-manager session be0758e9                        # the outline; the last reply is often the conclusion
project-manager session be0758e9 -t 1-4                 # the turns that matter, in full
project-manager session 6d837b28 --files                # where its deliverables were written
project-manager search 30 交付 -p qwen_fancy_web --prompts   # where the final set ended up
```

- **`--files` beats reading replies for "where is it".** Deliverables are what a session wrote, and
  the tool calls say exactly where; replies paraphrase. It covers subagent threads too. Paths put
  there by shell commands (downloads, `cp`, redirects) are best-effort and listed separately.
- **Later wins.** When several sessions touched the same set, the newest one's `--files` and last turns
  say where the final version is — earlier copies (`stable_tasks/`, `fix1/`…) are usually superseded.
- **Codex reads are not tracked** (it reads through shell commands); Codex writes are.
- Point subagents at concrete paths once found, rather than at the project — history is for finding,
  the files themselves are for reading.

### Opening a project from ~/PycharmProjects

```bash
project-manager open codesense                  # on the board (no-op if it already is)
project-manager open codesense --claude -n "audit"   # …with a Claude terminal running in it
```

`new <project>` only knows projects already on the board; `open` takes any folder directly inside
`~/PycharmProjects` (fuzzy name), which the server enforces. It goes through the API, so `-u` works.

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

See the [[fleetview-peers]] skill for the full remote rules (what does not cross the network — the web
terminal view, `log` paths, `ask`, the history commands — and the safety notes: there's no auth, so
`send` lands in someone's live, permission-bypassed session). The CLI `open` command does work remotely.

## Cautions

- `send`/`choose`/`key` **inject real keystrokes** into a live session. Before acting on a terminal
  that is `working`, prefer to `show` it first — don't interrupt an in-progress turn unless asked.
- **Read `send`'s verdict and exit status** — `submitted` means the agent has it; exit 1 means the
  text is stuck in its input box. Don't write `send … && echo ok` and trust it: a failed send just
  skips the `&&`, so it looks silent. (This is how the zsh `$PM` bug above hid — the send returned
  127 and nothing was injected.) `choose` sends a single digit, which is not verified; `show` after it.
- A terminal must have a live tmux session to inspect/drive it (`ls` shows it; closed ones can't be
  read). `send`/`choose` do nothing useful on a closed terminal.
- `check` is heuristic (it scans recent output). Confirm by reading `show <id>` before concluding a
  session truly failed. A user Ctrl-C is deliberately **not** treated as an error.
- Don't `rm` a terminal unless explicitly asked — it ends that agent's session.
