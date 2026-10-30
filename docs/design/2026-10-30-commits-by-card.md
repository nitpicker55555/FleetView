# Which card made which commit

Follows [the file window's history](2026-10-26-file-window-history.md). Asked for on 2026-10-30: "FleetView 是
project based 的，又切分出了很多终端卡片，所以我希望还能方便的看出每个终端提交的 commit"; some cards commit
to a repository that is not their project's, and those commits have to be shown and opened too; a duplicated card
shares its parent's history, and a commit in it belongs to the parent only; and the card itself should have a
button that lists its commits.

## What it shows

- **On a card**, once its agent has committed: a chip with a branch glyph and how many commits. A click opens the
  project's file window on the 提交 page, listing that card's commits. The card's menu has the same, "这张卡的提交".
- **On the 提交 page**, each commit names the card that made it, in place of the author (on this machine the author
  is the same person on every commit). A card no longer on the board is drawn faded. Clicking the name lists that
  card's commits.
- **A card's commits** are listed across every repository it committed to, newest first. A commit that is not in
  the window's own repository says which one it is in; clicking it opens it there, diff and all.
- **The repository menu** has a second section, "本项目的卡片提交过的其他仓库": repositories outside the project
  that its cards committed to (on this machine, FleetView's cards to `env-agents-last-exam`, home_puzhen's to
  `puzhen-pad`). They are read like the project's own, read-only, and nothing in the tree or the watcher touches
  them. Worktrees of the project's repository (`FleetView-redesign`, `FleetView-files`) are the same repository —
  they share its commits — and are not listed separately.

## How a commit is put on a card

Nothing in git records which card made a commit, so it comes from the agents' transcripts (`CommitLedger`):

- Every `git commit` an agent runs is a tool call, with the time it was sent and the time it was answered, and
  the directory it ran in (the record's cwd, then the `cd`s and `git -C` in the command, with the variables the
  command assigns). Also counted: `git merge`, `cherry-pick`, `revert`, and `gh pr merge`, whose merge commit
  GitHub makes during the call. Not `merge-base` or `commit-tree`, which only read, and not `rebase` or `pull`,
  which rewrite or bring in commits other cards wrote.
- A commit committed (committer time, not author time) inside that span, in that repository or a worktree of it,
  is the call's. When the output names the commit (`[main abc1234]`), that wins. When two calls' spans hold the
  same commit, the narrower one gets it.
- The output alone would not do. Agents commit with `-q` and read the result back with `git log`: of 246 commit
  calls over two weeks, none printed `[branch sha]`. By time and place, 136 of 294 calls landed on exactly one
  commit, 9 on several, and no commit was claimed by two calls. The rest landed on none: nothing to commit, a
  hook refused it, or the commit was amended since. Another 53 ran in temporary folders that are gone.
- The conversation is put back on its card with the audit log's `transcript_bound` records — a card goes
  through several conversations, a `/clear` or a reopen that could not resume, and the board keeps only the
  last — then the drawer of removed cards, then the board. A card belongs to a project by id, or by its working
  directory being inside the project, because a project closed and opened again has a new id.
- **A duplicated card.** `--fork-session` copies its parent's records into the new transcript, tool call ids
  included (checked: the first three ids of a fork were all in its parent, whose file was created seven days
  earlier). The forks SessionForge and treeflow write copy them too. So the ledger keeps one row per call id,
  from the oldest file it appears in: the parent keeps its commits, and a commit made after the fork appears only
  in the fork and is the fork's. Of 1,344 calls read, 191 were such copies.
- Repositories under `/tmp` or `/var/folders` are left out of every list and count — the throwaway repositories
  agents build to test against (one FleetView card had eight under its scratchpad).

Checked on FleetView's own repository: 37 of the last 40 commits were put on a card, each on the right one —
this session's on `FleetView-1` and none on its duplicate `FleetView-1 ⑂`, the file window's on the removed
`FleetView-git`. The three left were GitHub merges made before `gh pr merge` was counted.

## What it costs

Every screen reads `~/.fleetview/commits.db` and nothing else; git is not run to draw a list, a chip or a menu.

- **Calls.** The transcripts are read by byte offset like the search index, but on offsets of their own and in a
  file of their own, so the ledger cannot disturb the index. The first pass reads every transcript once (11,960
  files in about 25 s on this machine, at utility priority; the wanted lines are found by byte search before any
  JSON is decoded). Every pass after reads what was appended.
- **Commits.** A call is matched once, half a minute after it was answered: one `git log --all --since --until`
  per repository for all of its new calls, and the result written down (`made`). The whole history — 1,148
  calls in 21 repositories, 723 commits — took 0.9 s.
- **Cards.** The audit log's `transcript_bound` lines are copied into the file as the log grows (`binding`), read
  by offset too: the log is 269 MB, and only today's file grows.
- **Asking.** One card's commits, the cards of a page of commits, every card's count: under 5 ms each, on a read
  connection of its own that does not wait for a pass in progress. What is written down is shown at once; the
  ledger then catches up (about 0.4 s, most of it listing the transcript folders) and the screen is redrawn if
  anything changed. Passes run at launch, with the search index's five-minute refresh, five seconds after a run
  ends, and when the 提交 page is shown.

The first version matched at the time of asking: a `git log` per call. Git runs two at a time here, shared with
the file window's own status, log and diffs, so counting the board's cards — 765 calls, two git processes each —
queued everything behind it, and the window crawled.

## Not covered

- Commits made by hand in a card's shell are not in any transcript, so they are not put on a card. Neither are
  commits made by a script the agent ran (`./release.sh` that commits inside).
- The web dashboard has no commit history yet, so the git chip is on the desktop board only.
