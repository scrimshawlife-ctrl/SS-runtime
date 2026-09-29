#!/bin/bash
# usage: ps-run.sh <name> <configs> <seeds>   (writes ps-<name>.jsonl / .log in scratchpad)
set -u
HERE=/private/tmp/claude-501/-Users-luna-Documents-claude/c5a69cd5-d75b-4716-a9cd-7bb13ac15e9e/scratchpad
cd "$HERE/ss-rt" || exit 1
start=$(date +%s)
SS_SEARCH_CONFIGS="$2" SS_SEARCH_SEEDS="$3" SS_SEARCH_REPORT="$HERE/ps-$1.jsonl" \
  swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter pacingSearch > "$HERE/ps-$1.log" 2>&1
echo "exit $? secs $(( $(date +%s) - start ))" >> "$HERE/ps-$1.log"
tail -3 "$HERE/ps-$1.log"
