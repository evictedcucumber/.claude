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

# The project root is /repo, which doesn't need to exist (realpath -m).
# run <expect> <mode> <command> [cwd] [project-dir]
run() {
  local expect=$1 mode=$2 cmd=$3 cwd=${4:-/repo} proj=${5:-/repo} rc want
  local -a args=()
  [[ "$mode" == tests ]] && args=(--allow-tests)
  jq -n --arg c "$cmd" --arg d "$cwd" '{cwd: $d, tool_input: {command: $c}}' \
    | CLAUDE_PROJECT_DIR=$proj bash "$hook" "${args[@]}" >/dev/null 2>&1
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
allow ro cd ./sub && ls
block ro cd /tmp && ls
block ro cd sub
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
allow ro jq 'map(.a)' f
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
# cd would point a runner at another tree, even in a separate call (the
# Bash tool keeps its working directory)
block tests cd /tmp/x && npm test
block tests npm test; cd /tmp/x
block tests cd sub
# pytest --override-ini, --debug and --pastebin (and abbreviations)
block tests pytest --override-ini=addopts=--junitxml=x
block tests pytest --overr=addopts=x
block tests pytest --debug=x.log
block tests pytest --pastebin=all
block tests python -m pytest --override-ini=cache_dir=x
allow tests pytest -rA tests
# paths outside the project
block tests pytest /tmp/x
block tests pytest ../other
block tests pytest tests/../../other
block tests pytest ~/x
block tests go test ../other/...
block tests npm test -- /tmp/x
block tests npm test -- --testPathPattern=../x
allow tests pytest tests/unit
allow tests go test ./pkg/...
# jest and vitest directory and module options, in any case
block tests npm test -- --rootDir=/tmp/x
block tests npm test -- --rootDir=x
block tests npx --no jest --roots=x
block tests npx --no vitest run --root x
block tests npx --no vitest run -r x
block tests npx --no jest --globalSetup=x.js
block tests npx --no jest --setupFiles=x.js
block tests npx --no jest --testRunner=x
block tests npx --no jest --reporters=x
block tests npx --no jest --transform=x
block tests npx --no jest --testEnvironment=x
block tests npx --no vitest run --environment=x
# go linker and module-file options
block tests go test -ldflags=-extld=x ./...
block tests go test --ldflags=x ./...
block tests go test -modfile=x.mod ./...
# paths hidden after a second = or other separators; absolute paths inside the
# session's cwd (/repo in these tests) are fine
block tests npm test -- --node-option=require=/tmp/x.js
block tests npm test -- --require=a:/tmp/x
block tests npm test -- --x=file:///tmp/x
allow tests pytest /repo/tests/test_a.py
block tests pytest /repo/../x
block tests pytest /repox/tests
# jest -c and vitest -r with attached values; cargo -r is --release
block tests npx --no jest -c/tmp/evil.js
block tests npx --no jest -cx.js
block tests npx --no vitest run -r../up
block tests npm test -- -c x.js
allow tests npm test -- -t name
allow tests cargo test -r
# kebab-case aliases and more module or file options
block tests npx --no jest --global-setup=x
block tests npx --no jest --root-dir=x
block tests npx --no jest --testResultsProcessor=x
block tests npx --no jest --collectCoverage
block tests npx --no jest --collect-coverage
block tests npx --no jest --cacheDirectory=x
block tests npx --no vitest run --ui
block tests npx --no vitest run --api
# built-in reporters only
allow tests npx --no vitest run --reporter=verbose
allow tests npm test -- --reporters=default,summary
block tests npx --no vitest run --reporter ./x.js
block tests npx --no jest --reporters=./x.js
# go and cargo options that write files or change go.mod
block tests go test -c=true ./...
block tests go test -testlogfile=x ./...
block tests go test -test.gocoverdir=x ./...
block tests go test -mod=mod ./...
block tests go test -modcacherw ./...
allow tests go test -count=1 -race ./...
block tests cargo test -- --logfile out.txt
# pytest plugins, @argfiles, --pyargs, plugin report writers
block tests pytest -p antigravity
block tests pytest -pantigravity
block tests pytest -xpfoo
allow tests pytest -p no:cacheprovider
allow tests pytest -pno:cacheprovider
block tests pytest @args.txt
block tests pytest --pyargs pkg
block tests pytest --html=x.html
allow tests pytest -k test_connect
allow tests pytest -rfE
# quote-aware splitting: each command in a pipeline is checked on its own words
allow tests pytest -q | tail -20
allow tests npm test 2>&1 | head -50
allow tests npm test | sort -r
allow tests go test ./... | grep -v /site-packages/
block tests pytest -q | sh
allow ro grep 'a;b' file
allow ro rg 'a|b' src
allow ro grep '>' file
allow ro echo "a && b"
allow ro echo "a\"; rm x"
block ro echo "a\\"; rm x
block ro echo 'a\'; rm x
allow ro echo a\;rm x
allow ro ls >/dev/null 2>&1
block ro ls >>/dev/null
block ro echo hi 2>x
block ro ls 2>&1&
block ro ls # comment
block ro echo 'unterminated
block ro ls \
block ro cat $[1+1]
block ro "ls"
block ro ls; "rm" x
# allowlists: anything not listed is rejected
block tests pytest --junit-prefix=x
block tests pytest --rootd=x
block tests pytest --confcutdir=x
block tests npx --no jest --watch
block tests npx --no jest --clearCache
block tests go test -args -x
block tests go test -mod mod ./...
allow tests go test -mod=readonly ./...
allow tests go test -v=true -timeout 30s ./...
allow tests cargo test -p core --features x -- --nocapture --test-threads=1
block tests cargo test --timings
block tests cargo test -- -Z unstable-options
allow tests npx --no jest --run-in-band --ci -t name src
allow tests npx --no vitest run --pool=forks --no-isolate
block tests npx --no vitest run --pool ./x.js
# cd inside the project only, as ./dir or an absolute path
allow tests cd ./sub
allow tests cd .
allow tests cd /repo/packages/a && npm test
block tests cd ..
block tests cd ../x
block tests cd ./a/../..
block tests cd /tmp
block tests cd /repo/../tmp
block tests cd
block tests cd -
block tests cd ~
block tests cd -P ./a
block tests cd ./a ./b
# git -C and git from a directory outside the project
block ro git -C /tmp/other log
block ro git -C ../other diff
allow ro git -C /repo/sub log
# pytest -W imports the warning category's module
block tests pytest -W ignore::os.path.X
block tests pytest -Wignore::x.Y
# more secret files
block ro cat .env.development
block ro cat app/.env.test
block ro ls ~/.config/gcloud
block ro cat ~/.azure/accessTokens.json
block ro cat ~/.pgpass
block ro cat ~/.cargo/credentials.toml
block ro cat ~/.terraform.d/credentials.tfrc.json
CASES

# Working directory and project root. Each case is
# "<expect> <mode> <cwd> <project-dir> <command>".
while IFS= read -r line; do
  [[ -z "$line" || "$line" == '#'* ]] && continue
  read -r expect mode cwd proj cmd <<<"$line"
  run "$expect" "$mode" "$cmd" "$cwd" "$proj"
done <<'CASES'
block tests /tmp /repo npm test
block tests /tmp /repo cd ./x
allow tests /repo/sub /repo pytest
allow tests /repo/sub /repo pytest /repo/other/tests
block tests /repo/sub /repo pytest ../x
allow ro /tmp /repo ls
block ro /tmp /repo git status
block ro /tmp /repo cd ./x
CASES

# Symlinks inside the project that point outside it (needs GNU realpath -m).
if realpath -m -- / >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/repo/sub"
  ln -s /tmp "$tmp/repo/out"
  run block tests "pytest $tmp/repo/out/x" "$tmp/repo" "$tmp/repo"
  run block tests "cd $tmp/repo/out" "$tmp/repo" "$tmp/repo"
  run allow tests "cd $tmp/repo/sub" "$tmp/repo" "$tmp/repo"
fi

if ((count < min_cases)); then
  echo "FAIL: only $count cases ran (expected at least $min_cases)"
  fail=1
fi
if ((fail)); then
  echo "readonly-bash tests: FAILED ($count cases)"
  exit 1
fi
echo "readonly-bash tests: all $count cases passed"
