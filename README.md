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

- `settings.json` sets `model` to Opus 5.5 and turns on the `Orchestrator` output style (`output-styles/orchestrator.md`). The style has Opus plan the work itself, delegate each step to the best-fitting subagent, coordinate the hand-offs between them, and review every result (reading the diff and rechecking verification) before reporting. It also lists standard sequences of agents for common tasks (bug, feature, dependency upgrade, security-sensitive change, performance, CI failure, git, docs).
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
  | `git` | Sonnet | yes | Commits, merges, rebases, conflicts, history recovery |
  | `worker-fast` | Haiku | yes | Mechanical, fully specified edits; running a command and summarizing it |
  | `explorer-fast` | Haiku | no | Locating files, symbols, and call sites |
  | `researcher-fast` | Haiku | no | Looking up one external fact |
  | `docs-writer-fast` | Haiku | yes | Short docs: docstrings, changelog entries |
  | `test-runner` | Haiku | no | Running existing tests and reporting failures |
  | `git-fast` | Haiku | yes | Fully specified git steps: commit named files, branch, fast-forward |

  Each Haiku agent names its Sonnet counterpart in its description, and the orchestrator moves a step there if the Haiku agent reports that it needs judgment or gets it wrong. Review, security, and debugging stay on Sonnet.

- Agents that edit files don't commit or switch branches unless the brief says so, and never push or suggest pushing. Merges follow a rule of thumb set in the orchestrator style and the git agents: `--no-ff` for an accurate record, rebase or squash only when linear history is asked for, and `--ff-only` for a short-lived branch with no divergence. Worktree branches, including worktrees nested inside the checkout such as `.claude/worktrees/<name>`, are merged as normal branches under the same rules. They undo their own edits with Edit or a saved patch, never `git stash`/`checkout`/`restore`/`reset`/`bisect`, so they can't wipe someone else's uncommitted work. Their `disallowedTools` removes web, scheduling, notification and Artifact tools, so a writer misled by repo content can't fetch URLs, schedule jobs, or publish pages through those tools (Bash can still reach the network); the orchestrator does research first and passes the facts in. Parallel writers need disjoint files or a worktree; `integrator` merges worktree branches back, and `git`/`git-fast` handle other git work when the brief allows it.
- The orchestrator delegates by the shape of the work (self-contained steps that return a summary) and does small steps inline, while always doing review itself.
- `modelSettings` runs Opus 5.5 at high effort, since planning and review need the deepest reasoning (Opus otherwise defaults to medium, the same as the workers). Try `xhigh` if planning quality matters more than speed.
- `modelSettings` also caps Sonnet 5.5 and Haiku 5.5 at high effort, for every subagent on those models (including built-ins). Both already default to medium, so agents that don't set `effort` run at medium. Anthropic's guidance for Haiku 5.5 is that `low` is more likely to skip a search or check in multi-step agent work, and that `xhigh`/`max` should be compared against Sonnet 5.5 first; a step that needs more than high on Haiku goes to Sonnet instead.
- `CLAUDE_CODE_SUBAGENT_MODEL` sends subagents that don't set a `model`, including the built-in `general-purpose`, to Sonnet 5.5. Agents that set a `model` keep it. It doesn't change the built-in Explore and Plan agents, which stay on the main model; the orchestrator uses `explorer-fast` and plans itself instead.
- `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` stops subagents from spawning their own subagents (the default allows 3 levels). Every result reaches Opus in one hop, so the orchestrator reviews raw output instead of a summary of a summary.
- `GIT_OPTIONAL_LOCKS=0` stops read-only git commands such as `git status` from taking `.git/index.lock`, so a reviewer doesn't collide with a worker editing the same checkout.

### How agents talk to each other

`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` means subagents can't spawn their own subagents, and they don't message each other, so every exchange goes through the orchestrator, in a fixed format each way:

- **Brief (orchestrator to agent).** The output style defines the fields: Goal, Context, Scope (the files the agent owns), Constraints, Done when, Verify with, Permissions, and Return. Facts from one agent reach another only after the orchestrator has checked them and rewritten them into Context; it never forwards a report or raw web content into a writer's brief, so injected instructions can't travel from a read-only agent to one that can edit files or run commands.
- **Report (agent to orchestrator).** Every agent ends with the same `## Report` section. It starts with `STATUS: done | partial | blocked` and ends with `Unverified:` (what to spot-check), `Open:` (decisions needed, with options and a recommendation, or what is left of a `partial` step), and `Next:` (the agent it suggests for the next step). Agents stop as soon as they are blocked, and expect a SendMessage reply that resumes them with their context intact. Each agent is told its turn budget and reports `partial` at about 80% of it; a report with no `STATUS:` line means the agent was cut off, and the orchestrator treats it as `partial`.
- **Context packs.** `explorer` can return a short context pack (key files, conventions, build and test commands, gotchas) that the orchestrator pastes into several briefs, so parallel workers don't each rediscover the same area.
- **Retries.** A step that fails twice on the same agent type is escalated, re-planned, or done inline rather than sent back a third time.

### Permissions

`permissions.deny` in `settings.json` applies to the main session and every subagent:

- It blocks the Read tool on well-known secret files (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.config/gcloud`, `~/.azure`, token files such as `~/.netrc`, `~/.pgpass`, `~/.cargo/credentials` and `~/.config/gh/hosts.yml`, `~/.claude/.credentials.json`, and `.env` / `.env.local` / `.env.development` / `.env.staging` / `.env.test` / `.env.production`). `.env.example` stays readable.
- It blocks every `git push`, including `git -C dir push`. Other forms such as `git -c key=value push` or a push from a script aren't covered, so treat this as a guard against mistakes; the agents and the orchestrator style also tell Claude never to push.
- `.env` rules appear twice: `**/.env` covers the working directory and `//**/.env` covers absolute paths anywhere.

Read rules don't stop `cat` through Bash in the main session, so they are a guard against accidents and prompt injection, not a sandbox.

### Read-only agents

Subagents inherit the parent's permission mode and ignore their own, so "only run read-only commands" in a prompt is not enforced. These agents are restricted in their frontmatter instead. Each one gets an explicit `tools:` allowlist rather than a `disallowedTools` denylist, because a denylist still inherits tools such as Monitor (which runs shell commands outside the Bash hook), Artifact, CronCreate, RemoteTrigger, WebFetch, and any MCP tools.

- `researcher` reads untrusted web content, so it gets only `tools: WebSearch, WebFetch`. With no file or shell access, injected instructions can't read local secrets and send them out through a fetched URL. The orchestrator passes it any versions it needs from lockfiles.
- `researcher-fast` gets the same `tools: WebSearch, WebFetch` as `researcher`.
- `explorer`, `explorer-fast`, `code-reviewer`, `security-reviewer` and `test-runner` get `tools: Read, Grep, Glob, Bash`, with no network tools, so they can read untrusted repos without a way to send data out. Bash runs `hooks/readonly-bash.sh` as a `PreToolUse` hook (matched on `Bash|Monitor`, in their own frontmatter, so it applies only while they are active). The hook tokenizes the command the way bash does (quotes, backslash escapes) and checks each command in a `;`, `&&`, `||` or `|` chain on its own dequoted words, so `-ex''ec` is seen as `-exec` and a quoted `;` or `|` is just text. It blocks any command that isn't on a conservative read-only allowlist (`ls`, `cat`, `grep`, `rg`, `find` without `-exec`/`-delete`, `git log`/`diff`/`show`/`status`, and similar), plus redirections other than `2>&1` and `>/dev/null`, command substitution, `$'...'` quoting, unquoted parentheses, comments, background jobs, `tail -f`, and arguments naming well-known secret files. For commands whose flags matter (`find`, `rg`, `sort`, `git`, `tail`, test runners) it also rejects variables and unquoted globs or braces, since bash would expand them into flags the hook never saw (for example a file named `--pre=sh`). It fails closed, and false rejects are expected.
- Only `code-reviewer` and `test-runner` pass `--allow-tests`, which also allows common test runners (`npm test`, `pytest`, `cargo test`, `go test`, `make test`, `npx --no jest`, `npx --no vitest run`). Each runner has an allowlist of options (filters, verbosity, parallelism, fail-fast, built-in reporters, and similar), so snapshot-update, output-file, config, plugin, module-loading and directory options are rejected without having to be named. npm, pnpm and yarn take only `--silent`/`--if-present` before `--`, and jest/vitest options after it; `make test` takes only `-j`/`-k`/`-s`. Every argument and option value must stay inside the project (`$CLAUDE_PROJECT_DIR`): `~` and `..` are rejected, and absolute paths must resolve under the root (symlinks resolved with GNU `realpath -m`, lexically elsewhere). Test runners refuse to run from a directory outside the project. To test a sub-package of a monorepo, `cd ./packages/x` or pass its path. Test runners execute the project's code with your privileges, so this is for reviewing trusted code. `security-reviewer` doesn't get it, because the code it reviews may be hostile; it names the tests to run and the orchestrator decides.
- The Bash tool keeps its working directory between calls, so all five agents may `cd` only to `./dir` or an absolute path inside the project (a bare `cd x` goes through `CDPATH`), `git -C` must point inside it too, and git refuses to run from a directory outside it. That keeps test runs, and git with another repo's `.git/config`, on the project.
- Git commands still honor the repo's own `.git/config` (for example `diff.external` or textconv drivers), so don't point read-only agents at a repo whose `.git` directory came from someone else.
- The hook lives at `~/.claude/hooks/readonly-bash.sh`, so the agents rely on this repo being cloned there. Run `hooks/test-readonly-bash.sh` after changing the hook, and add a test case for every bypass you fix.

To skip orchestration for one session, switch the output style back to Default or pick another model with `/model`.

## Adding config

To track a new file or directory, add a matching `!` rule to `.gitignore`.

To add an agent, copy the closest existing one, keep its `## Report` section unchanged at the end, and add it to the tables in `output-styles/orchestrator.md` and this README.
