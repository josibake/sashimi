#!/bin/sh
set -eu
BIG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
T=$(mktemp -d)
PORT=18601
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT

expect_tip() {
  read -r h _ <"$1/tip"
  [ "$h" = "$2" ] || { echo "FAIL: $1 tip $h, want $2"; exit 1; }
}
expect_fail() {
  if "$@" 2>/dev/null; then echo "FAIL: should have rejected block 290"; exit 1; fi
}

"$BIG" farm "$T/src" 300 --pad 300 --badsig 290 2>/dev/null
"$BIG" serve "$T/src" 127.0.0.1:$PORT 2>/dev/null &
i=0; while ! nc -z 127.0.0.1 $PORT 2>/dev/null; do i=$((i + 1)); [ $i -lt 50 ] || { echo "serve did not start"; exit 1; }; sleep 0.1; done
ADDR=127.0.0.1:$PORT

expect_fail "$BIG" run "$T/n" "$ADDR" --peers 4 --slices 2 --cutters 3 --graders 2 --window 1M --ahead 1M --segment 0
expect_tip "$T/n" 289

rm "$T/n/tip"
expect_fail sh -c "\"$BIG\" stock \"$T/n\" | \"$BIG\" commit \"$T/n\" --slices 2 --graders 1 --window 0 2>/dev/null"
expect_tip "$T/n" 289

for S in 1 4; do
  mkdir -p "$T/s$S/blocks"; cp "$T/n/headers.bin" "$T/s$S/"; cp "$T/n/blocks/"* "$T/s$S/blocks/"
  expect_fail sh -c "\"$BIG\" stock \"$T/s$S\" | \"$BIG\" commit \"$T/s$S\" --slices $S --cutters 2 --graders 3 --snapshot 50 2>/dev/null"
  expect_tip "$T/s$S" 289
  [ "$(cat "$T/s$S/utxo/289")" = "$(cat "$T/n/utxo/289")" ] || { echo "FAIL: digest differs at S=$S"; exit 1; }
  echo "00$(cut -c3- "$T/s$S/utxo/289")" >"$T/s$S/utxo/289"; rm "$T/s$S/tip"
  expect_fail sh -c "\"$BIG\" stock \"$T/s$S\" | \"$BIG\" commit \"$T/s$S\" --slices $S --graders 2 --snapshot 50 2>/dev/null"
  [ "$(cat "$T/s$S/utxo/289")" = "$(cat "$T/n/utxo/289")" ] || { echo "FAIL: replay from the snapshot below an off-chain one differs at S=$S"; exit 1; }
done

ln -s "$BIG" "$T/seal"
expect_fail "$BIG" run "$T/t" "$ADDR" --runner thread --peers 2 --cutters 2 --graders 2 --seal "$T/seal"
expect_tip "$T/t" 289
[ "$(cat "$T/t/utxo/289")" = "$(cat "$T/n/utxo/289")" ] || { echo "FAIL: thread mode digest differs"; exit 1; }

"$BIG" farm "$T/live" 100 2>/dev/null
cp -r "$T/live" "$T/fork"
PORT=$((PORT + 1))
"$BIG" serve "$T/live" 127.0.0.1:$PORT 2>/dev/null &
i=0; while ! nc -z 127.0.0.1 $PORT 2>/dev/null; do i=$((i + 1)); [ $i -lt 50 ] || { echo "serve did not start"; exit 1; }; sleep 0.1; done
"$BIG" run "$T/f" 127.0.0.1:$PORT --peers 2 2>/dev/null
expect_tip "$T/f" 99
"$BIG" tail "$T/f" 127.0.0.1:$PORT --every 100 2>/dev/null &
TAIL=$!
"$BIG" farm "$T/live" 5 2>/dev/null
i=0; while [ "$(cat "$T/f/tip" 2>/dev/null)" != 104 ]; do i=$((i + 1)); [ $i -lt 100 ] || { echo "FAIL: tail did not follow, tip $(cat "$T/f/tip")"; exit 1; }; sleep 0.1; done
kill $TAIL
"$BIG" farm "$T/fork" 10 --pad 7 2>/dev/null
PORT=$((PORT + 1))
"$BIG" serve "$T/fork" 127.0.0.1:$PORT 2>/dev/null &
i=0; while ! nc -z 127.0.0.1 $PORT 2>/dev/null; do i=$((i + 1)); [ $i -lt 50 ] || { echo "serve did not start"; exit 1; }; sleep 0.1; done
if "$BIG" tail "$T/f" 127.0.0.1:$PORT --every 100 2>/dev/null; then echo "FAIL: tail should exit on a reorg"; exit 1; fi
[ "$(($(wc -c <"$T/f/headers.bin") / 80))" = 110 ] || { echo "FAIL: forked chain not adopted"; exit 1; }
"$BIG" tail "$T/f" 127.0.0.1:$PORT --every 100 2>/dev/null &
TAIL=$!
i=0; while [ "$(cat "$T/f/tip" 2>/dev/null)" != 109 ]; do i=$((i + 1)); [ $i -lt 100 ] || { echo "FAIL: did not recover from the reorg, tip $(cat "$T/f/tip")"; exit 1; }; sleep 0.1; done
kill $TAIL

echo "e2e ok: $(cat "$T/n/utxo/289")"
