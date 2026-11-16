#!/usr/bin/env bash
# control: same host SIGKILL at idle (no load), immediately and 50/100 ms after receipt
cd /home/exedev/hunt-logs/repro/load; P=venv/bin/python
until grep -q "phase3 done" phase3.log; do sleep 5; done
PROBE=1002 $P exp.py kill 10 0 kill0 > exp-kill0.log 2>&1
PROBE=1002 $P exp.py kill:50 5 0 kill0-d50 > exp-kill0-d50.log 2>&1
PROBE=1002 $P exp.py kill:100 5 0 kill0-d100 > exp-kill0-d100.log 2>&1
echo phase4 done
