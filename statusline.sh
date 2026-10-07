#!/usr/bin/env bash
#
# Status line: model · directory · git branch · output style.
# Claude Code passes session info as JSON on stdin and shows the first line printed.

input=$(cat)
field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

model=$(field .model.display_name)
dir=$(field .workspace.current_dir)
style=$(field .output_style.name)

line=${model:-Claude}
if [[ -n "$dir" ]]; then
  line+=" · ${dir/#$HOME/\~}"
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
  [[ -n "$branch" ]] && line+=" · $branch"
fi
[[ -n "$style" && "$style" != default ]] && line+=" · $style"
# Drop control characters so a hostile directory name can't send terminal escapes.
printf '%s\n' "${line//[[:cntrl:]]/}"
