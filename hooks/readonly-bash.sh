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
# command. Quotes, backslashes and `$` are stripped before flag checks so that
# obfuscated flags such as -ex''ec are still caught.
#
# Test runners (npm test, pytest, cargo test, go test, ...) are opt-in via
# --allow-tests. They execute project code and can write files (snapshots,
# __pycache__, .pytest_cache, coverage output, build dirs, lockfile churn), so
# "read-only" is only best effort for them.

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
case "$cmd" in
  *'`'* | *'$('* | *'<('* | *'>('* | *'${'*)
    block "command or process substitution and \${...} expansion are not allowed" ;;
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

# Reject variable expansion in a segment (used for commands whose flags matter).
no_vars() {
  if [[ "$1" =~ $dollar_re ]]; then
    block "variable expansion is not allowed in '$cmdword' commands"
  fi
}

is_test_cmd() {
  local a=${toks[0]} b=${toks[1]:-} c=${toks[2]:-}
  case "$a" in
    pytest) return 0 ;;
    npm) [[ "$b" == test || ( "$b" == run && "$c" == test ) ]] ;;
    pnpm | yarn | cargo | go | make) [[ "$b" == test ]] ;;
    python | python3) [[ "$b" == -m && "$c" == pytest ]] ;;
    npx) [[ "$b" == jest || ( "$b" == vitest && "$c" == run ) ]] ;;
    *) return 1 ;;
  esac
}

check_test_flags() {
  local t i
  for ((i = 1; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    case "$t" in
      # Snapshot, golden-file and autofix modes.
      -u | --update* | --snapshot-update* | --fix* | --write* | -update* | -fix* | -write* \
        | --bless* | --force-regen* | --regen* | --overwrite* | --accept*)
        block "'$t' would modify files" ;;
      # Options that write to a chosen path or run another program.
      --junitxml* | --junit-xml* | --output* | --outputFile* | --log-file* | --resultlog* \
        | --result-log* | --basetemp* | --cov* | --coverage* | --report* | --target-dir* \
        | --config* | -Z* | -coverprofile* | -cpuprofile* | -memprofile* | -blockprofile* \
        | -mutexprofile* | -trace* | -outputdir* | -exec* | -toolexec* | -overlay* | -fuzz* \
        | -o | -o=* | -c | --script-shell* | --userconfig* | --globalconfig*)
        block "'$t' writes files or runs another program" ;;
    esac
    if [[ "$cmdword" == make ]]; then
      case "$t" in
        -f | --file* | --makefile* | -C | --directory* | *=*)
          block "'$t' is not allowed for make" ;;
      esac
    fi
  done
}

check_git() {
  local i=1 n=${#toks[@]} t sub
  while ((i < n)); do
    case "${toks[i]}" in
      --no-pager) i=$((i + 1)) ;;
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
      --ext* | --exec*)
        block "git '$t' can run external programs" ;;
    esac
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

check_segment() {
  local seg=$1
  local -a raw
  raw=()
  read -ra raw <<<"$seg" || true
  ((${#raw[@]} > 0)) || return 0 # empty segment

  cmdword=${raw[0]}
  squash "$seg"
  # Exact, unquoted first word (anything like "rm", \rm, $X, FOO=1 cmd fails).
  if [[ "${toks[0]:-}" != "$cmdword" ]]; then
    block "'$cmdword' is not an allowlisted command"
  fi

  case "$sq" in
    *--output*) block "'--output' could write a file" ;;
  esac

  local i t
  case "$cmdword" in
    cd | pwd | ls | cat | head | tail | wc | grep | cut | jq | diff | echo | basename \
      | dirname | realpath | which | true | stat) ;;
    printf)
      no_vars "$seg"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          -v*) block "printf -v assigns variables" ;;
        esac
      done ;;
    file)
      no_vars "$seg"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          --co*) block "file '${toks[i]}' writes a compiled magic file" ;;
          --*) ;;
          -*C*) block "file '${toks[i]}' writes a compiled magic file" ;;
        esac
      done ;;
    find)
      no_vars "$seg"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          -exec | -execdir | -ok | -okdir | -delete | -fprint | -fprint0 | -fprintf | -fls)
            block "find '${toks[i]}' can run commands or write files" ;;
        esac
      done ;;
    rg)
      no_vars "$seg"
      for ((i = 1; i < ${#toks[@]}; i++)); do
        case "${toks[i]}" in
          --pre* | --hostname-bin*) block "rg '${toks[i]}' runs an external program" ;;
        esac
      done ;;
    sort)
      no_vars "$seg"
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
      no_vars "$seg"
      check_git ;;
    *)
      if ((ALLOW_TESTS == 1)) && is_test_cmd; then
        no_vars "$seg"
        check_test_flags
      else
        block "'$cmdword' is not an allowlisted read-only command"
      fi ;;
  esac
}

IFS=';' read -ra segments <<<"$rest" || true
for segment in "${segments[@]}"; do
  check_segment "$segment"
done

ALLOWED=1
exit 0
