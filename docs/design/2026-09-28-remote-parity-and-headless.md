# Remote parity for project-manager, and a headless FleetView

| | |
|---|---|
| **Date** | 2026-09-28 |
| **Status** | Shipped; deployed headless on the Mac mini (`100.109.51.92`, Tailscale) |
| **Supersedes** | the "local only" rule for history in `2026-09-26-send-and-project-history.md` |

## What changed

Two things, because the first could not be deployed without the second.

1. **Every `project-manager` command works against another instance.** The terminal commands already
   did (they are HTTP calls). The ones that read files — `projects`, `history`, `session`, `search`,
   `memory`, `log`, and the new `cat` — used to refuse `-u`, because answering from the caller's disk
   would describe the wrong machine. They now run on the target machine.
2. **FleetView runs without a screen.** The Mac mini is reached only over SSH, and FleetView could not
   start there at all.

## 1. Running the command where the files are: `GET /pm`

`/pm?argv=<JSON>` makes FleetView run `project-manager <argv>` on its own machine and answer
`{code, stdout, stderr}`; the CLI prints that and exits with the code. The script is bundled into the
app (`Contents/Resources/project-manager`, by `package_app.sh`) and falls back to the checkout.

**Why the script and not a Swift port.** The history commands encode a lot of rules — turn numbering
that skips injected prompts, project attribution, Codex id lengths, the index's CJK query rewrite. A
Swift copy served over HTTP would be a second implementation of all of it, and the two would drift.
Running the same file on the other machine makes the remote answer identical by construction.

Details that were not obvious:

- **Only the file-reading commands** are accepted (`PMRunner.commands` = `REMOTE_RUN` in the script).
  Everything else already has an HTTP route and no reason to be spawned from the network.
- **"Your project" is resolved on the caller's side.** `history`/`memory` with no project, and
  `subagent` with no `-p`, used to mean the card you run on. Run by FleetView over there, the script
  has no card and its cwd is `~`, so the client resolves its own project name and passes it; the
  remote matches that name. `whoami` always reads the local instance for the same reason.
- **Hints carry the `-u`.** `next: project-manager session …` copied from remote output would run
  locally. The client sends its URL as `origin`; the served script prefixes every hint with it.
- **`log -c`/`-f` travel in 4 MB pieces** via a hidden `log --bytes-from N`, cut at line ends (or a
  UTF-8 boundary for a single longer line). `-f` holds back an unterminated last line — the agent is
  mid-write, and printing half a record then the rest reads as two. Verified on the mini: `log -c`
  over Tailscale is byte-identical to the file (same SHA-1), and a line appended in two halves came
  out of `-f` as one.
- **`cat`** exists for the other machine. History hands over paths (memory notes, `--files`), and
  without it following one from another Mac ended at a path you could not open.

**No authentication — the user's call.** An HMAC-signed scheme (only this Mac may reach the others) was
designed and dropped on request: the LAN and tailnet are trusted. Consequence worth stating plainly:
anyone who can reach port 8080 can read that machine's history and any file its user can, on top of
the terminal control they already had.

## 2. Headless

**The failure, measured.** Started over SSH on the mini (whose console user is someone else), the
FleetView binary runs, sits in `-[NSApplication run]`'s event loop, and `applicationDidFinishLaunching`
never fires — no window server, so no launch. No web server, no hooks, no `~/.fleetview` — and no error.

**The fix.** `main.swift` checks `Headless.wanted` (`--headless`, or `CGSessionCopyCurrentDictionary()`
is nil; `--gui` overrides) and, if so, never creates the NSApplication: `Headless.run()` starts
everything that is not a window — `AppStartup.start`, the same function the desktop app now calls — and
runs the main run loop. SIGTERM/SIGINT/SIGHUP stop it the way Quit does (`AppStartup.stop`): state
saved, terminals left running, reattached on the next start.

**Terminals without windows.** A `TerminalWindowController` was also what created the tmux session: its
pty ran `tmux new-session -A`. AppState now holds terminals as `TerminalHost`, and in headless mode
that is a `HeadlessTerminal`: the identical session (same socket, config, size, environment, login
shell) created with `new-session -d`. Typing goes through `RemoteServer.sendText`, the web's path. A
window learns its shell exited from the pty; headless has none, so it polls the cached `liveSessions`
every 2 s (a 3 s tick measured just over 6 s to "exited" in the worst case).

**Permissions (TCC).** macOS attributes an agent's file access to the responsible process. From an SSH
login that is the remote-login service, which on the mini has Full Disk Access; from launchd it would
be FleetView itself, and granting it anything needs a screen. Measured on the mini: a shell inside a
headless FleetView terminal reads `/Library/Application Support/com.apple.TCC/TCC.db`, which needs
FDA, exactly as a plain SSH shell does. So: start it from SSH, inside a tmux session on the default
socket so it outlives the connection. It does not survive a reboot; that is the price. The desktop app
is unaffected — same bundle, same signature, same grants.

## Verified on the Mac mini (from this Mac, over Tailscale)

`peers` finds it; `open -t`, `new`, `send`, `tail`, `show`, `rm`, `subagent --no-wait` (resolving the
same-named project) work; `exit` in a shell turns the card `exited`; a restart reattaches the live
session; `projects`, `history`, `session` (`-t`, `--files`), `search`, `memory`, `cat`, `log`/`-p`/`-c`/`-f`
answer from the mini's disk; the dashboard renders in Chromium with no JS errors; `/conversation`
parses; `/open` starts ttyd and its port answers from this Mac. Not exercised: a real agent session
there — neither `claude` nor `codex` is on that account's PATH — so status from live hooks was checked
by feeding `hook.sh` a SessionStart payload by hand.
