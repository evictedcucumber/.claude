#!/usr/bin/env bash
#
# Table-driven tests for readonly-bash.sh. Run: hooks/test-readonly-bash.sh
#
# Each case is "<expect> <mode> <command>", where expect is allow (exit 0) or
# block (exit 2), and mode is "ro" (no flags) or "tests" (--allow-tests).
# Add a case for every bypass you fix so it stays fixed.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook=$here/readonly-bash.sh
fail=0
count=0
# Guards against a truncated case table passing with "all 0 cases passed".
min_cases=150

# The hook fails OPEN if Claude Code can't execute it, so check the mode bit.
if [[ ! -x "$hook" ]]; then
  echo "FAIL: $hook is not executable (run: chmod +x $hook)"
  fail=1
fi

run() {
  local expect=$1 mode=$2 cmd=$3 rc want
  local -a args=()
  [[ "$mode" == tests ]] && args=(--allow-tests)
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | bash "$hook" "${args[@]}" >/dev/null 2>&1
  rc=$?
  [[ "$expect" == allow ]] && want=0 || want=2
  count=$((count + 1))
  if [[ $rc -ne $want ]]; then
    printf 'FAIL: expected %s (exit %d), got exit %d [%s]: %s\n' "$expect" "$want" "$rc" "$mode" "$cmd"
    fail=1
  fi
}

while IFS= read -r line; do
  [[ -z "$line" || "$line" == '#'* ]] && continue
  read -r expect mode cmd <<<"$line"
  if [[ ! "$expect" =~ ^(allow|block)$ || ! "$mode" =~ ^(ro|tests)$ || -z "$cmd" ]]; then
    echo "FAIL: malformed case: $line"
    fail=1
    continue
  fi
  run "$expect" "$mode" "$cmd"
done <<'CASES'
# --- plain read-only commands
allow ro ls -la
allow ro cat README.md
allow ro grep -rn foo . 2>/dev/null | head -5
allow ro ls 2>&1 | head
allow ro cd /tmp && ls
allow ro find . -name '*.md'
allow ro find . -name "*.md" -type f
allow ro find . -name \*.md
allow ro cat *.md
allow ro grep -rn TODO src
allow ro jq .a f
allow ro rg -n foo src
allow ro sort -u file
allow ro tail -n 20 file
allow ro jq . settings.json
allow ro stat -c %n file
allow ro printf '%s\n' hi
# --- git
allow ro git status
allow ro git status --porcelain
allow ro git --no-optional-locks status
allow ro git --no-pager log --oneline -n 5
allow ro git diff HEAD~1
allow ro git -C sub log
allow ro git cat-file -p HEAD
block ro git -c core.pager=x log
block ro git push
block ro git diff --output=x
block ro git diff --out=x
block ro git show --ext-diff
block ro git log -p --textconv
block ro git cat-file --textconv HEAD:x
block ro git cat-file --filters HEAD:x
block ro git cat-file --fil HEAD:x
block ro git cat-file --tex HEAD:x
block ro git grep -O foo
block ro git grep --open-files-in-pager foo
block ro git log $X
block ro git log -- *.md
allow ro git log -- '*.md'
# --- shell syntax
block ro ls; rm x
block ro ls && rm x
block ro ls || rm x
block ro ls | sh
block ro ls &
block ro (rm x)
block ro echo hi > x
block ro cat < x
block ro cat <<<x
block ro wc -l $(ls)
block ro wc -l `ls`
block ro cat ${HOME}/x
block ro diff <(ls) x
block ro "rm" x
block ro \rm x
block ro $X
block ro FOO=1 ls
block ro ls >/dev/nullx
# $'...' decodes escapes, so flags can be spelled in hex.
block ro find . $'-\x64elete'
block ro rg $'--\x70re=sh' foo
block ro sort $'-\x6f' out in
block ro cat $"x"
# a quoted separator must not cut a command's flags off into the next segment
block ro find . -name "x; ls " -delete
block ro find . -name 'x| ls ' -exec ls
block ro rg foo "x; ls " --pre=sh
block ro sort "x; ls " -o out
block ro find . -name "x; ls " -{de,x}lete
block tests go test "x; ls " --exec=sh
allow ro find . -name '*.md' | head -5
allow ro git log --oneline | head
# brace expansion builds flags out of pieces
block ro find . -{de,x}lete
block ro git diff --{out,x}put=x
block ro sort -{o,x} out in
# parentheses: subshells, and zsh glob qualifiers that run code
block ro ls *(e:x:)
block ro jq 'map(.a)' f
block ro echo (
# --- per-command flags
block ro find . -delete
block ro find . -exec ls ;
block ro find . -exe\c ls
block ro find . -ex''ec ls
block ro find . -fprint x
block ro rg --pre=sh foo
# globs can expand to hostile file names such as --pre=sh
block ro rg foo *
block ro rg foo src/*
block ro sort *
block ro find * -name x
block ro tail *
allow ro rg -n 'a.*b' src
allow ro rg -n "a.*b" src
allow ro rg -g '*.md' foo
block ro sort -o out in
block ro sort --compress-program=sh in
block ro printf -v x hi
block ro file -C -m x
block ro tail -f log
block ro tail -F log
block ro tail -nf log
block ro tail --follow=name log
block ro sed -i s/a/b/ x
block ro rm -rf x
block ro curl https://example.com
# --- secret files (best effort)
block ro cat ~/.ssh/id_rsa
block ro cat ~/'.ssh'/config
block ro ls ~/.ssh
block ro cat ~/.claude/.credentials.json
block ro cat .env
block ro cat app/.env.local
block ro cat ~/.aws/credentials
block ro cat ~/.netrc
block ro cat ~/.config/gh/hosts.yml
allow ro cat .env.example
# --- test runners are off unless --allow-tests
block ro npm test
block ro pytest
allow tests npm test
allow tests npm run test
allow tests pytest -q tests
allow tests python -m pytest
allow tests cargo test
allow tests go test ./...
allow tests make test
allow tests npx --no jest
allow tests npx --no vitest run
block tests npx jest
block tests npx vitest run
block tests npm install
block tests npm test -- -u
block tests npm test -- --updateSnapshot
block tests pytest --snapshot-update
block tests pytest --cov=src
block tests pytest --rootdir=/tmp/x /tmp/x
block tests npm test --prefix /tmp/x
block tests cargo test --manifest-path /tmp/x/Cargo.toml
block tests go test -C /tmp/x ./...
block tests go test -exec sh ./...
block tests pnpm test --dir /tmp/x
block tests pnpm test --filter x
block tests yarn test --cwd /tmp/x
block tests make -f other.mk test
block tests make test CC=sh
block tests make test install
block tests make test -Cdir
block tests make test -sC dir
block tests make test -E x
block tests make test --eval x
allow tests make test -j4
allow tests make test -k -s
# Go accepts --flag and -test.flag
block tests go test --exec=sh ./...
block tests go test --toolexec=sh ./...
block tests go test --coverprofile=x ./...
block tests go test -test.coverprofile=x ./...
block tests go test --C /tmp/x ./...
block tests go test --o x
allow tests go test -run TestX -v ./...
# pytest attached and bundled short options
block tests pytest -cfoo.ini
block tests pytest -xcfoo.ini
block tests pytest -oaddopts=x
block tests python -m pytest -cfoo.ini
allow tests pytest -xvs tests
allow tests pytest -k foo tests
# npm, pnpm and yarn options before -- (the parser accepts abbreviations)
block tests npm test --script-sh=sh
block tests npm test --userc=x
block tests npm run test --x
block tests yarn test --foo
allow tests npm test --silent
allow tests npm test -- --runInBand
block tests npm test -- --updateSnapshot
allow tests cargo test --workspace
allow tests pnpm test
# cd would point a runner at another tree
block tests cd /tmp/x && npm test
block tests npm test; cd /tmp/x
allow tests cd sub
CASES

if ((count < min_cases)); then
  echo "FAIL: only $count cases ran (expected at least $min_cases)"
  fail=1
fi
if ((fail)); then
  echo "readonly-bash tests: FAILED ($count cases)"
  exit 1
fi
echo "readonly-bash tests: all $count cases passed"
