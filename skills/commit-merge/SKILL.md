---
name: commit-merge
description: Commit the uncommitted changes in the current branch or worktree, then merge that branch into the main branch locally. No push, pull, fetch, rebase, tag, or branch deletion.
argument-hint: "[message or hint] [-- paths...] [--into <branch>]"
disable-model-invocation: true
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git rev-parse:*), Bash(git branch --show-current), Bash(git branch --list:*), Bash(git worktree list:*), Bash(git ls-files:*), Bash(git symbolic-ref:*), Bash(git merge-base:*), Bash(git rev-list:*), Bash(git merge:*), Bash(git switch:*), Bash(git -C:*)
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

## 3. Merge

1. Pick the strategy. Follow the user's request or the project's CLAUDE.md if either states one. Otherwise: if `git merge-base --is-ancestor <target> <source>` succeeds, the target hasn't diverged, so use `git merge --ff-only <source>`; if not, use `git merge --no-ff <source>`. Use squash only when asked, with `git merge --squash` followed by a commit. Never rebase.
2. For a `--no-ff` merge, write the message in the project's convention (for example `chore: merge branch '<source>'` for Conventional Commits) with `-m`, plus the attribution trailers your instructions give for commits. Check it for personal details as in `/commit`.
3. If the merge conflicts, run `git merge --abort` in the same checkout, switch back to the source if you switched, and stop. List the conflicting files and leave resolving them to the user.
4. If a hook fails, don't bypass it; abort as above and report the error.

## Report

List each commit made (short SHA and subject), the merge (strategy, target, and resulting target SHA), anything skipped or left uncommitted, and the final `git status --short` of the current checkout.
