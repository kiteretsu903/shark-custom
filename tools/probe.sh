#!/bin/bash
# Send candidate command frames to A001 and report any non-telemetry reply.
# Usage: tools/probe.sh "02 06" "02 05" ...
cd "$(dirname "$0")/.."
LOG=build/discovery.log
for FRAME in "$@"; do
  BEFORE=$(wc -l < "$LOG")
  echo "SEND $FRAME" > /tmp/funcooler_cmd
  sleep 2.5
  REPLY=$(tail -n +$((BEFORE+1)) "$LOG" | grep -E "value A00[23]" | grep -v "= 89 06" | sed 's/.*= //;s/ *".*//' | head -3 | tr '\n' '|')
  if [ -n "$REPLY" ]; then
    echo "  >>> $FRAME  ==>  REPLY: $REPLY"
  else
    echo "      $FRAME  ==>  (no reply)"
  fi
done
