---
name: card-git
description: >-
  See what one FleetView card (agent terminal) has done to code: every commit its agent made — in
  whatever repository, the project's own, a worktree or a sibling checkout — and the files it wrote
  that are still uncommitted, via `project-manager commits <card>`; and the other way round, which
  card (by uuid) wrote a given uncommitted file or each uncommitted file in a folder, via
  `project-manager writers <path>`. Use whenever asked what a card or another agent committed,
  changed, or left uncommitted ("看看 X 卡片提交了什么", "X 改了哪些文件还没提交", "这个文件的改动是哪个卡片
  引入的", "who changed this file", "review what the X terminal did", "which commits came from that
  agent", "did it commit its work"), before reviewing, merging or reverting another agent's work, or
  when tidying up after a card.
---

# card-git — a card's commits and uncommitted work

A FleetView project is many cards, and git cannot say which of them made a commit. FleetView works it
out from the agents' own transcripts (its commit ledger): every `git commit`, `merge`, `cherry-pick`,
`revert` and `gh pr merge` call, matched by time and repository to the commit it made; and every file
an Edit / Write / MultiEdit / NotebookEdit call or a Codex patch wrote, checked against `git status`.
`project-manager commits` asks for that.

```bash
project-manager commits <card>           # name substring or id prefix, as everywhere in project-manager
project-manager commits <card> -n 0      # every commit, not just the newest 30
project-manager commits <card> --json    # {id, name, project, commits[], uncommitted[]}
project-manager -u <host> commits <card> # a card on another Mac (answered there)
```

Output, in order:

- **uncommitted** — one block per repository: the files this card's agent wrote last that git still
  reports as changed (`A` new, `M` modified), with the repository's path.
- **commits** — newest first: short sha, when, the repository (when more than one), subject.

The other way round — which card wrote a file:

```bash
project-manager writers <file>           # the card (uuid, name) that last wrote it, and when
project-manager writers <folder>         # every uncommitted file under it, each with its last writer
project-manager writers -a <file>        # every card that wrote it, latest first
project-manager writers --json <path>    # {repo, path, files: [{path, status, writers: [{id, name, removed, at, transcript}]}]}
```

A line reads `M Sources/x.swift  ← 4ddb2613-…  FleetView-1  10-30 14:22`: git's mark (`M`, `A`, `?` new,
`D`), the file, the card's full uuid and name (`(removed)` if it is no longer on the board), and when it
last wrote the file. `← no agent wrote it` means a shell command or a person changed it. The uuid is what
`project-manager` takes everywhere (`project-manager show <uuid>`, `commits <uuid>`).

Then look with plain git, read-only:

```bash
git -C <repo> show <sha>                 # one commit
git -C <repo> show --stat <sha>          # just its files
git -C <repo> diff -- <file>             # an uncommitted file's change
```

In `--json`, `committed` is a Unix time and `repo` is the repository's top level.

## How to read it

- **A duplicated card** carries its parent's history; commits made before the duplicate stay the
  parent's, and only what the duplicate did afterwards is listed under it.
- **A file is credited to the last card that wrote it.** If two cards edited the same file, only the
  later one lists it as uncommitted.
- **Shell edits are invisible.** A file changed by `sed -i`, a script or a generator is not in any
  transcript, so it is not listed as the card's — `git -C <repo> status` shows everything uncommitted.
  Likewise a commit made by hand in the card's shell, or by a script the agent ran, is not credited.
- **The last half minute is not in yet.** A commit is matched about 30 s after the call that made it was
  answered; ask again if the agent has only just committed.
- **Repositories under `/tmp`** (throwaway test repositories) are left out.
- The same lists are in the desktop app: the branch chip on the card, or the card's menu → 这张卡的提交,
  opens them in the project's file window, diffs and all.
