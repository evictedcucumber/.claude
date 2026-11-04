# This repo is my global Claude Code config

This repo is cloned to `~/.claude`, so its contents are my global Claude Code settings. These instructions apply only when working inside this repo. They are not global instructions.

- Treat edits here as changes to my global config, which affects every project. Say so before making broad changes.
- `.gitignore` is an allowlist (`*` is ignored, config is re-included). When adding a new config file or directory, add a matching `!` rule.
- Never commit credentials, transcripts, or caches (`projects/`, `remote/`, `sessions/`, `file-history/`, `.credentials.json`, `settings.local.json`).
- Keep the two CLAUDE.md files separate. `CLAUDE.md` at the repo root is global user memory and loads in every project, so only rules for every project go there. This file, `.claude/CLAUDE.md`, holds the rules for working on this repo. Don't merge them or move this file's rules into the global one.

## Commits

- Scope commit messages by the area changed, e.g. `feat(settings): disable push notifications`.
- Before committing, review `git diff --staged` and make sure nothing sensitive or identifying is included: API keys, tokens, passwords, credentials, email addresses, real names, usernames, home directory paths, hostnames, or private URLs. Use placeholders instead.
- Check the commit message too, not just the files. Do not put personal details in it.
- If something sensitive is found, stop and tell me instead of committing.
