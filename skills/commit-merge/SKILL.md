---
name: commit-merge
description: Commit the uncommitted changes in the current branch or worktree, then merge that branch into the main branch locally. No push, pull, fetch, rebase, tag, or branch deletion.
argument-hint: "[message or hint] [-- paths...] [--into <branch>]"
disable-model-invocation: true
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git rev-parse:*), Bash(git branch --show-current), Bash(git branch --list:*), Bash(git worktree list:*), Bash(git ls-files:*), Bash(git symbolic-ref:*), Bash(git merge-base:*), Bash(git merge-tree:*), Bash(git rev-list:*), Bash(git merge:*), Bash(git switch:*), Bash(git -C:*), Read, Edit
---

Run this only because the user typed `/commit-merge`. Never start it on your own or from a brief.

Commit the current branch's changes, then merge that branch into the main branch on this machine, and stop. Do this yourself, without subagents.

Arguments: `$ARGUMENTS`. `--into <branch>` sets the target branch. `-- <paths>` and any other text mean the same as for `/commit`: paths to commit, and a commit message or hint.

## Scope

- Only this repository: the current branch (the source) and the target branch. Never touch other branches or other worktrees' uncommitted changes.
- Not allowed: `push`, `pull`, `fetch`, `rebase`, `cherry-pick`, `tag`, `commit --amend`, `reset`, `restore`, `checkout --` over files, `stash`, `clean`, `branch -d/-D`, `worktree remove`, or `--no-verify`. Leave the source branch and its worktree in place after the merge. Don't suggest pushing or any other follow-up afterwards.

## 1. Commit

Read `${CLAUDE_SKILL_DIR}/../commit/SKILL.md` and follow its Scope and Steps for the current branch. If it stops (secrets found, hook failure, detached HEAD, operation in progress), stop here too and don't merge. If there was nothing to commit, carry on to the merge.

## 2. Find the target

1. Source: `git branch --show-current`. The target is `--into <branch>` if given, otherwise the branch the project's CLAUDE.md names as main, otherwise `git symbolic-ref --short refs/remotes/origin/HEAD` without the remote prefix, otherwise whichever of `main` or `master` exists locally (`git branch --list main master`). If none is found, or the source is the target, stop and say so.
2. If the source has no commits the target lacks (`git rev-list --count <target>..<source>` is 0), say it is already merged and stop.
3. Find where the target is checked out: `git worktree list --porcelain`, looking for `branch refs/heads/<target>`.
   - Checked out in another worktree (for example the main checkout while you are in `.claude/worktrees/<name>`): the merge runs there, with `git -C <that path>`. Run `git -C <path> status --porcelain` first; if it has uncommitted changes to tracked files, stop and tell the user rather than merging over them.
   - Not checked out anywhere, and the current checkout is clean after step 1: `git switch <target>`, merge, then `git switch <source>` to go back.
   - Not checked out anywhere, but the current checkout isn't clean (you committed only some paths): stop and tell the user.

## 3. Check for conflicts

Before switching branches or merging, dry-run the merge: `git merge-tree --write-tree --name-only --no-messages <target> <source>`. It changes nothing in any checkout. Exit 0 means it merges cleanly; go to step 5. Exit 1 means it conflicts, and the output lists the conflicting files after the tree SHA; go to step 4.

## 4. Resolve conflicts on the source branch

Never resolve conflicts on the target. Bring the target into the source instead, so the target only ever gets a clean merge.

1. The source checkout must be clean (`git status --porcelain` shows no changes to tracked files). If it isn't, because you committed only some paths, stop and list the conflicting files.
2. In the source checkout, run `git merge --no-ff <target>` with the message `chore: merge branch '<target>' into <source>` plus the attribution trailers your instructions give for commits.
3. For each conflicting file, read both sides and what each branch was trying to do (`git log --oneline <merge-base>..<target> -- <file>` and the same for the source). Resolve so both sides' intent survives: keep both sets of additions, fit the source's change into the target's newer structure, and never just pick one side of a hunk to make the conflict go away. Remove every conflict marker, then `git add` the file.
4. Look past the textual conflicts for semantic ones: code that merged cleanly but now calls something the other side renamed, removed, or made stricter.
5. Run the project's checks (tests, lint, format, type check) as its CLAUDE.md or README describes them. They must pass.
6. If any conflict's right resolution is unclear (both sides changed the same behaviour in incompatible ways, or it needs a product decision), or the checks fail and the fix isn't a direct consequence of the merge, run `git merge --abort` in the source checkout and stop. List the conflicting files, what each side changed, and where you got stuck.
7. Otherwise `git commit --no-edit` to finish the merge. The target is now an ancestor of the source, so step 5 fast-forwards it.

## 5. Merge

1. Pick the strategy. Follow the user's request or the project's CLAUDE.md if either states one. Otherwise: if `git merge-base --is-ancestor <target> <source>` succeeds, the target hasn't diverged, so use `git merge --ff-only <source>`; if not, use `git merge --no-ff <source>`. Use squash only when asked, with `git merge --squash` followed by a commit. Never rebase.
2. For a `--no-ff` merge, write the message in Conventional Commits format, `chore: merge branch '<source>'`, with `-m`, plus the attribution trailers your instructions give for commits. Check it for personal details as in `/commit`.
3. If the merge into the target conflicts anyway, run `git merge --abort` in that checkout, switch back to the source if you switched, and stop. List the conflicting files. Never resolve conflicts on the target.
4. If a hook fails, don't bypass it; abort as above and report the error.

## Report

List each commit made (short SHA and subject), any merge of the target into the source with how each conflict was resolved and the checks you ran, the merge (strategy, target, and resulting target SHA), anything skipped or left uncommitted, and the final `git status --short` of the current checkout.
