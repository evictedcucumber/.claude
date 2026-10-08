# Claude Code global config

My global [Claude Code](https://claude.com/claude-code) settings, kept in a repo that is cloned to `~/.claude`.

## Setup

```bash
git clone <this-repo-url> ~/.claude
```

If `~/.claude` already exists, clone elsewhere and copy the tracked files over, or run `git init` in `~/.claude` and add this repo as `origin`.

If you copy files instead of cloning, keep the scripts executable. A hook that can't run is a non-blocking error, so a non-executable `readonly-bash.sh` silently turns the read-only restriction off:

```bash
chmod +x ~/.claude/hooks/*.sh && ~/.claude/hooks/test-readonly-bash.sh
```

The hook needs `jq`.

## What's tracked

The `.gitignore` is an allowlist: everything is ignored unless it is explicitly re-included. Tracked files:

- `settings.json`: global settings
- `agents/`: global subagents (see the table below)
- `hooks/`: hook scripts used by agents (`readonly-bash.sh` and its tests, see "Read-only agents")
- `output-styles/`: output styles (`orchestrator.md`)
- `.claude/CLAUDE.md`: instructions that apply only when working inside this repo
- `.github/workflows/ci.yml`: CI that runs shellcheck, the hook tests, and schema validation of `settings.json`
- `.gitignore`, `README.md` and `LICENSE`

Transcripts, caches, session data and credentials (`projects/`, `remote/`, `sessions/`, `file-history/`, `.credentials.json`, etc.) are never committed.

## Orchestrator setup

The main session runs on Opus 5.5 as planner and reviewer. Subagents do the execution: Haiku 5.5 for lookups and fully specified mechanical steps, Sonnet 5.5 for everything that needs judgment.

- `settings.json` sets `model` to Opus 5.5 and turns on the `Orchestrator` output style (`output-styles/orchestrator.md`). The style has Opus plan the work itself, delegate each step to the best-fitting subagent, coordinate the hand-offs between them, and review every result (reading the diff and rechecking verification) before reporting. It also lists standard sequences of agents for common tasks (bug, feature, dependency upgrade, security-sensitive change, performance, CI failure, docs).
- `agents/` holds the global subagents. Each agent's model, effort, and turn limit (`maxTurns`) are set in its own frontmatter, which is the source of truth:

  | Agent | Model | Edits files | Use for |
  | --- | --- | --- | --- |
  | `worker` | Sonnet | yes | Default for well-scoped execution no specialist covers |
  | `worker-high` | Sonnet | yes | General tasks that need deeper reasoning |
  | `explorer` | Sonnet | no | Understanding how code works or where it lives |
  | `researcher` | Sonnet | no | External docs, APIs, versions |
  | `test-writer` | Sonnet | yes | Adding or updating tests |
  | `build-fixer` | Sonnet | yes | Build, type, lint, and CI failures |
  | `docs-writer` | Sonnet | yes | READMEs, guides, docstrings, changelogs |
  | `debugger` | Sonnet | yes | Root-causing bugs and failing tests |
  | `code-reviewer` | Sonnet | no | Reviewing changes for bugs |
  | `security-reviewer` | Sonnet | no | Security review |
  | `optimizer` | Sonnet | yes | Performance work driven by measurements |
  | `integrator` | Sonnet | yes | Merging branches from parallel or worktree agents |
  | `worker-fast` | Haiku | yes | Mechanical, fully specified edits; running a command and summarizing it |
  | `explorer-fast` | Haiku | no | Locating files, symbols, and call sites |
  | `researcher-fast` | Haiku | no | Looking up one external fact |
  | `docs-writer-fast` | Haiku | yes | Short docs: docstrings, changelog entries |
  | `test-runner` | Haiku | no | Running existing tests and reporting failures |

  Each Haiku agent names its Sonnet counterpart in its description, and the orchestrator moves a step there if the Haiku agent reports that it needs judgment or gets it wrong. Review, security, and debugging stay on Sonnet.

- Agents that edit files don't commit, push, or switch branches unless the brief says so. Parallel writers need disjoint files or a worktree; `integrator` merges worktree branches back.
- The orchestrator delegates by the shape of the work (self-contained steps that return a summary) and does small steps inline, while always doing review itself.
- `modelSettings` runs Opus 5.5 at high effort, since planning and review need the deepest reasoning (Opus otherwise defaults to medium, the same as the workers). Try `xhigh` if planning quality matters more than speed.
- `modelSettings` also sets Sonnet 5.5 and Haiku 5.5 to medium effort by default and caps both at high, for every subagent on those models (including built-ins and any agent that doesn't set `effort`). Anthropic's guidance for Haiku 5.5 is that `low` is more likely to skip a search or check in multi-step agent work, and that `xhigh`/`max` should be compared against Sonnet 5.5 first; a step that needs more than high on Haiku goes to Sonnet instead.
- `CLAUDE_CODE_SUBAGENT_MODEL` sends custom subagents that don't set a `model` to Sonnet 5.5. Agents that set a `model` keep it.
- `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` stops subagents from spawning their own subagents (the default allows 3 levels). Every result reaches Opus in one hop, so the orchestrator reviews raw output instead of a summary of a summary.
- `GIT_OPTIONAL_LOCKS=0` stops read-only git commands such as `git status` from taking `.git/index.lock`, so a reviewer doesn't collide with a worker editing the same checkout.

### How agents talk to each other

`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` means subagents can't spawn their own subagents, and they don't message each other, so every exchange goes through the orchestrator, in a fixed format each way:

- **Brief (orchestrator to agent).** The output style defines the fields: Goal, Context, Scope (the files the agent owns), Constraints, Done when, Verify with, Permissions, and Return. Facts from one agent reach another only after the orchestrator has checked them and rewritten them into Context; it never forwards a report or raw web content into a writer's brief, so injected instructions can't travel from a read-only agent to one that can edit files or run commands.
- **Report (agent to orchestrator).** Every agent ends with the same `## Report` section. It starts with `STATUS: done | partial | blocked` and ends with `Unverified:` (what to spot-check), `Open:` (decisions needed, with options and a recommendation, or what is left of a `partial` step), and `Next:` (the agent it suggests for the next step). Agents stop as soon as they are blocked, and expect a SendMessage reply that resumes them with their context intact.
- **Context packs.** `explorer` can return a short context pack (key files, conventions, build and test commands, gotchas) that the orchestrator pastes into several briefs, so parallel workers don't each rediscover the same area.
- **Retries.** A step that fails twice on the same agent type is escalated, re-planned, or done inline rather than sent back a third time.

### Permissions

`permissions.deny` in `settings.json` applies to the main session and every subagent:

- It blocks the Read tool on well-known secret files (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, token files such as `~/.netrc` and `~/.config/gh/hosts.yml`, `~/.claude/.credentials.json`, and `.env` / `.env.local` / `.env.production`). `.env.example` stays readable.
- It blocks force pushes (`git push --force`, `-f`, and `+refspec`). `--force-with-lease` is still allowed. Forms such as `git -C dir push -f` aren't covered, so treat this as a guard against mistakes.
- `.env` rules appear twice: `**/.env` covers the working directory and `//**/.env` covers absolute paths anywhere.

Read rules don't stop `cat` through Bash in the main session, so they are a guard against accidents and prompt injection, not a sandbox.

### Read-only agents

Subagents inherit the parent's permission mode and ignore their own, so "only run read-only commands" in a prompt is not enforced. These agents are restricted in their frontmatter instead. Each one gets an explicit `tools:` allowlist rather than a `disallowedTools` denylist, because a denylist still inherits tools such as Monitor (which runs shell commands outside the Bash hook), Artifact, CronCreate, RemoteTrigger, WebFetch, and any MCP tools.

- `researcher` reads untrusted web content, so it gets only `tools: WebSearch, WebFetch`. With no file or shell access, injected instructions can't read local secrets and send them out through a fetched URL. The orchestrator passes it any versions it needs from lockfiles.
- `researcher-fast` gets the same `tools: WebSearch, WebFetch` as `researcher`.
- `explorer`, `explorer-fast`, `code-reviewer`, `security-reviewer` and `test-runner` get `tools: Read, Grep, Glob, Bash`, with no network tools, so they can read untrusted repos without a way to send data out. Bash runs `hooks/readonly-bash.sh` as a `PreToolUse` hook (matched on `Bash|Monitor`, in their own frontmatter, so it applies only while they are active). The hook blocks any command that isn't on a conservative read-only allowlist (`ls`, `cat`, `grep`, `rg`, `find` without `-exec`/`-delete`, `git log`/`diff`/`show`/`status`, and similar), plus redirections, command substitution, `$'...'` quoting, parentheses, chaining into other commands, background jobs, `tail -f`, and arguments naming well-known secret files. For commands whose flags matter (`find`, `rg`, `sort`, `git`, `tail`, test runners) it also rejects variables and unquoted globs or braces, since bash would expand them into flags the hook never saw (for example a file named `--pre=sh`). It fails closed, and false rejects are expected: `jq 'map(.a)'` and `rg 'a|b'` are rejected, so the agents use the Grep and Glob tools for those.
- Only `code-reviewer` and `test-runner` pass `--allow-tests`, which also allows common test runners (`npm test`, `pytest`, `cargo test`, `go test`, `make test`, `npx --no jest`, ...) without snapshot-update, fix, output, or "run another project" flags. npm, pnpm and yarn options are allowed only after `--`, `make test` takes only `-j`/`-k`/`-s`, and `cd` can't be combined with a test runner in one command. Test runners execute the project's code with your privileges, so this is for reviewing trusted code. `security-reviewer` doesn't get it, because the code it reviews may be hostile; it names the tests to run and the orchestrator decides.
- Git commands still honor the repo's own `.git/config` (for example `diff.external` or textconv drivers), so don't point read-only agents at a repo whose `.git` directory came from someone else.
- The hook lives at `~/.claude/hooks/readonly-bash.sh`, so the agents rely on this repo being cloned there. Run `hooks/test-readonly-bash.sh` after changing the hook, and add a test case for every bypass you fix.

To skip orchestration for one session, switch the output style back to Default or pick another model with `/model`.

## Adding config

To track a new file or directory, add a matching `!` rule to `.gitignore`.

To add an agent, copy the closest existing one, keep its `## Report` section unchanged at the end, and add it to the tables in `output-styles/orchestrator.md` and this README.
