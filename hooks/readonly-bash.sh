#!/usr/bin/env bash
#
# PreToolUse hook for the Bash tool that keeps "read-only" subagents read-only.
#
# Subagents inherit the parent's permission mode and ignore their own, so a
# prompt asking an agent to "only run read-only commands" is not enforced. This
# hook is: it exits 0 only for commands on a small read-only allowlist and
# exits 2 (block, reason on stderr) for everything else. It fails closed: any
# error, malformed input, or empty command blocks.
#
# Usage in an agent's frontmatter:
#   command: '"$HOME/.claude/hooks/readonly-bash.sh"'                 # no test runners
#   command: '"$HOME/.claude/hooks/readonly-bash.sh" --allow-tests'   # plus test runners
#
# It is deliberately CONSERVATIVE. False rejects are fine, false accepts are
# not. It rejects what it cannot reason about (newlines, control characters,
# command and process substitution, ${...}, $'...', comments, redirections
# other than 2>&1 and >/dev/null, background jobs, unquoted parentheses), then
# tokenizes the rest the way bash does (single and double quotes, backslash
# escapes) and splits it into commands at unquoted ; && || and |. Each
# command's first word must be an unquoted, allowlisted command, and its flags
# are checked on the dequoted words, so obfuscated flags such as -ex''ec are
# seen as -exec. A word that contains an unquoted $, glob or brace character is
# recorded, and commands whose flags matter reject it, because bash would
# expand it into words the checks never saw.
#
# Test runners (npm test, pytest, cargo test, go test, ...) are opt-in via
# --allow-tests. They EXECUTE PROJECT CODE (package.json scripts, Makefiles,
# conftest.py, build.rs) with the user's privileges, so only enable them for
# agents that review trusted code. Each runner has an allowlist of options;
# anything else is rejected. Every argument and option value must stay inside
# the project ($CLAUDE_PROJECT_DIR): no ~, no .. components, and absolute paths
# only under the project root (symlinks resolved when GNU realpath is
# available). cd is allowed only to ./dir or an absolute path inside the
# project, because the Bash tool keeps its working directory between calls
# (this applies to every agent, since git honors the .git/config of the repo it
# runs in, and git -C is checked the same way).
# Test runners can still write files (snapshots, __pycache__, .pytest_cache,
# build dirs), so "read-only" is only best effort for them.
#
# It assumes bash syntax. Unquoted parentheses are rejected, which covers zsh's
# glob qualifiers, but zsh's EXTENDED_GLOB operators (^x, x#) are not; leave
# that option off if the Bash tool runs zsh.
#
# It also refuses arguments that name well-known secret files (~/.ssh,
# credentials, .env, ...). That check is best effort: globs and cd can evade
# it. The real control is that read-only agents have no network tools.

set -euo pipefail

# Exit status 1 from a hook is a non-blocking error (the call would proceed),
# so make every exit path other than the explicit "allow" below exit 2.
ALLOWED=0
trap 'if [[ $ALLOWED -ne 1 ]]; then exit 2; fi' EXIT

ALLOW_TESTS=0
if [[ "${1:-}" == "--allow-tests" ]]; then
  ALLOW_TESTS=1
fi

block() {
  {
    echo "Blocked by the read-only Bash hook: $1."
    echo "This subagent is read-only and may only run allowlisted read-only commands (ls, cat, grep, rg, find, git log/diff/show/status, etc.). Do not retry this command in another form; use a read-only alternative or report what you could not check."
  } >&2
  exit 2
}

# ---------------------------------------------------------------- read input
command -v jq >/dev/null 2>&1 || block "jq is not installed, so the hook cannot read the command (install jq)"
input=$(cat) || block "could not read hook input"
cmd=$(printf '%s' "$input" | jq -er '
  .tool_input.command
  | select(type == "string")
  | select(contains("\u0000") | not)
') || block "could not read a command from the hook input"
[[ -n "${cmd//[[:space:]]/}" ]] || block "empty command"
# The session's working directory. Empty if missing.
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty | select(type == "string")' 2>/dev/null) || hook_cwd=

# ----------------------------------------------------------- project paths
# GNU realpath -m resolves symlinks in the parts of a path that exist. Without
# it (macOS), fall back to lexical normalisation.
have_realpath=0
if realpath -m -- / >/dev/null 2>&1; then
  have_realpath=1
fi

lexical_norm() {
  local part IFS=/
  local -a parts out=()
  read -ra parts <<<"$1" || true
  for part in "${parts[@]}"; do
    case "$part" in
      '' | .) ;;
      ..) if ((${#out[@]} > 0)); then unset "out[$((${#out[@]} - 1))]"; fi ;;
      *) out+=("$part") ;;
    esac
  done
  printf '/%s' "${out[@]}"
}

norm_path() {
  if ((have_realpath == 1)); then
    realpath -m -- "$1"
  else
    lexical_norm "$1"
  fi
}

# The project root: $CLAUDE_PROJECT_DIR, else the session's cwd. Empty if
# neither is a usable absolute path, in which case absolute paths are refused.
root=${CLAUDE_PROJECT_DIR:-}
[[ "$root" == /?* ]] || root=$hook_cwd
root_n=
if [[ "$root" == /?* ]]; then
  root_n=$(norm_path "$root") || root_n=
  [[ "$root_n" == /?* ]] || root_n=
fi

# True if path $1 is inside the project root.
in_root() {
  local r
  [[ -n "$root_n" ]] || return 1
  r=$(norm_path "$1") || return 1
  [[ "$r" == "$root_n" || "$r" == "$root_n"/* ]]
}

# True if $1 points outside the project: ~, any .. component, or an absolute
# path not under the root. Relative paths without .. stay below the working
# directory, which cwd_ok checks is inside the project.
outside_path() {
  local p=$1
  case "$p" in
    '~'* | .. | ../* | */../* | */..) return 0 ;;
    /*) if in_root "$p"; then return 1; fi; return 0 ;;
  esac
  return 1
}

cwd_ok() {
  [[ -n "$hook_cwd" && -n "$root_n" ]] || return 0
  in_root "$hook_cwd"
}

# ------------------------------------------- whole-command syntax rejections
if [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]]; then
  block "multi-line commands are not allowed"
fi
if [[ "${cmd//$'\t'/ }" == *[[:cntrl:]]* ]]; then
  block "control characters are not allowed"
fi
# shellcheck disable=SC2016 # the $( and ${ patterns are meant literally
case "$cmd" in
  *'`'* | *'$('* | *'<('* | *'>('* | *'${'* | *'$['*)
    block "command or process substitution, \${...} and \$[...] are not allowed" ;;
  # $'...' decodes escapes such as \x2d, which would hide flags from the checks below.
  *"\$'"* | *'$"'*)
    block "\$'...' and \$\"...\" quoting are not allowed" ;;
esac

# ----------------------------------------------------------------- tokenize
# Splits $cmd into commands (segs, words joined by $US) the way bash would,
# recording for each command whether any word had an unquoted $ (seg_var) or
# glob or brace character (seg_glob), and whether its first word was a plain
# literal (seg_lit).
US=$'\x1f'
segs=()
seg_var=()
seg_glob=()
seg_lit=()
cur=
cvar=0
cglob=0
clit=1
nwords=0
word=
inword=0
wquoted=0
wvar=0
wglob=0

end_word() {
  if ((inword == 0)); then return 0; fi
  cur+=$word$US
  if ((nwords == 0)) && ((wquoted == 1 || wvar == 1 || wglob == 1)); then clit=0; fi
  nwords=$((nwords + 1))
  if ((wvar == 1)); then cvar=1; fi
  if ((wglob == 1)); then cglob=1; fi
  word=
  inword=0
  wquoted=0
  wvar=0
  wglob=0
}

end_seg() {
  end_word
  segs+=("$cur")
  seg_var+=("$cvar")
  seg_glob+=("$cglob")
  seg_lit+=("$clit")
  cur=
  cvar=0
  cglob=0
  clit=1
  nwords=0
}

# True if position $1 ends a word (end of input, blank, or an operator).
is_boundary() {
  local c=${cmd:$1:1}
  [[ -z "$c" || "$c" == ' ' || "$c" == $'\t' || "$c" == ';' || "$c" == '|' || "$c" == '&' ]]
}

# Accepts the exact redirection $2 starting at position $1 and skips it, or blocks.
redirect() {
  local start=$1 form=$2
  if [[ "${cmd:start:${#form}}" == "$form" ]] && is_boundary $((start + ${#form})); then
    i=$((start + ${#form} - 1))
    word=
    inword=0
    wquoted=0
    wvar=0
    wglob=0
    return 0
  fi
  block "redirections other than 2>&1, >/dev/null, 2>/dev/null and &>/dev/null are not allowed"
}

# True if the character after position $1 starts a parameter expansion.
dollar_expands() {
  local nx=${cmd:$(($1 + 1)):1}
  [[ -n "$nx" && "$nx" != ' ' && "$nx" != $'\t' && "$nx" != '"' ]]
}

n=${#cmd}
q=
for ((i = 0; i < n; i++)); do
  c=${cmd:i:1}
  if [[ "$q" == "'" ]]; then
    if [[ "$c" == "'" ]]; then q=; else word+=$c; fi
    continue
  fi
  if [[ "$q" == '"' ]]; then
    case "$c" in
      '"') q= ;;
      "\\")
        # Inside double quotes a backslash escapes only $ " \ (` is rejected above).
        nx=${cmd:i+1:1}
        case "$nx" in
          '$' | '"' | "\\") word+=$nx; i=$((i + 1)) ;;
          *) word+="\\" ;;
        esac ;;
      '$') if dollar_expands "$i"; then wvar=1; fi; word+=$c ;;
      *) word+=$c ;;
    esac
    continue
  fi
  case "$c" in
    ' ' | $'\t') end_word ;;
    ';') end_seg ;;
    '|')
      nx=${cmd:i+1:1}
      if [[ "$nx" == '|' ]]; then
        i=$((i + 1))
      elif [[ "$nx" == '&' ]]; then
        block "|& is not allowed"
      fi
      end_seg ;;
    '&')
      nx=${cmd:i+1:1}
      if [[ "$nx" == '&' ]]; then
        i=$((i + 1))
        end_seg
      elif [[ "$nx" == '>' ]] && ((inword == 0)); then
        redirect "$i" '&>/dev/null'
      else
        block "background jobs (&) are not allowed"
      fi ;;
    '>')
      if ((inword == 0)); then
        redirect "$i" '>/dev/null'
      elif [[ "$word" == 2 ]] && ((wquoted == 0)); then
        if [[ "${cmd:i:3}" == '>&1' ]]; then
          redirect $((i - 1)) '2>&1'
        else
          redirect $((i - 1)) '2>/dev/null'
        fi
      else
        block "redirections other than 2>&1 and >/dev/null are not allowed"
      fi ;;
    '<') block "redirections (<) are not allowed" ;;
    # Subshells, and in zsh glob qualifiers like *(e:...:) that run code.
    '(' | ')') block "unquoted parentheses are not allowed" ;;
    '#')
      if ((inword == 0)); then block "comments are not allowed"; fi
      word+=$c ;;
    "\\")
      ((i + 1 < n)) || block "a trailing backslash is not allowed"
      word+=${cmd:i+1:1}
      i=$((i + 1))
      inword=1
      wquoted=1 ;;
    "'" | '"')
      q=$c
      inword=1
      wquoted=1 ;;
    '$')
      if dollar_expands "$i"; then wvar=1; fi
      word+=$c
      inword=1 ;;
    '*' | '?' | '[' | '{')
      wglob=1
      word+=$c
      inword=1 ;;
    *)
      word+=$c
      inword=1 ;;
  esac
done
[[ -z "$q" ]] || block "unterminated quote"
end_seg

# ------------------------------------------------------------ command checks
# Set per command by check_segment: toks (dequoted words), cmdword, seg_has_var,
# seg_has_glob.

# For commands whose flags matter: reject anything bash would expand into words
# the flag checks don't see (variables, unquoted globs, brace expansion).
no_vars() {
  if ((seg_has_var == 1)); then
    block "variable expansion is not allowed in '$cmdword' commands"
  fi
  if ((seg_has_glob == 1)); then
    block "unquoted glob or brace patterns are not allowed in '$cmdword' commands; quote them"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_test_cmd() {
  local a=${toks[0]} b=${toks[1]:-} c=${toks[2]:-}
  case "$a" in
    pytest) return 0 ;;
    npm) [[ "$b" == test || ( "$b" == run && "$c" == test ) ]] ;;
    pnpm | yarn | cargo | go | make) [[ "$b" == test ]] ;;
    python | python3) [[ "$b" == -m && "$c" == pytest ]] ;;
    # --no stops npx from downloading a missing package from the registry.
    npx) local d=${toks[3]:-}
      [[ "$b" == --no && ( "$c" == jest || ( "$c" == vitest && "$d" == run ) ) ]] ;;
    *) return 1 ;;
  esac
}

# An argument or option value: block if it, or any piece after = : , @
# (--x=require=/y, file:///y), points outside the project.
check_path_word() {
  local t=$1 p
  local -a pieces=()
  IFS='=:,@' read -ra pieces <<<"$t" || true
  for p in "$t" "${pieces[@]}"; do
    if outside_path "$p"; then
      block "'$t' points the test runner outside the current project"
    fi
  done
}

# npm, pnpm and yarn: before --, only a few package-manager flags (their parsers
# accept abbreviations and config overrides); after --, the script's runner.
check_pm_args() {
  local i t
  for ((i = $1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if [[ "$t" == -- ]]; then
      check_node_args $((i + 1))
      return 0
    fi
    case "$t" in
      --silent | -s | --if-present) ;;
      -*) block "'$t' is not allowed for ${toks[0]}; put test-runner options after --" ;;
      *) check_path_word "$t" ;;
    esac
  done
}

# jest and vitest. Long names are compared lowercase without - or _, because
# both accept --runInBand, --run-in-band and --runinband alike.
check_node_args() {
  local i t n name val rest done_opts=0 r
  local -a rs
  for ((i = $1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if ((done_opts == 1)) || [[ "$t" != -* ]]; then
      check_path_word "$t"
      continue
    fi
    if [[ "$t" == -- ]]; then
      done_opts=1
      continue
    fi
    if [[ "$t" == --* ]]; then
      n=$(lower "${t#--}")
      name=${n%%=*}
      name=${name//[-_]/}
      val=
      [[ "$t" == *=* ]] && val=${t#*=}
      case "$name" in
        runinband | ci | verbose | silent | bail | testnamepattern | testpathpattern \
          | testpathpatterns | testpathignorepatterns | onlychanged | changedsince | lastcommit \
          | findrelatedtests | listtests | maxworkers | minworkers | passwithnotests \
          | detectopenhandles | forceexit | nostacktrace | colors | expand | errorondeprecated \
          | logheapusage | usestderr | json | randomize | seed | showseed | shard | testtimeout \
          | hooktimeout | selectprojects | onlyfailures | run | hideskippedtests | isolate \
          | fileparallelism | allowonly | retry | project | changed | sequence.shuffle \
          | sequence.seed) ;;
        pool)
          case "$(lower "$val")" in
            threads | forks | vmthreads | vmforks) ;;
            *) block "'$t' needs a built-in pool, attached (--pool=forks)" ;;
          esac ;;
        reporter | reporters)
          # Built-in reporters only, attached; anything else can be a module path.
          [[ -n "$val" ]] || block "'$t' needs its value attached (--reporter=NAME)"
          IFS=',' read -ra rs <<<"$(lower "$val")" || true
          ((${#rs[@]} > 0)) || block "'$t' has no reporter"
          for r in "${rs[@]}"; do
            case "$r" in
              default | verbose | dot | basic | tap | tap-flat | json | junit | summary \
                | github-actions | hanging-process | spec | list | min | progress | tree) ;;
              *) block "'$t' loads a reporter module" ;;
            esac
          done ;;
        no*)
          case "${name#no}" in
            cache | colors | coverage | watch | watchman | isolate | fileparallelism) ;;
            *) block "'$t' is not an allowlisted test-runner option" ;;
          esac ;;
        *) block "'$t' is not an allowlisted test-runner option" ;;
      esac
      [[ -z "$val" ]] || check_path_word "$val"
      continue
    fi
    # Short options: -i -b -e -f take no value; -t and -w take one, attached
    # or in the next word. Bundles are rejected.
    rest=${t:2}
    case "${t:1:1}" in
      i | b | e | f) [[ -z "$rest" ]] || block "bundled short options such as '$t' are not allowed" ;;
      t | w) [[ -z "$rest" ]] || check_path_word "$rest" ;;
      *) block "'$t' is not an allowlisted test-runner option" ;;
    esac
  done
}

# pytest (argparse). Long options must be spelled out in full; abbreviations
# are rejected rather than resolved.
check_pytest_args() {
  local i t name val s j ch rest done_opts=0
  for ((i = $1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if ((done_opts == 1)) || [[ "$t" != -* ]]; then
      # @file reads more arguments from a file the hook never sees.
      [[ "$t" != @* ]] || block "'$t' reads pytest arguments from a file"
      check_path_word "$t"
      continue
    fi
    if [[ "$t" == -- ]]; then
      done_opts=1
      continue
    fi
    if [[ "$t" == --* ]]; then
      name=${t#--}
      name=${name%%=*}
      val=
      [[ "$t" == *=* ]] && val=${t#*=}
      case "$name" in
        verbose | quiet | exitfirst | lf | last-failed | ff | failed-first | nf | new-first \
          | sw | stepwise | sw-skip | stepwise-skip | lfnf | last-failed-no-failures | co \
          | collect-only | collectonly | fixtures | fixtures-per-test | markers | strict-markers \
          | strict-config | strict | showlocals | no-showlocals | no-header | no-summary \
          | disable-warnings | disable-pytest-warnings | runxfail | full-trace | setup-show \
          | setup-only | setup-plan | doctest-modules | doctest-continue-on-failure | cache-show \
          | cache-clear | continue-on-collection-errors | no-cov | benchmark-skip \
          | benchmark-disable | benchmark-only | version | help | maxfail | tb | capture \
          | durations | durations-min | deselect | ignore | ignore-glob | color | code-highlight \
          | doctest-glob | show-capture | log-level | log-cli-level | timeout | count \
          | numprocesses | maxprocesses | reruns | reruns-delay | only-rerun | verbosity) ;;
        import-mode)
          case "$val" in '' | prepend | append | importlib) ;; *) block "'$t' has an unknown import mode" ;; esac ;;
        *) block "'$t' is not an allowlisted pytest option" ;;
      esac
      [[ -z "$val" ]] || check_path_word "$val"
      continue
    fi
    # Short options may be bundled, and the first one that takes a value takes
    # the rest of the word (or the next word): -xvs, -kfoo, -rA, -p no:NAME.
    s=${t:1}
    for ((j = 0; j < ${#s}; j++)); do
      ch=${s:j:1}
      rest=${s:j+1}
      case "$ch" in
        v | q | x | s | l) ;;
        # -W is left out: a warning filter's category (-W ignore::pkg.Warning) is imported.
        k | m | r | n)
          [[ -z "$rest" ]] || check_path_word "$rest"
          break ;;
        p)
          # -p loads any importable module as a plugin; only -p no:NAME
          # (disable a plugin) is allowed.
          [[ -n "$rest" ]] || rest=${toks[i + 1]:-}
          [[ "$rest" == no:* ]] || block "'$t' loads a pytest plugin"
          break ;;
        *) block "'$t' is not an allowlisted pytest option" ;;
      esac
    done
  done
}

# go test. Go's flag package accepts -flag, --flag and -test.flag.
check_go_args() {
  local i t f name val
  for ((i = $1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if [[ "$t" != -* ]]; then
      check_path_word "$t"
      continue
    fi
    [[ "$t" != -- ]] || block "'--' is not allowed for go test"
    f=${t#-}
    f=${f#-}
    f=${f#test.}
    name=${f%%=*}
    val=
    [[ "$f" == *=* ]] && val=${f#*=}
    case "$name" in
      v | race | short | failfast | json | cover | benchmem | x | n | a | msan | asan \
        | trimpath | fullpath)
        case "$val" in '' | true | false) ;; *) block "'$t' takes true or false" ;; esac ;;
      run | skip | count | timeout | parallel | p | cpu | tags | bench | benchtime | coverpkg \
        | list | vet) ;;
      covermode)
        case "$val" in '' | set | count | atomic) ;; *) block "'$t' has an unknown cover mode" ;; esac ;;
      shuffle)
        case "$val" in '' | on | off | [0-9]*) ;; *) block "'$t' has an unknown shuffle value" ;; esac ;;
      mod)
        # -mod=mod rewrites go.mod and downloads modules; a separate value
        # word would skip this check, so it must be attached.
        case "$val" in readonly | vendor) ;; *) block "'$t' must be -mod=readonly or -mod=vendor" ;; esac ;;
      *) block "'$t' is not an allowlisted go test option" ;;
    esac
    [[ -z "$val" ]] || check_path_word "$val"
  done
}

# cargo test: cargo options, then libtest options after --.
check_cargo_args() {
  local i t name val s j ch rest libtest=0
  for ((i = $1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if [[ "$t" == -- ]]; then
      ((libtest == 0)) || block "a second '--' is not allowed for cargo test"
      libtest=1
      continue
    fi
    if [[ "$t" != -* ]]; then
      check_path_word "$t"
      continue
    fi
    if [[ "$t" == --* ]]; then
      name=${t#--}
      name=${name%%=*}
      val=
      [[ "$t" == *=* ]] && val=${t#*=}
      if ((libtest == 0)); then
        case "$name" in
          workspace | all | lib | bins | bin | tests | test | benches | bench | examples | example \
            | doc | all-targets | no-fail-fast | package | exclude | features | all-features \
            | no-default-features | release | profile | locked | frozen | offline | quiet | verbose \
            | jobs | no-run | color | message-format | keep-going | ignore-rust-version | target) ;;
          *) block "'$t' is not an allowlisted cargo test option" ;;
        esac
      else
        case "$name" in
          nocapture | no-capture | test-threads | exact | ignored | include-ignored | skip | list \
            | show-output | quiet | color | test | bench) ;;
          format)
            case "$val" in '' | pretty | terse) ;; *) block "'$t' has an unknown format" ;; esac ;;
          *) block "'$t' is not an allowlisted test-binary option" ;;
        esac
      fi
      [[ -z "$val" ]] || check_path_word "$val"
      continue
    fi
    s=${t:1}
    for ((j = 0; j < ${#s}; j++)); do
      ch=${s:j:1}
      rest=${s:j+1}
      if ((libtest == 1)); then
        [[ "$ch" == q ]] || block "'$t' is not an allowlisted test-binary option"
        continue
      fi
      case "$ch" in
        q | v | r) ;;
        p | F | j)
          [[ -z "$rest" ]] || check_path_word "$rest"
          break ;;
        *) block "'$t' is not an allowlisted cargo test option" ;;
      esac
    done
  done
}

check_test_flags() {
  local t i
  cwd_ok || block "the working directory is outside the project"
  case "${toks[0]}" in
    pytest) check_pytest_args 1 ;;
    python | python3) check_pytest_args 3 ;;
    npm) if [[ "${toks[1]}" == run ]]; then check_pm_args 3; else check_pm_args 2; fi ;;
    pnpm | yarn) check_pm_args 2 ;;
    npx) if [[ "${toks[2]}" == jest ]]; then check_node_args 3; else check_node_args 4; fi ;;
    cargo) check_cargo_args 2 ;;
    go) check_go_args 2 ;;
    make)
      # make runs whatever the Makefile says, so allow only plain "make test" with a
      # few scheduling flags (no other targets, variables, -C, -f, -E, ...).
      for ((i = 2; i < ${#toks[@]}; i++)); do
        t=${toks[i]}
        [[ "$t" =~ ^(-j[0-9]*|--jobs(=[0-9]+)?|-k|--keep-going|-s|--silent|--quiet)$ ]] \
          || block "'$t' is not allowed for make test"
      done ;;
  esac
}

# cd only inside the project. The Bash tool keeps its working directory between
# calls, so a cd elsewhere would point later test runs, or git with another
# repo's .git/config (pagers, diff drivers), at a tree outside the project.
check_cd() {
  local d
  ((${#toks[@]} == 2)) || block "cd needs exactly one directory"
  d=${toks[1]}
  ((seg_has_var == 0 && seg_has_glob == 0)) || block "cd with variables or globs is not allowed"
  case "$d" in
    # A bare name is looked up in CDPATH first.
    /* | . | ./*) ;;
    *) block "cd needs ./dir or an absolute path inside the project" ;;
  esac
  cwd_ok || block "the working directory is outside the project"
  if outside_path "$d"; then
    block "'$d' is outside the project; cd only inside it"
  fi
}

check_git() {
  local i=1 n=${#toks[@]} t sub
  while ((i < n)); do
    case "${toks[i]}" in
      --no-pager | --no-optional-locks) i=$((i + 1)) ;;
      -C)
        # Another repo's .git/config can run programs (pager, diff drivers).
        ((i + 1 < n)) || block "git -C needs a directory"
        if outside_path "${toks[i + 1]}"; then
          block "git -C '${toks[i + 1]}' is outside the project"
        fi
        i=$((i + 2)) ;;
      *) break ;;
    esac
  done
  ((i < n)) || block "git needs an allowlisted subcommand"
  sub=${toks[i]}
  case "$sub" in
    diff | log | show | status | grep | blame | ls-files | rev-parse | shortlog \
      | merge-base | cat-file | ls-tree) ;;
    *) block "git subcommand '$sub' is not on the read-only allowlist" ;;
  esac
  for ((i = i + 1; i < n; i++)); do
    t=${toks[i]}
    case "$t" in
      # --output writes a file. Long options may be abbreviated (--out=x).
      --ou | --out | --outp | --outpu | --ou=* | --out=* | --outp=* | --outpu=* | --output*)
        block "git '$t' writes a file" ;;
      --ext* | --exec* | --textc*)
        block "git '$t' can run external programs" ;;
    esac
    if [[ "$sub" == cat-file ]]; then
      # --textconv and --filters run configured programs; both may be abbreviated.
      case "$t" in
        --te* | --fi*) block "git cat-file '$t' can run external programs" ;;
      esac
    fi
    if [[ "$sub" == grep ]]; then
      # Short options may be bundled (-nO), so check any single-dash token.
      case "$t" in
        --op*) block "git grep '$t' can run a pager program" ;;
        --*) ;;
        -*O*) block "git grep '$t' can run a pager program" ;;
      esac
    fi
  done
}

# Best effort (see header): refuse words that name well-known secret files.
check_secrets() {
  local i t
  for ((i = 1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    case "$t" in
      *.ssh | *.ssh/* | *.gnupg* | *.aws/* | *.aws | *.kube/* | *.docker/config.json \
        | *.netrc | *.npmrc | *.pypirc | *.git-credentials | *.credentials.json | *id_rsa* \
        | *id_ed25519* | *id_ecdsa* | *gh/hosts.yml | .env | */.env | .env.local | */.env.local \
        | .env.*.local | */.env.*.local | .env.production | */.env.production \
        | .env.development | */.env.development | .env.staging | */.env.staging \
        | .env.test | */.env.test | *.config/gcloud | *.config/gcloud/* | *.azure | *.azure/* \
        | *.pgpass | *.cargo/credentials* | *credentials.tfrc.json)
        block "'$t' looks like a secret file" ;;
    esac
  done
}

# $1 is the index of the command in segs.
check_segment() {
  local idx=$1 i t
  toks=()
  IFS=$US read -ra toks <<<"${segs[idx]}" || true
  ((${#toks[@]} > 0)) || return 0 # empty command
  cmdword=${toks[0]}
  seg_has_var=${seg_var[idx]}
  seg_has_glob=${seg_glob[idx]}
  # Plain first word only: "rm", \rm, $X and the like fail.
  [[ "${seg_lit[idx]}" == 1 ]] || block "'$cmdword' must be a plain, unquoted command name"

  for t in "${toks[@]}"; do
    case "$t" in
      *--output*) block "'--output' could write a file" ;;
    esac
  done
  check_secrets

  case "$cmdword" in
    pwd | ls | cat | head | wc | grep | cut | jq | diff | echo | basename \
      | dirname | realpath | which | true | stat) ;;
    cd) check_cd ;;
    tail)
      no_vars
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          # Following a file never exits, so the call hangs until it times out.
          --f* | --retry*) block "tail '${toks[i]}' follows the file and never exits" ;;
          --*) ;;
          -*[fF]*) block "tail '${toks[i]}' follows the file and never exits" ;;
        esac
      done ;;
    printf)
      no_vars
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          -v*) block "printf -v assigns variables" ;;
        esac
      done ;;
    file)
      no_vars
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          --co*) block "file '${toks[i]}' writes a compiled magic file" ;;
          --*) ;;
          -*C*) block "file '${toks[i]}' writes a compiled magic file" ;;
        esac
      done ;;
    find)
      no_vars
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          -exec | -execdir | -ok | -okdir | -delete | -fprint | -fprint0 | -fprintf | -fls)
            block "find '${toks[i]}' can run commands or write files" ;;
        esac
      done ;;
    rg)
      no_vars
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          --pre* | --hostname-bin*) block "rg '${toks[i]}' runs an external program" ;;
        esac
      done ;;
    sort)
      no_vars
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          # -o/--output write a file; --compress-program runs a program.
          # Long options may be abbreviated; short ones bundled (-ro).
          --o* | --co*) block "sort '${toks[i]}' writes a file or runs a program" ;;
          --*) ;;
          -*o*) block "sort '${toks[i]}' writes a file or runs a program" ;;
        esac
      done ;;
    git)
      no_vars
      cwd_ok || block "the working directory is outside the project"
      check_git ;;
    *)
      if ((ALLOW_TESTS == 1)) && is_test_cmd; then
        no_vars
        check_test_flags
      else
        block "'$cmdword' is not an allowlisted read-only command"
      fi ;;
  esac
}

for ((k = 0; k < ${#segs[@]}; k++)); do
  check_segment "$k"
done

ALLOWED=1
exit 0
