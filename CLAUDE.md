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
| `Tests/FleetViewAuditTests/` | `swift run FleetViewAuditTests` (not `swift test` — see Package.swift) |
| `docs/design/` | design notes, dated |
| `scripts/`, `examples/` | **ignored by default** — see below |
| `~/.fleetview/` | all runtime state: `state.json`, logs, `ui/panel.html`, `sessions/`, `search.db` |

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
- **The user runs a long-lived production FleetView.** A second instance steals its hook events.
  Don't launch the app to test — build (`swift build`), and let the user deploy
  (`./scripts/package_app.sh --install`, which needs the running app quit first).
- **Quitting FleetView does not kill the terminals.** `RemoteServer.stopAll()` stops the web
  servers but leaves the tmux sessions on the `fleetview` socket running; only Remove Terminal
  destroys a session. So restarting the app is safe.
- Two agent backends, two transcript formats: Claude
  `~/.claude/projects/<slug>/…` (branches via `parentUuid`), Codex
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (branches via `forked_from_id`). Anything that
  reads history has to handle both, or say which one it handles.
