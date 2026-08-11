#!/bin/bash
# Sweep opcodes on A001 as bare [len=02][opcode] query frames and report replies.
# Usage: tools/sweep.sh <start_hex> <end_hex>   e.g. tools/sweep.sh 00 3f
cd "$(dirname "$0")/.."
LOG=build/discovery.log
START=$((16#${1:-00})); END=$((16#${2:-ff}))
for ((op=START; op<=END; op++)); do
  FRAME=$(printf "02 %02x" $op)
  BEFORE=$(wc -l < "$LOG")
  echo "SEND $FRAME" > /tmp/funcooler_cmd
  sleep 1.3
  REPLY=$(tail -n +$((BEFORE+1)) "$LOG" | grep -E "value A00[23]" | grep -v "= 89 06" \
          | sed 's/.*= //;s/ *".*//' | head -2 | tr '\n' '|')
  [ -n "$REPLY" ] && printf ">>> op 0x%02x  =>  %s\n" $op "$REPLY"
done
echo "sweep $1..$2 done"
