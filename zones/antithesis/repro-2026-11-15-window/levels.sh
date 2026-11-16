#!/usr/bin/env bash
# Task 1a: lag vs load. Each level: 10s warmup, 60s measured.
cd /home/exedev/hunt-logs/repro/load; P=venv/bin/python
for r in "$@"; do
  $P load.py $r 75 > load-$r.log 2>&1 & L=$!
  sleep 10; $P monitor.py lag-$r 60; wait $L
  echo "== rate $r"; $P analyze.py lag-$r; tail -n 2 load-$r.log
  sleep 5
done
