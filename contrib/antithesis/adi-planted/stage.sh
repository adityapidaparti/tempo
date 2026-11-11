#!/bin/sh
# Stages Antithesis config directories for the planted-Reth-bug runs under .stage/ (untracked).
# Each holds the target's unchanged docker-compose.yaml plus an .env naming locally built images.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
stage() { # name compose-dir env-lines...
    dir="$here/.stage/$1"; mkdir -p "$dir"
    cp "$root/$2/docker-compose.yaml" "$dir/"
    shift 2
    printf '%s\n' "$@" > "$dir/.env"
}
stage reth-state-root reth-state-root RETH_STATE_ROOT_IMAGE=tempo-reth-state-root-antithesis:planted
for variant in asis vol deep; do
    stage "zones-$variant" zones ZONES_IMAGE=tempo-zones-antithesis:planted \
        "WORKLOAD_IMAGE=tempo-zones-antithesis-workload:planted-$variant"
done
