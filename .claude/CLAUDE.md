# This repo is my global Claude Code config

This repo is cloned to `~/.claude`, so its contents are my global Claude Code settings. These instructions apply only when working inside this repo. They are not global instructions.

- Treat edits here as changes to my global config, which affects every project. Say so before making broad changes.
- `.gitignore` is an allowlist (`*` is ignored, config is re-included). When adding a new config file or directory, add a matching `!` rule.
- Never commit credentials, transcripts, or caches (`projects/`, `remote/`, `sessions/`, `file-history/`, `.credentials.json`, `settings.local.json`).
- Do not create `~/.claude/CLAUDE.md` unless I ask. That file is global user memory.

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/) for every commit message (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, etc.), with an optional scope, e.g. `feat(settings): disable push notifications`.
- Before committing, review `git diff --staged` and make sure nothing sensitive or identifying is included: API keys, tokens, passwords, credentials, email addresses, real names, usernames, home directory paths, hostnames, or private URLs. Use placeholders instead.
- Check the commit message too, not just the files. Do not put personal details in it.
- If something sensitive is found, stop and tell me instead of committing.
