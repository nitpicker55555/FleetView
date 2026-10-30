---
name: card-git
description: >-
  Tie FleetView cards (agent terminals) to code, in every direction: which card produced each commit,
  which card produced each uncommitted file change, and what each card has produced — its commits in
  whatever repository (the project's own, a worktree, a sibling checkout) and its uncommitted files —
  by card uuid, via `project-manager repo / writers / commits`. Use whenever asked who or which agent
  made a commit or a change, or what a card committed, changed or left uncommitted ("这个 commit 是哪个卡片
  产出的", "这个文件的改动是哪个卡片引入的", "看看 X 卡片提交了什么", "X 改了哪些文件还没提交", "who made this
  commit", "which agent changed this file", "review what the X terminal did", "did it commit its work"),
  before reviewing, merging or reverting another agent's work, or when tidying up after a card.
---

# card-git — which card produced which commit and which change

A FleetView project is many cards, and git cannot say which of them made a commit. FleetView works it
out from the agents' own transcripts (its commit ledger): every `git commit`, `merge`, `cherry-pick`,
`revert` and `gh pr merge` call, matched by time and repository to the commit it made; and every file
an Edit / Write / MultiEdit / NotebookEdit call or a Codex patch wrote. `project-manager` asks it.

| You want | Run |
|---|---|
| each commit of a repository, and which card produced it | `project-manager repo [path]` |
| which card produced one commit | `project-manager repo [path] --sha <sha>` |
| which card produced an uncommitted file change | `project-manager writers <file>` |
| each uncommitted file under a folder, with its card | `project-manager writers <folder>` (or `repo`, for the whole repository) |
| everything one card produced: commits and uncommitted files | `project-manager commits <card>` |

`<card>` is a name substring or uuid prefix, as everywhere in `project-manager`; `[path]` is any file or
folder inside the repository (default: the current one). Cards are named by their **full uuid** and
name — `4ddb2613-e53f-4ace-99cb-19193183e14a  FleetView-1` — and `(removed)` marks one no longer on the
board. The uuid is what every other `project-manager` command takes.

## By repository: `project-manager repo`

```bash
project-manager repo                     # this repository: uncommitted files, then the newest 30 commits
project-manager repo ~/proj -n 100       # another one, more commits
project-manager repo --sha 2154aa5       # one commit
project-manager repo --json              # {repo, uncommitted: [...], commits: [{sha, committed, author, subject, card?, transcript?}]}
```

Each commit is followed by `← <uuid>  <name>` — the card that produced it — or `← no agent made it`
(made by hand, by a script, or on GitHub, e.g. a pull request merged in the browser). Each uncommitted
file reads `M path  ← <uuid>  <name>  <when it last wrote it>`.

## By file: `project-manager writers`

```bash
project-manager writers <file>           # the card that last wrote it, and when
project-manager writers <folder>         # every uncommitted file under it, each with its last writer
project-manager writers -a <file>        # every card that wrote it, latest first
project-manager writers --json <path>    # {repo, path, files: [{path, status, writers: [{id, name, removed, at, transcript}]}]}
```

git's marks: `M` modified, `A` added, `?` new (untracked), `D` deleted. `← no agent wrote it` means a shell
command or a person changed it.

## By card: `project-manager commits`

```bash
project-manager commits <card>           # its uncommitted files (by repository), then its commits
project-manager commits <card> -n 0      # every commit, not just the newest 30
project-manager commits <card> --json    # {id, name, project, commits: [...], uncommitted: [{repo, files, untracked}]}
```

## Then look with plain git, read-only

```bash
git -C <repo> show <sha>                 # one commit
git -C <repo> show --stat <sha>          # just its files
git -C <repo> diff -- <file>             # an uncommitted file's change
```

All three commands add `-u <host>` for a card on another Mac (answered there).

## How to read it

- **A duplicated card** carries its parent's history; commits and files written before the duplicate
  stay the parent's, and only what the duplicate did afterwards is credited to it.
- **A file is credited to the last card that wrote it.** `writers -a` shows the earlier ones.
- **Shell edits are invisible.** A file changed by `sed -i`, a script or a generator is not in any
  transcript: it shows as `no agent wrote it` and is missing from `commits <card>`. A commit made by
  hand in a card's shell, or by a script the agent ran, is likewise not credited.
- **The last half minute is not in yet.** A commit is matched about 30 s after the call that made it was
  answered; ask again if the agent has only just committed.
- **Repositories under `/tmp`** (throwaway test repositories) are left out of a card's lists.
- The same is in the desktop app: the branch chip on a card (commits · ● uncommitted files), or the
  card's menu → 这张卡的提交; and in a project's file window, the 提交 page names each commit's card.
