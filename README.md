# Claude Code global config

My global [Claude Code](https://claude.com/claude-code) settings, kept in a repo that is cloned to `~/.claude`.

## Setup

```bash
git clone <this-repo-url> ~/.claude
```

If `~/.claude` already exists, clone elsewhere and copy the tracked files over, or run `git init` in `~/.claude` and add this repo as `origin`.

## What's tracked

The `.gitignore` is an allowlist: everything is ignored unless it is explicitly re-included. Tracked files:

- `settings.json`: global settings
- `agents/`: global subagents (see the table below)
- `output-styles/`: output styles (`orchestrator.md`)
- `.claude/CLAUDE.md`: instructions that apply only when working inside this repo
- `.gitignore` and `README.md`

Transcripts, caches, session data and credentials (`projects/`, `remote/`, `sessions/`, `file-history/`, `.credentials.json`, etc.) are never committed.

## Orchestrator setup

The main session runs on Opus 5.5 as planner and reviewer. Sonnet 5.5 subagents do the execution.

- `settings.json` sets `model` to Opus 5.5 and turns on the `Orchestrator` output style (`output-styles/orchestrator.md`). The style has Opus plan the work itself, delegate each step to the best-fitting subagent, and review every result (reading the diff and rechecking verification) before reporting.
- `agents/` holds the global subagents, all on Sonnet 5.5. Only the agents whose task needs deeper reasoning use high effort:

  | Agent | Effort | Edits files | Use for |
  | --- | --- | --- | --- |
  | `worker` | medium | yes | Default for any well-scoped task |
  | `worker-high` | high | yes | General tasks that need deeper reasoning |
  | `explorer` | medium | no | Understanding how code works or where it lives |
  | `researcher` | medium | no | External docs, APIs, versions |
  | `test-writer` | medium | yes | Adding or updating tests |
  | `build-fixer` | medium | yes | Build, type, lint, and CI failures |
  | `docs-writer` | medium | yes | READMEs, guides, docstrings, changelogs |
  | `debugger` | high | yes | Root-causing bugs and failing tests |
  | `code-reviewer` | high | no | Reviewing changes for bugs |
  | `security-reviewer` | high | no | Security review |

- `modelSettings` sets Sonnet 5.5 to medium effort by default and caps it at high, for every Sonnet subagent (including built-ins and project agents that don't set `effort`).
- `CLAUDE_CODE_SUBAGENT_MODEL` sends custom subagents that don't set a `model` to Sonnet 5.5. Agents that set a `model` keep it.

### Project subagents

Subagents a project defines in `<project>/.claude/agents/` show up in the orchestrator's Agent tool list automatically:

- The orchestrator calls a project agent directly whenever it fits a step, and splits a step that spans a project agent and a global one.
- `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` stops subagents from spawning their own subagents. Every result reaches Opus in one hop, so the orchestrator reviews raw output instead of a summary of a summary.
- A project agent with the same name as a global one (for example, `code-reviewer`) replaces it in that project.

To skip orchestration for one session, switch the output style back to Default or pick another model with `/model`.

## Adding config

To track a new file or directory, add a matching `!` rule to `.gitignore`.
