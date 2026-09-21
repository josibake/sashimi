#!/bin/sh
set -eu
BLOCKS=${1:-400}
OUTPUTS=${2:-600}
cd "$(dirname "$0")/.."
zig build -Dbench=true -Doptimize=ReleaseFast
BIG=$PWD/zig-out/bin/sashimi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

printf '0 200000 %d 0 0\n' "$OUTPUTS" >"$T/profile"
export BIG_PROFILE="$T/profile"
export BIG_AGES="1:50,2:15,3:8,10:10,50:7,200:6,1000:4"
"$BIG" farm "$T/src" "$BLOCKS" 2>/dev/null
echo "blocks=$BLOCKS outputs/block=$OUTPUTS ages=$BIG_AGES"
printf '%-24s %8s %8s %8s %8s %8s\n' knobs spends overlay hot cold wall_s

run() {
  label=$1; hot=$2; shift 2
  export BIG_LOAD="cold_ns:150000,hot_blocks:$hot"
  rm -rf "$T/n"; mkdir -p "$T/n/blocks"; cp "$T/src/headers.bin" "$T/n/"; cp "$T/src/blocks/"* "$T/n/blocks/"
  start=$(python3 -c 'import time; print(time.time())')
  "$BIG" stock "$T/n" 2>/dev/null | "$BIG" commit "$T/n" --graders 2 --cutters 1 "$@" 2>"$T/log"
  end=$(python3 -c 'import time; print(time.time())')
  awk -v s="$start" -v e="$end" -v l="$label" '
    /^bench:/ { for (i = 1; i <= NF; i++) { if ($i == "spends") sp += $(i+1); if ($i == "hot") h += $(i+1); if ($i == "cold") c += $(i+1) } }
    END { printf "%-24s %8d %8d %8d %8d %8.2f\n", l, sp, sp - h - c, h, c, e - s }' "$T/log"
}

run "W0     hot0"     0        --window 0 --slices 2
run "W2     hot0"     0        --window 22K --slices 2
run "W4     hot0"     0        --window 44K --slices 2
run "W16    hot0"     0        --window 173K --slices 2
run "W100   hot0"     0        --window 1100K --slices 2
run "W16    hot20"    20       --window 173K --slices 2
run "W16    hot100"   100      --window 173K --slices 2
run "W16    hot100 S8" 100     --window 173K --slices 8
