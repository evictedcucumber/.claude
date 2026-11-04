# Global instructions

These apply in every project, to the main session and to subagents.

## Git

- Prefer several small commits to one large one: one per feature, fix, or concern, split per file or area when a change touches unrelated parts. Keep a feature's code, tests, and docs together, and refactors, formatting, dependency bumps, and config changes in commits of their own. Order them so prerequisites come first and each stands on its own. Make a single commit only when I ask for one or the change is indivisible.
- Write every commit message, including merge commits, in [Conventional Commits](https://www.conventionalcommits.org/) format (`<type>(<optional scope>): <subject>`).
- Make every commit with the `commit` skill (the Skill tool with `commit`, passing the message and `-- <paths>` when you know them), not with a raw `git commit`. It already splits changes into small commits.
- Never merge unless I ask for that merge in the prompt or run `/commit-merge` myself. Never invoke the `commit-merge` skill on your own. A subagent may merge only when its brief says I asked for that merge.
- Never push, and never suggest, offer, or list pushing as a next step, even when a task ends with commits or merges. I push myself.
- Never create tags or releases (`git tag`, `gh release create`, a version bump made only to cut a release) unless I ask for it in the prompt or a CLAUDE.md tells you to. Don't suggest them either. Listing existing tags or releases is fine.
- When I ask for a merge, pick the strategy by this rule of thumb:
  - Want an accurate record of what happened: regular merge with `--no-ff`.
  - Want clean, linear history: rebase, or squash for tidy single-commit features.
  - Short-lived branch with no divergence: fast-forward (`--ff-only`).

  Follow my request or the repo's CLAUDE.md when either states a preference. Otherwise fast-forward when the target hasn't diverged, and merge with `--no-ff` when it has. Rebase or squash only when linear history is asked for, since they rewrite or drop the branch's commits.
- Treat a branch checked out in a worktree, including a worktree nested inside the main checkout (such as `.claude/worktrees/<name>`), as a normal branch: the same merge rule of thumb, and no push. Refer to it by branch name, not by its directory.

## Code

- Don't add unnecessary code comments that describe behaviour or reasons. Keep the comments and docstrings you do write short and concise, to prevent reading fatigue.
