# The file window's history: commits, what each changed, and repositories inside a project

Follows [the file window](2026-10-26-file-browser-editor.md), whose design left the 提交 / 对比 pages
of the first git mockup (`.scratch/git-viewer-mockup.html`) for later. This is that later, for the
desktop window. Asked for on 2026-10-26: "为啥现在没有显示分支，看不到 commit".

## What it shows

**A third page in the sidebar, 提交**, beside 文件 and 搜索:

- The repository's commits, newest first, a hundred at a time ("load earlier ones" for more): subject,
  short sha, author, when, files and lines changed, and a Claude / Codex badge when a
  `Co-Authored-By` trailer names one. Refs (`HEAD → main`, `origin/main`, tags) beside the commit
  they point at.
- Above them, when there is anything uncommitted, a row for the working tree: "未提交 · N 个文件".
- A branch menu at the top: every local and remote branch, newest first. Choosing one lists *its*
  commits — it does not check anything out. On a branch other than the current one the menu offers
  "compare with the current branch" (from their merge base, as a pull request would show it).
- A file's history: "这个文件的历史" in a file's menus lists only the commits that changed it
  (`--follow`, so across renames), with a chip to go back to all of them.

**A commit opens as a tab**, like a file: its message, author, date, parents (each a link), then
every file it changed with its counts. A file's diff unfolds under its name — the first ones already
unfolded, up to a budget, the rest on a click. Changed lines are told apart by **background tint
only**, as everywhere in this window. Each file can be opened side by side (the merge view, both
sides read-only), or opened at a line by clicking that line. The working-tree row opens the same
kind of tab for everything uncommitted against HEAD, untracked files included; a commit's menu
opens "this commit ↔ working tree", and picking two commits compares them.

Which card made each commit, a card's commits across repositories, and the repositories outside the project its
cards committed to: [2026-10-30-commits-by-card.md](2026-10-30-commits-by-card.md).

Read-only, like everything else here: no commit, checkout, reset or stash. Those stay in the
terminals, where an agent's half-done work is not one misclick away.

## Repositories inside a project

A project folder that is not a repository can hold some (`qwen_cowork` holds two). They are found
without walking the project: a short bounded look three levels down when the window opens (skipping
the usual dependency and build folders), and any folder the tree lists that has a `.git`. Each one
then gets what the project's own repository gets — markers in the tree, the HEAD tint in the editor,
its branch beside its folder, its own entry in the 提交 page's repository menu. Only for projects
that are not themselves in a repository: a repository's nested clones are usually ignored build
output, and their status would cost for nothing.

## Git, and what it costs

Only commands that leave `.git/index` alone (checked again on 2026-10-26 with a stat-dirty working
tree): `log`, `diff-tree`, `diff-index`, `for-each-ref`, `merge-base`, `rev-parse`, `cat-file`.
`diff-index` compares against the index's stat data without refreshing it, so a file that was only
touched shows up in `--name-status` with no change in `--numstat`; such entries are dropped.

- The log is read when the 提交 page is shown and again when HEAD or the refs move — not on a timer.
  `--shortstat` for a hundred commits is bounded by a timeout, after which the list comes without
  counts.
- A commit's file list is two `diff-tree` calls; a file's diff is one more, when it unfolds, capped
  at 4 MB. Untracked files are read directly and shown as added, never with `ls-files --others`
  without `--directory` (eight million files in one project here).
- Nested repositories' status runs with the main one's, under the same scheduling, at most twelve of
  them.
