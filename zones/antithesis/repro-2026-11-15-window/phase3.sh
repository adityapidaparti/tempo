#!/usr/bin/env bash
# Task 2b deploy-kill (SIGTERM then SIGKILL after 10s / 2s) and window sweep (SIGKILL D ms after receipt)
cd /home/exedev/hunt-logs/repro/load; P=venv/bin/python
until grep -q "phase2 done" phase2.log; do sleep 5; done
PROBE=1005 $P exp.py term:10 10 400 term-10-400 > exp-term-10-400.log 2>&1
PROBE=1005 $P exp.py term:2 10 400 term-2-400 > exp-term-2-400.log 2>&1
PROBE=1004 $P exp.py kill 10 50 kill50 > exp-kill50.log 2>&1
for d in 50 100 250 500; do PROBE=1003 $P exp.py kill:$d 5 400 kill400-d$d > exp-kill400-d$d.log 2>&1; done
echo phase3 done
