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
# not. It does not parse shell; it rejects anything it cannot reason about
# (newlines, command substitution, redirections, background jobs), splits the
# rest naively on && || ; | (over-splitting can only add segments to check),
# and requires each segment's first word to be an exact, unquoted allowlisted
# command. A separator inside quotes ("x; ls ") would cut a command's own flags
# off into the next segment, so flag checks look at everything from the
# segment to the end of the command, not just the segment. Quotes, backslashes and `$` are stripped before flag checks so that
# obfuscated flags such as -ex''ec are still caught.
#
# Test runners (npm test, pytest, cargo test, go test, ...) are opt-in via
# --allow-tests. They EXECUTE PROJECT CODE (package.json scripts, Makefiles,
# conftest.py, build.rs) with the user's privileges, so only enable them for
# agents that review trusted code. They can also write files (snapshots,
# __pycache__, .pytest_cache, coverage output, build dirs, lockfile churn), so
# "read-only" is only best effort for them.
#
# It assumes bash syntax. Parentheses are rejected, which covers zsh's glob
# qualifiers, but zsh's EXTENDED_GLOB operators (^x, x#) are not; leave that
# option off if the Bash tool runs zsh.
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

# ------------------------------------------- whole-command syntax rejections
if [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]]; then
  block "multi-line commands are not allowed"
fi
# shellcheck disable=SC2016 # the $( and ${ patterns are meant literally
case "$cmd" in
  *'`'* | *'$('* | *'<('* | *'>('* | *'${'*)
    block "command or process substitution and \${...} expansion are not allowed" ;;
  # $'...' decodes escapes such as \x2d, which would hide flags from the checks below.
  *"\$'"* | *'$"'*)
    block "\$'...' and \$\"...\" quoting are not allowed" ;;
  # Subshells, and in zsh glob qualifiers like *(e:...:) that run code. This also
  # rejects ( inside quotes, such as jq 'map(.a)'; use the Read tool instead.
  *'('* | *')'*)
    block "parentheses are not allowed, even inside quotes" ;;
esac

# Strip the exact harmless redirection forms. Each must start a word and end a
# word, so things like ca>/dev/nullt or ls2>&1 are not mangled into something
# that looks allowed. Replace with a space, and repeat until stable because
# adjacent forms share a separator.
strip_re='(^|[[:space:]])(2>&1|>/dev/null|2>/dev/null|&>/dev/null)([[:space:];|&]|$)'
rest=$cmd
while :; do
  next=$(printf '%s' "$rest" | sed -E "s#${strip_re}#\\1 \\3#g")
  if [[ "$next" == "$rest" ]]; then break; fi
  rest=$next
done

case "$rest" in
  *'>'* | *'<'*)
    block "redirections (< or >) are not allowed" ;;
esac

# && is a separator; any other & is a background job (or |&).
rest=${rest//&&/;}
case "$rest" in
  *'&'*) block "background jobs (&) are not allowed" ;;
esac
rest=${rest//|/;}

# ------------------------------------------------------------ segment checks
dollar_re="[\$][^[:space:]'\")]"

# Words after the first, with quotes, backslashes and $ removed (see header).
# Sets: sq (squashed segment), toks (squashed words).
squash() {
  sq=${1//[\'\"\\]/}
  sq=${sq//\$/}
  toks=()
  read -ra toks <<<"$sq" || true
}

# True if the segment has an unquoted glob or brace character (* ? [ {). Bash
# expands those into words the checks never see: -{de,x}lete becomes -delete,
# and * can expand to a hostile file name such as --pre=sh. Segments only start
# where bash starts a command, so scanning from an unquoted state matches bash.
has_unquoted_expansion() {
  local s=$1 i c q=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if [[ "$q" == "'" ]]; then
      [[ "$c" == "'" ]] && q=
    elif [[ "$q" == '"' ]]; then
      if [[ "$c" == "\\" ]]; then
        i=$((i + 1))
      elif [[ "$c" == '"' ]]; then
        q=
      fi
    else
      case "$c" in
        "\\") i=$((i + 1)) ;;
        "'" | '"') q=$c ;;
        '*' | '?' | '[' | '{') return 0 ;;
      esac
    fi
  done
  return 1
}

# For commands whose flags matter: reject anything that could turn into words
# the flag checks don't see (variables, unquoted globs, brace expansion).
no_vars() {
  if [[ "$1" =~ $dollar_re ]]; then
    block "variable expansion is not allowed in '$cmdword' commands"
  fi
  if has_unquoted_expansion "$1"; then
    block "unquoted glob or brace patterns are not allowed in '$cmdword' commands; quote them"
  fi
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

check_test_flags() {
  local t i a=${toks[0]} first=2
  [[ "$a" == npm && "${toks[1]:-}" == run ]] && first=3
  [[ "$a" == python || "$a" == python3 ]] && first=3
  [[ "$a" == pytest ]] && first=1

  # npm, pnpm and yarn options (before --) configure the package manager, and
  # its option parser accepts abbreviations, so allow only a few known-safe ones.
  if [[ "$a" == npm || "$a" == pnpm || "$a" == yarn ]]; then
    for ((i = first; i < ${#toks[@]}; i++)); do
      t=${toks[i]}
      [[ "$t" == -- ]] && break
      case "$t" in
        --silent | -s | --if-present) ;;
        -*) block "'$t' is not allowed for $a; put test-runner options after --" ;;
      esac
    done
  fi

  # make runs whatever the Makefile says, so allow only plain "make test" with a
  # few scheduling flags (no other targets, variables, -C, -f, -E, ...).
  if [[ "$a" == make ]]; then
    for ((i = 2; i < ${#toks[@]}; i++)); do
      t=${toks[i]}
      [[ "$t" =~ ^(-j[0-9]*|--jobs(=[0-9]+)?|-k|--keep-going|-s|--silent|--quiet)$ ]] \
        || block "'$t' is not allowed for make test"
    done
  fi

  for ((i = 1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    # Go's flag package accepts --flag and -test.flag as well as -flag.
    if [[ "$a" == go ]]; then
      [[ "$t" == --* ]] && t=${t#-}
      [[ "$t" == -test.* ]] && t=-${t#-test.}
    fi
    # pytest (argparse) accepts bundled and attached short options: -xcFILE, -oK=V.
    if [[ "$a" == pytest || "$a" == python || "$a" == python3 ]] && ((i >= first)); then
      case "$t" in
        --*) ;;
        -*[co]*) block "'$t' sets pytest's config file or ini options" ;;
      esac
    fi
    case "$t" in
      # Snapshot, golden-file and autofix modes.
      -u | --update* | --snapshot-update* | --fix* | --write* | -update* | -fix* | -write* \
        | --bless* | --force-regen* | --regen* | --overwrite* | --accept*)
        block "'$t' would modify files" ;;
      # Options that write to a chosen path or run another program.
      --junitxml* | --junit-xml* | --output* | --log-file* | --resultlog* \
        | --result-log* | --basetemp* | --cov* | --report* | --target-dir* \
        | --config* | -Z* | -coverprofile* | -cpuprofile* | -memprofile* | -blockprofile* \
        | -mutexprofile* | -trace* | -outputdir* | -exec* | -toolexec* | -overlay* | -fuzz* \
        | -o | -o=* | -c | --script-shell* | --userconfig* | --globalconfig*)
        block "'$t' writes files or runs another program" ;;
      # Options that point the runner at a project other than the current one.
      --prefix* | --manifest-path* | --rootdir* | --dir | --dir=* | --cwd* | -C | -C=*)
        block "'$t' runs tests outside the current project" ;;
    esac
  done
}

check_git() {
  local i=1 n=${#toks[@]} t sub
  while ((i < n)); do
    case "${toks[i]}" in
      --no-pager | --no-optional-locks) i=$((i + 1)) ;;
      -C)
        ((i + 1 < n)) || block "git -C needs a directory"
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
        | .env.*.local | */.env.*.local | .env.production | */.env.production)
        block "'$t' looks like a secret file" ;;
    esac
  done
}

# $1 is the segment, $2 the segment plus every later one (see header).
check_segment() {
  local seg=$1 tail=$2
  local -a raw
  raw=()
  read -ra raw <<<"$seg" || true
  ((${#raw[@]} > 0)) || return 0 # empty segment

  cmdword=${raw[0]}
  squash "$tail"
  # Exact, unquoted first word (anything like "rm", \rm, $X, FOO=1 cmd fails).
  if [[ "${toks[0]:-}" != "$cmdword" ]]; then
    block "'$cmdword' is not an allowlisted command"
  fi

  case "$sq" in
    *--output*) block "'--output' could write a file" ;;
  esac
  check_secrets

  local i t
  case "$cmdword" in
    cd | pwd | ls | cat | head | wc | grep | cut | jq | diff | echo | basename \
      | dirname | realpath | which | true | stat) ;;
    tail)
      no_vars "$tail"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          # Following a file never exits, so the call hangs until it times out.
          --f* | --retry*) block "tail '${toks[i]}' follows the file and never exits" ;;
          --*) ;;
          -*[fF]*) block "tail '${toks[i]}' follows the file and never exits" ;;
        esac
      done ;;
    printf)
      no_vars "$tail"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          -v*) block "printf -v assigns variables" ;;
        esac
      done ;;
    file)
      no_vars "$tail"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          --co*) block "file '${toks[i]}' writes a compiled magic file" ;;
          --*) ;;
          -*C*) block "file '${toks[i]}' writes a compiled magic file" ;;
        esac
      done ;;
    find)
      no_vars "$tail"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          -exec | -execdir | -ok | -okdir | -delete | -fprint | -fprint0 | -fprintf | -fls)
            block "find '${toks[i]}' can run commands or write files" ;;
        esac
      done ;;
    rg)
      no_vars "$tail"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          --pre* | --hostname-bin*) block "rg '${toks[i]}' runs an external program" ;;
        esac
      done ;;
    sort)
      no_vars "$tail"
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
      no_vars "$tail"
      check_git ;;
    *)
      if ((ALLOW_TESTS == 1)) && is_test_cmd; then
        saw_test=1
        no_vars "$tail"
        check_test_flags
      else
        block "'$cmdword' is not an allowlisted read-only command"
      fi ;;
  esac
}

saw_cd=0
saw_test=0
IFS=';' read -ra segments <<<"$rest" || true
for ((k = 0; k < ${#segments[@]}; k++)); do
  segment=${segments[k]}
  tail_text=$segment
  for ((j = k + 1; j < ${#segments[@]}; j++)); do
    tail_text+=" ${segments[j]}"
  done
  cmdword=
  check_segment "$segment" "$tail_text"
  [[ "${cmdword:-}" == cd ]] && saw_cd=1
done
# cd would let a test runner run another tree's code, which the per-runner
# directory flags above are meant to prevent.
if ((saw_cd && saw_test)); then
  block "cd and a test runner in the same command are not allowed"
fi

ALLOWED=1
exit 0
