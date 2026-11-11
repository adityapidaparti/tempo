#!/bin/sh
# Reproduces the forced-recovery fork with the test operator, which stops the old leader and waits
# for confirmation before forcing recovery. Run from zones/antithesis with a
# .env that sets ZONES_IMAGE and WORKLOAD_IMAGE to images built from this branch (the workload
# image with TEMPLATES=zone_recovery).
set -u
ex() { docker compose exec -T workload "$@" 2>/dev/null; }
T=/opt/antithesis/test/v1/zone_recovery
tips() { for n in 11 12 13 20; do ex cast rpc zone_getSequencerInfo --rpc-url "http://10.20.0.$n:8545" | jq -c '[.local.name,.local.role,.localTip.zoneHeight,.localTip.zoneHash[0:10]]' 2>/dev/null || echo "\"10.20.0.$n silent\""; done | tr '\n' ' '; echo; }
ip() { case $1 in zone-0) echo 10.20.0.11;; zone-1) echo 10.20.0.12;; zone-2) echo 10.20.0.13;; zone-rpc) echo 10.20.0.20;; esac; }
docker compose down -v >/dev/null 2>&1; docker compose up -d >/dev/null 2>&1
until docker compose logs workload 2>/dev/null | grep -q 'zone replicated'; do sleep 2; done
ex $T/first_seed | tail -1; sleep 5
NET=$(docker inspect zone-0 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
echo "== start"; tips
echo "== followers cut off for 6 s (leader builds alone), then leader cut off, followers back"
for n in zone-1 zone-2 zone-rpc; do docker network disconnect "$NET" $n; done
sleep 6
docker network disconnect "$NET" zone-0
for n in zone-1 zone-2 zone-rpc; do docker network connect --ip "$(ip $n)" "$NET" $n; done
sleep 4; tips
echo "== operator"
ex $T/parallel_driver_force_recovery | cut -c1-500
ex sh -c 'ls /control /acks' | tr '\n' ' '; echo
echo "== old leader's network restored"
docker network connect --ip 10.20.0.11 "$NET" zone-0
sleep 30; tips
docker compose logs zone-0 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'supervisor|Installed manifest forced|parent mismatch|conflicts with canonical' | cut -c1-190 | sort | uniq -c | tail -8
echo "== checks"
ex $T/anytime_safety | tail -1 | cut -c1-200
ex $T/eventually_recovery | tail -4 | cut -c1-600
