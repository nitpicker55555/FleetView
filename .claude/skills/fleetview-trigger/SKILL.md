---
name: fleetview-trigger
description: >-
  Set up work that FleetView runs on its own, later or repeatedly, with no card having to stay alive
  for it: a fleet trigger held by the FleetView process, fired by a cron schedule, an interval, a
  one-off time, a file or folder changing, a check command starting to succeed, or a fire from any
  other program — and running any command, typically `project-manager subagent` to open a new agent
  (or resume a given conversation), hand it a prompt, and remove the card once it has answered. Use
  whenever the user wants something to happen at a time or on an event and keep happening after this
  conversation ends ("every day at 9 open an agent and …", "每天早上…", "定时…", "when this file
  changes …", "once the build is green …", "remind/resume X tomorrow at …"), and to list, fire, pause,
  read the log of, or remove such triggers. Not for a reminder inside this session only — that is
  your own CLI's schedule, and it dies with the card.
---

# fleetview-trigger — work FleetView runs on its own

A fleet trigger belongs to **FleetView, not to a card**. The FleetView process keeps it in
`~/.fleetview/fleet-triggers.json`, checks it every two seconds and runs its command itself. Close
every card, quit this agent, restart FleetView: the trigger carries on. That is the difference from
your CLI's own crons and background tasks, which live in your process and stop with it.

Everything goes through `project-manager trigger`. Add `-u <url>` to work on another Mac's FleetView.
Each Mac runs only its own triggers.

## Add one

```bash
project-manager trigger add NAME  <when>  --run 'COMMAND'  [--cwd DIR] [--timeout DUR]
```

Give exactly one `<when>`:

| option | fires | notes |
|---|---|---|
| `--cron '0 9 * * *'` | on a five-field cron in this Mac's local time | `*/15 * * * *`, `30 8 * * 1-5`, … |
| `--every 30m` | every interval | 10 s minimum; `90`, `30s`, `10m`, `2h`, `1d` |
| `--at '2026-11-01 09:00'` | once | also `'09:00'` (the next one) or `'+45m'` |
| `--watch PATH` | when a file changes, or anything directly inside a folder | looks every 5 s (`--interval`) |
| `--check 'CMD'` | when CMD starts exiting 0 | once per false→true, looks every 60 s (`--interval`) |
| `--manual` | only when fired | `trigger fire ID`, or `POST /fleet-triggers/fire?id=ID` from any program |

Every trigger can also be fired by hand, whatever its kind.

How the command runs:
- `--run` goes through `zsh -lc`, so it gets the login PATH (`project-manager`, `claude`, `codex`, brew).
- It runs in your home folder unless you give `--cwd`.
- It has a one-hour timeout unless you give `--timeout`. When a run times out, it and its children are stopped.
- If the previous run is still going when the trigger fires again, that fire is skipped and written to the log.

The command does **not** run inside a card, so `FLEETVIEW_TERM_ID` is not set. Name the project
with `-p` when the command calls `project-manager subagent`. These variables are set for it:

- `FV_TRIGGER_ID`, `FV_TRIGGER_NAME`
- `FV_TRIGGER_REASON`: one of `cron`, `every`, `at`, `watch`, `check`, `manual`, `catch-up`
- `FV_TRIGGER_SOURCE`: the card that set it up

When you add a trigger from inside a card, that card is recorded as its **source**. The board's ⚡
list shows the source's uuid, and "Restore card" brings that card back in its latest conversation.

## The usual command: an agent does a job and goes away

`project-manager subagent` takes three options that make it a one-line job:

- `--rm` waits for the reply, prints it, and removes the card. The card stays on the board if the
  turn ended on a question, timed out (`-t SEC`), or the card was already open beforehand.
- `--wait` waits for the reply and prints it, and keeps the card.
- `--resume SESSION` gives the task to an existing conversation instead of a new agent. FleetView
  restores it into its card first, and the task is only typed once that agent is up.

```bash
# Every weekday at 09:00: a fresh agent reviews yesterday's commits, then its card goes.
project-manager trigger add morning-review --cron '0 9 * * 1-5' \
  --run "project-manager subagent -p FleetView --rm -t 1800 'Review yesterday’s commits on main and list anything risky. Write the list to ~/reviews/\$(date +%F).md'"

# Every night: carry on in a particular conversation, then close its card.
project-manager trigger add nightly-continue --cron '30 23 * * *' \
  --run "project-manager subagent --resume 2cb10637 --rm 'Continue where we left off: process today’s new entries.'"

# When a file lands in a folder.
project-manager trigger add inbox --watch ~/inbox \
  --run "project-manager subagent -p home_puzhen --rm 'New files in ~/inbox: sort them into ~/docs.'"

# Once, in 45 minutes.
project-manager trigger add check-run --at '+45m' --run "project-manager subagent -p FleetView --rm 'Is the harbor run finished? Summarise it.'"
```

Any program works, not only agents: `--run './backup.sh'`, `--run 'curl -X POST …'`. Quote the
command for the shell you type it in. Use single quotes inside double quotes, and escape `$` that
should expand when the trigger runs, not now.

## Look after them

```bash
project-manager trigger ls            # when, next run, last result, source card uuid (+ --json)
project-manager trigger log ID [-n 200]   # every run: header, output, exit line
project-manager trigger fire ID       # run it now
project-manager trigger pause ID      # stop it firing (resume ID to start again, from now)
project-manager trigger restore ID    # bring back the card that set it up
project-manager trigger rm ID         # remove it; stops a run that is still going
```

`ID` is the 8-character id, a prefix of it, or part of the name. The same list is in the desktop
toolbar (⚡) and in the web dashboard header. There you can run, pause, remove, and restore the source card.

## Things to know

- **Missed runs.** A time-based run that fell while FleetView was not running fires once when
  FleetView comes back, if it is less than 12 hours late (reason `catch-up`). Later than that, it is
  skipped and the schedule goes on from now. A Mac that was asleep fires on waking.
- **`--check` is edge-triggered.** It fires when the command goes from failing to succeeding, not
  on every look while it succeeds. To fire again, make the condition fail again, for example by having
  the run delete the flag file the check looks for.
- **`--watch` is not recursive.** It sees a folder's direct entries (added, removed, resized,
  re-saved), not changes deeper down.
- **Clean up.** A one-off `--at` stays in the list after it has run. Remove it, and remove any trigger
  the user no longer needs. Every add, fire, finish and remove is in FleetView's audit log
  (`fleetview.fleet_trigger.*`).
- The HTTP API, for other programs: `GET /fleet-triggers`,
  `POST /fleet-triggers/{add,rm,fire,pause,restore}`, `GET /fleet-triggers/log`. `add` takes JSON
  `{name, when:{kind, cron|every|at|path|check, interval?}, run, cwd?, timeout?}`. Like the rest of
  FleetView's API it is open to the LAN and tailnet without auth.
