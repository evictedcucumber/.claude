---
name: commit
description: Commit the uncommitted changes in the current branch or worktree, and nothing else. No push, merge, rebase, branch switch, tag, or amend. Use for every commit, whether the user asks for one or a brief allows one; pass the message and `-- <paths>` when they are known.
argument-hint: "[message or hint] [-- paths...]"
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git rev-parse:*), Bash(git branch --show-current), Bash(git worktree list:*), Bash(git ls-files:*)
---

Commit the uncommitted changes in the current working directory's checkout (the current branch, or the current worktree's branch) and stop. Do this yourself, without subagents.

Arguments: `$ARGUMENTS`. If they include `-- <paths>`, commit only those paths. Any other text is the commit message to use, or a hint for writing it. If you are a subagent and your brief names paths or messages, commit only those, even if other changes are uncommitted.

## Scope

- Only the repository and branch the current directory belongs to. Never switch branches, and never touch other worktrees or the main checkout. Use plain `git` in the current directory, never `git -C` to another path.
- Allowed: `git status`, `git diff`, `git log`, `git add <paths>`, `git commit -m`, and read-only lookups (`git rev-parse`, `git branch --show-current`, `git ls-files`).
- Not allowed: `push`, `pull`, `fetch`, `merge`, `rebase`, `cherry-pick`, `tag`, `commit --amend`, `reset`, `restore`, `checkout`, `switch`, `stash`, `clean`, or `--no-verify`. Don't suggest pushing or any other follow-up afterwards.

## Steps

1. Run `git rev-parse --show-toplevel`, `git branch --show-current`, `git status --short`, and `git log --oneline -n 10`. If nothing is uncommitted, say so and stop. If HEAD is detached, or a merge, rebase, or cherry-pick is in progress, stop and tell the user instead of committing.
2. Read the repo's commit convention: the CLAUDE.md files for this project and the recent `git log` (for example Conventional Commits). Follow it.
3. Read `git diff` and `git diff --staged` (`--stat` first if large), and look at untracked files from `git status`.
   - If something is already staged and no paths were given, commit only what is staged.
   - Otherwise commit all tracked changes and untracked files that belong with them. Skip anything that looks like a build artifact, cache, log, local env file, or editor junk, and mention what you skipped.
4. Group the changes. Prefer several small commits to one large one: one per feature, fix, or concern, with a feature's code, tests, and docs together, and refactors, formatting, dependency bumps, and config changes on their own. Order them so prerequisites come first. Make one commit if a single message was given or the change is indivisible.
5. For each commit: stage with `git add <paths>` (never `git add -A` or `git add .`), read `git diff --staged`, and check it and the message for secrets and personal details: keys, tokens, passwords, credentials, `.env` files, email addresses, real names, usernames, home directory paths, hostnames, and private URLs. If you find any, stop and tell the user where, without quoting the secret, and leave the rest uncommitted. Then run `git commit -m "<subject>" -m "<body>"`, with a body only when the subject isn't enough, and the attribution trailers your instructions give for commits.
6. If a pre-commit hook fails, don't bypass it. Fix the issue only if it is trivial and inside the files being committed (for example a formatter rewrote them, so re-stage), otherwise stop and report the hook's error.

## Report

List each commit (short SHA and subject), anything skipped or left uncommitted, and the final `git status --short`.
