#!/bin/bash
set -euo pipefail

SERVICE=${1:?Usage: rollback-release.sh SERVICE [COMMIT]}
COMMIT=${2:-}
APP="/home/kiwiton/apps/${SERVICE}"
ROOT="/home/kiwiton/releases/${SERVICE}"

if [ ! -d "$APP" ] || [ ! -d "$ROOT" ]; then
    echo "Unknown service or no release snapshots: $SERVICE" >&2
    exit 1
fi

if [ -n "$COMMIT" ]; then
    RELEASE="${ROOT}/${COMMIT}"
else
    RELEASE=$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -nr | sed -n '2p' | cut -d' ' -f2-)
fi

if [ -z "${RELEASE:-}" ] || [ ! -d "$RELEASE" ]; then
    echo "Rollback release not found" >&2
    exit 1
fi

rsync -a --delete \
    --exclude '.git' --exclude '.env' --exclude '.env.local' \
    --exclude '.venv' --exclude 'models' --exclude 'models-backup*' \
    --exclude 'state' --exclude 'tmp' --exclude 'logs' --exclude 'node_modules' \
    "${RELEASE}/" "${APP}/"

VENV="/home/kiwiton/virtualenv/apps/${SERVICE}/3.11"
if [ -x "$VENV/bin/pip" ] && [ -f "$APP/requirements.txt" ]; then
    "$VENV/bin/pip" install -r "$APP/requirements.txt" --quiet
fi

mkdir -p "$APP/tmp"
touch "$APP/tmp/restart.txt"
ln -sfn "$RELEASE" "$ROOT/current"

if [ "$SERVICE" = "KTI-Strategy-Engine" ] && [ -f "$APP/tmp/live_daemon.pid" ]; then
    kill -TERM "$(cat "$APP/tmp/live_daemon.pid")" 2>/dev/null || true
    sleep 2
    bash "$APP/scripts/live_watchdog.sh"
fi
if [ "$SERVICE" = "KTI-ML-Service" ] && [ -f "$APP/tmp/training_worker.pid" ]; then
    kill -TERM "$(cat "$APP/tmp/training_worker.pid")" 2>/dev/null || true
    sleep 2
    bash "$APP/scripts/training_worker_watchdog.sh"
fi

echo "Rolled back ${SERVICE} to $(basename "$RELEASE")"
