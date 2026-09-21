#!/bin/sh
set -eu
PRESET=${1:-pi5}
BLOCKS=${2:-120}
cd "$(dirname "$0")/.."
zig build -Dbench=true -Doptimize=ReleaseFast
BIG=$PWD/zig-out/bin/sashimi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc)
ALLCORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc)

cat >"$T/profile" <<EOF
0 4096 8 4096 0
$((BLOCKS / 3)) 500000 800 400000 0
$((2 * BLOCKS / 3)) 1500000 2500 0 60
EOF
export BIG_PROFILE="$T/profile" BIG_LOAD="$PRESET"

"$BIG" farm "$T/src" "$BLOCKS" 2>/dev/null
echo "preset=$PRESET blocks=$BLOCKS perf_cores=$CORES all_cores=$ALLCORES"
printf '%-28s %8s %8s %8s %6s\n' knobs busy_s floor_s wall_s eff

run() {
  label=$1; shift
  rm -rf "$T/n"; mkdir -p "$T/n/blocks"; cp "$T/src/headers.bin" "$T/n/"; cp "$T/src/blocks/"* "$T/n/blocks/"
  start=$(python3 -c 'import time; print(time.time())')
  "$BIG" stock "$T/n" 2>/dev/null | "$BIG" commit "$T/n" "$@" 2>"$T/log"
  end=$(python3 -c 'import time; print(time.time())')
  busy=$(awk '/^bench:/ { for (i = 1; i <= NF; i++) if ($i == "busy") s += $(i + 1) } END { printf "%.3f", s }' "$T/log")
  awk -v b="$busy" -v s="$start" -v e="$end" -v c="$CORES" -v l="$label" \
    'BEGIN { w = e - s; f = b / c; printf "%-28s %8.3f %8.3f %8.3f %6.2f\n", l, b, f, w, (w > 0 ? f / w : 0) }'
}

run "M1 N1 S1 W0"        --graders 1 --cutters 1 --slices 1 --window 0
run "M$CORES N1 S1 W0"   --graders "$CORES" --cutters 1 --slices 1 --window 0
run "M$CORES N1 S1 W1M"  --graders "$CORES" --cutters 1 --slices 1 --window 1M
run "M$CORES N2 S2 W1M"  --graders "$CORES" --cutters 2 --slices 2 --window 1M
run "M$CORES N4 S4 W8M"  --graders "$CORES" --cutters 4 --slices 4 --window 8M
