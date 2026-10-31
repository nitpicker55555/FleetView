# FleetView

A macOS app that runs a fleet of agent terminals (Claude Code / Codex CLI) as cards on a board,
mirrors them to a LAN web dashboard, and lets you open any node of a past conversation.

## Where things go

The repo holds **the program**. Everything a *running* FleetView produces or that you write to
operate one lives outside it, under `~/.fleetview/`. Keeping that line clean is what stops
operational files from being swept into a commit by whoever runs `git add -A` next.

| | |
|---|---|
| `Sources/FleetView/` | the app (SwiftUI, AppKit, the embedded HTTP server, the web page) |
| `Sources/FleetViewAudit/` | the audit engine — Foundation only, deliberately no SwiftUI/AppKit/AppState |
| `Sources/FleetViewFiles/` | the file window's logic: exact text round-trips, saving, read-only git — Foundation only |
| `Editor/` | the file window's editor page (CodeMirror); `Editor/build.sh` rebuilds `Editor/dist/`, which is committed |
| `Tests/FleetViewAuditTests/` | `swift run FleetViewAuditTests` (not `swift test` — see Package.swift) |
| `docs/design/` | design notes, dated |
| `docs/问题与修复/` | incident records, dated: symptom, root cause, fix, how it was verified (index in its README) |
| `scripts/`, `examples/` | **ignored by default** — see below |
| `~/.fleetview/` | all runtime state: `state.json`, `archive.json` (removed cards), `triggers.json` (agents' last-reported crons), `fleet-triggers.json` (triggers FleetView itself runs, logs in `logs/fleet-triggers/`), logs, `ui/panel.html`, `sessions/`, `search.db` |

### scripts/ and examples/ are whitelisted, not open

Both directories hold two different kinds of thing, and only one of them belongs in git:

- **Ships with FleetView** — `scripts/package_app.sh`, `scripts/project-manager`,
  `examples/fleet-panel.html`. These are whitelisted in `.gitignore` by name.
- **Operational** — scripts and panels written to babysit a running fleet (fleet monitors,
  auto-recover daemons, one-off dashboards). Not part of the program.

So `.gitignore` ignores the contents of both directories and adds the product tooling back with
`!` lines. **Anything new you write there is ignored automatically.** If something you add really
is part of FleetView, add a `!` line for it — that explicit act is the point.

Need scratch space inside the repo? Use `.scratch/` (ignored). Prefer your session's scratchpad
directory outside the repo when you have one.

## Conventions

- **Comments explain _why_, not what.** The codebase is dense with rationale — a comment that
  restates the code is noise; one that records the failure that shaped it is what stops the next
  person from re-introducing it. Match the surrounding density.
- **Don't rename persisted keys casually.** `Terminal.subtaskDone` is the "mark" flag; the UI says
  Mark/Unmark but the stored key stays, because renaming it decodes as `false` against every mark
  already in `state.json` and silently clears them. Same care for anything else in `state.json`.
- **A field added to anything already in `state.json` must be Optional.** A default value does not
  help: synthesised `Codable` treats a missing key as an error even when the property has one. This
  has already cost the whole board once — one added non-optional field made every existing row
  undecodable, `Persisted` failed as a unit, `load()` read that as a fresh install and the next save
  wrote the emptiness over every project, terminal and note, with no error anywhere. `Persisted`
  now decodes field by field so a slip costs one field instead of the file, but the rule stands.
  Test the change against a *real* `state.json` that has data in it — an empty one decodes fine and
  proves nothing. See [`docs/design/2026-08-19-state-json-wipe.md`](docs/design/2026-08-19-state-json-wipe.md),
  which also records how the audit log in `~/.fleetview/logs/` was replayed to recover.
- **`package_app.sh` signs with a stable identity, and that is load-bearing.** TCC identifies an app
  by its designated requirement; an ad-hoc signature's *is* the hash of the build, so every install
  used to be a different app and every granted permission died with it. The script uses the
  `FleetView Local Signing` keychain identity when it exists and says out loud when it falls back to
  ad-hoc. After any change to how it is signed, every existing grant has to be **removed and
  re-added** in System Settings — toggling it off and on updates the row but not the `csreq` it is
  matched against, so it stays silently dead. See
  [`docs/design/2026-08-23-tcc-permissions.md`](docs/design/2026-08-23-tcc-permissions.md).
- **The user runs a long-lived production FleetView.** A second instance steals its hook events.
  Don't launch the app to test — build (`swift build`), and let the user deploy
  (`./scripts/package_app.sh --install`, which needs the running app quit first).
- **FleetView also runs headless** — on a Mac with no window server (reached only over SSH, like
  the Mac mini) or with `--headless`: no windows, terminals are detached tmux sessions
  (`HeadlessTerminal`), the web dashboard is the board. AppState reaches a terminal only through
  `TerminalHost`, so anything new it needs from a terminal window has to have a headless answer too.
  Start it from an SSH login, not launchd — see
  [`docs/design/2026-09-28-remote-parity-and-headless.md`](docs/design/2026-09-28-remote-parity-and-headless.md).
- **Quitting FleetView does not kill the terminals.** `RemoteServer.stopAll()` stops the web
  servers but leaves the tmux sessions on the `fleetview` socket running, so restarting the app is
  safe (and so is a self-update, which quits to hand off). The opt-in `closeTerminalsOnQuit`
  setting is the one exception, and it deliberately does not apply to the update handoff.
- **Closing a terminal destroys its session.** Closing the window, Close All Terminals and Remove
  Terminal all kill the tmux session — a card that says "closed" means the agent behind it is
  stopped. The kill is only a hangup, and an agent can survive one (a Claude under `sp-claude` spun
  for 46 hours that way), so `ProcessReaper` writes the pane's processes down before the kill and
  SIGTERM/SIGKILLs whatever is left after it — sparing anything that calls itself a daemon, which
  agents start on purpose to outlive them; see
  [`docs/问题与修复/2026-10-22-agent-outlives-closed-card.md`](docs/问题与修复/2026-10-22-agent-outlives-closed-card.md). Clicking a closed card reopens it and types `--resume` for the session it last had
  (`AppState.reopenTerminal`), which is what keeps that recoverable. `project-manager restore
  <session-id>` does the same from a session id, for a removed card too (`restoreConversation`).
  The only things that reattach to a still-live session are `reconnectLiveTerminals()` on launch
  and showing a hidden window. **Hiding** (`AppState.hideTerminal`, the title bar's 隐藏 button) is
  the non-destructive way to get a window off screen: the window and its tmux client go, the
  session stays, a `HeadlessTerminal` stands in for the window, and the card is marked hidden
  (`windowHidden`, which survives a relaunch) until a click on it brings the window back.
- **Codex keeps its hook trust inside FleetView's block in `~/.codex/config.toml`.** It appends the
  `[hooks.state."…"] trusted_hash` tables after its siblings, which is inside our fence, so
  `CodexHookInstaller.stripFence` must only ever remove our own `[[hooks.*]]` tables. Stripping the
  whole fence untrusted every hook on each launch and Codex stopped reporting without a word — see
  [`docs/design/2026-10-01-codex-worker-hooks.md`](docs/design/2026-10-01-codex-worker-hooks.md).
- **The file window (📁 in a project's header) never takes git's index lock, and never writes a
  file with `Data.write(.atomic)`.** Agents commit in the same repositories all day; porcelain
  `git diff` rewrites `.git/index` even with `--no-optional-locks` (measured), and an agent's commit
  then fails on `index.lock`. Git goes through `GitReader` — read-only commands only — and saves go
  through `FileSave`, which keeps symlinks, hard links, modes and xattrs and refuses to overwrite a
  file an agent changed since it was opened. The web `/save` uses it too. See
  [`docs/design/2026-10-26-file-browser-editor.md`](docs/design/2026-10-26-file-browser-editor.md).
  The editor page is `Editor/` (CodeMirror); change it there and run `Editor/build.sh`. To look at
  the window without launching the app: `FV_SNAPSHOT_FILES=<folder> FleetView --snapshot <dir>`.
- **Two kinds of trigger, and only one belongs to a card.** `AgentTrigger` (the per-card panel) is
  what an agent's own CLI scheduled; it lives in that process and dies with it. `FleetTrigger`
  (`FleetTriggerEngine`, the ⚡ toolbar list, `project-manager trigger`, the fleetview-trigger skill)
  is run by the FleetView process itself — cron, interval, once, file change, a check command, or a
  fire from outside — and outlives every card. It runs its command with `zsh -lc` and no
  `FLEETVIEW_TERM_ID`, in the desktop app and headless alike.
- Two agent backends, two transcript formats: Claude
  `~/.claude/projects/<slug>/…` (branches via `parentUuid`), Codex
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (branches via `forked_from_id`). Anything that
  reads history has to handle both, or say which one it handles.
- **`sp-claude` / `sp-codex` (sub-pool) are the same two agents with a second home.** They run the
  CLI with `CLAUDE_CONFIG_DIR` / `CODEX_HOME` set to a per-session temp dir linked into
  `~/.sub-pool/claude-home` / `codex-home`: settings, hooks, rollouts and the paths hooks report
  all live there, and each CLI resumes only what its own home holds. Go through `AgentHome` (roots,
  `canonical`, `resuming`) rather than spelling out `~/.claude` or `~/.codex/sessions`. Codex hooks
  cannot be trusted under `sp-codex`, so those cards run on the rollout poll — see
  `CodexHookInstaller`.
