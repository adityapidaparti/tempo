#!/usr/bin/env bash
# Task 2a: graceful shutdown (SIGTERM, never SIGKILL) at idle / 50 / 400 tx/s
cd /home/exedev/hunt-logs/repro/load; P=venv/bin/python
while pgrep -f "exp.py kill 30" >/dev/null; do sleep 5; done
PROBE=1006 $P exp.py term:inf 4 0 term-inf-0 > exp-term-inf-0.log 2>&1
PROBE=1006 $P exp.py term:inf 4 50 term-inf-50 > exp-term-inf-50.log 2>&1
PROBE=1006 $P exp.py term:inf 6 400 term-inf-400 > exp-term-inf-400.log 2>&1
echo phase2 done
