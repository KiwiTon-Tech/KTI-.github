#!/bin/bash
# Auto-Update Script for KTI Services
# Run via cron: */5 * * * * /home/kiwiton/bin/auto-update.sh >> /home/kiwiton/logs/auto-update.log 2>&1

set -e
set -o pipefail

# Configuration
BASE_PATH="/home/kiwiton/apps"
TOOLS_PATH="/home/kiwiton/tools"
LOG_DIR="/home/kiwiton/logs"
LOCK_FILE="/tmp/kti-auto-update.lock"
TOOLS_PYTHON="/home/kiwiton/venvs/kti-tools/bin/python"

# Services to auto-update (in order of dependency)
# KTI-DB is excluded (usually needs manual migration coordination)
SERVICES=(
    "KTI-Gateway"
    "KTI-Broker-Service"
    "KTI-Market-Data-Service"
    "KTI-News-Sentiment-Service"
    "KTI-NLP-Service"
    "KTI-Backtest-Service"
    "KTI-Strategy-Engine"
    "KTI-Observability"
    "KTI-ML-Service"
    # Excluded — not cPanel Passenger apps:
    # "KTI-DB"             (manual migration coordination)
    # "KTI-CF-WS-Worker"   (Cloudflare Worker — deploy via wrangler)
    # "KTI-Price-Publisher" (Fly.io — deploy via fly deploy)
    # "KTI-Strategies"     (pip package — consumed via git+https)
)

# Branch to track for each service (all production services use main)
declare -A SERVICE_BRANCHES
SERVICE_BRANCHES=(
    ["KTI-Gateway"]="main"
    ["KTI-Broker-Service"]="main"
    ["KTI-Market-Data-Service"]="main"
    ["KTI-News-Sentiment-Service"]="main"
    ["KTI-NLP-Service"]="main"
    ["KTI-Backtest-Service"]="main"
    ["KTI-Strategy-Engine"]="main"
    ["KTI-Observability"]="main"
    ["KTI-ML-Service"]="main"
)

# Logging setup
mkdir -p "$LOG_DIR"
UPDATE_LOG="${LOG_DIR}/auto-update.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$UPDATE_LOG"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$UPDATE_LOG" >&2
}

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -lt 300 ]; then  # 5 minutes
        log "Update already in progress (lock file exists, age: ${LOCK_AGE}s)"
        exit 0
    else
        log "Removing stale lock file (age: ${LOCK_AGE}s)"
        rm -f "$LOCK_FILE"
    fi
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "=== Auto-update check started ==="

# Function to check if a service needs update
needs_update() {
    local service=$1
    local service_path="${BASE_PATH}/${service}"
    local branch="${SERVICE_BRANCHES[$service]:-main}"
    
    if [ ! -d "$service_path/.git" ]; then
        return 1  # Not a git repo
    fi
    if [ -f "$service_path/tmp/deploy_failed" ]; then
        return 0
    fi
    
    cd "$service_path"
    
    # Fetch latest from origin
    git fetch origin "$branch" 2>/dev/null || return 1
    
    LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git rev-parse origin/${branch} 2>/dev/null || echo "")
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        return 0  # Needs update
    fi

    # HEAD moved without this script (e.g. a manual deploy.sh run). Redeploy so the
    # snapshot is only advanced after deploy.sh succeeds, never on an unverified HEAD.
    local current_release
    current_release=$(readlink -f "/home/kiwiton/releases/${service}/current" 2>/dev/null || true)
    if [ -n "$current_release" ] && [ -d "$current_release" ] \
        && [ "$(basename "$current_release")" != "$(git rev-parse --short=12 HEAD)" ]; then
        log "${service}: release snapshot $(basename "$current_release") is not HEAD; redeploying to verify"
        return 0
    fi
    return 1  # Up to date
}

# deploy.sh hard-resets to origin, so never deploy over edits made on the server
has_local_edits() {
    [ -n "$(git -C "${BASE_PATH}/$1" status --porcelain --untracked-files=no 2>/dev/null)" ]
}

snapshot_release() {
    local service=$1
    local service_path="${BASE_PATH}/${service}"
    local commit
    commit=$(git -C "$service_path" rev-parse --short=12 HEAD)
    local release_root="/home/kiwiton/releases/${service}"
    local release_path="${release_root}/${commit}"
    mkdir -p "$release_root"
    if [ ! -d "$release_path" ] || [ -z "$(find "$release_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        rm -rf "$release_path"
        mkdir -p "$release_path"
        tar -C "$service_path" \
            --exclude='./.git' --exclude='./.env' --exclude='./.env.local' \
            --exclude='./.venv' --exclude='./models' --exclude='./models-backup*' \
            --exclude='./state' --exclude='./tmp' --exclude='./logs' \
            --exclude='./node_modules' -cf - . \
            | tar -C "$release_path" -xf -
        if [ -z "$(find "$release_path" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            error "Release snapshot is empty: $release_path"
            return 1
        fi
        chmod -R a-w "$release_path"
    fi
    ln -sfn "$release_path" "${release_root}/current"
    find "$release_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -nr | tail -n +6 | cut -d' ' -f2- | xargs -r rm -rf
    log "Immutable release snapshot recorded: ${service}@${commit}"
}

update_service() {
    local service=$1
    local service_path="${BASE_PATH}/${service}"
    local branch="${SERVICE_BRANCHES[$service]:-main}"
    
    log "Updating ${service} (branch: ${branch})..."

    if has_local_edits "$service"; then
        error "${service} has uncommitted edits to tracked files; not deploying (deploy.sh would erase them). Commit or revert:"
        git -C "$service_path" status --short --untracked-files=no | sed -n '1,5p' | tee -a "$UPDATE_LOG"
        return 2
    fi

    cd "$service_path"
    
    # Bootstrap: if deploy.sh is missing, pull latest code first so we get it
    if [ ! -f "${service_path}/deploy.sh" ]; then
        log "deploy.sh not found locally — bootstrapping git pull for ${service}..."
        git fetch origin "$branch" 2>&1 | tee -a "$UPDATE_LOG" || true
        git reset --hard "origin/${branch}" 2>&1 | tee -a "$UPDATE_LOG" || true
    fi

    # Check if deploy.sh exists (after potential bootstrap pull)
    if [ ! -f "${service_path}/deploy.sh" ]; then
        log "⚠️ ${service} missing deploy.sh even after pull - skipping"
        return 1
    fi
    
    # Run deploy script
    if bash "${service_path}/deploy.sh" production "$branch" 2>&1 | tee -a "$UPDATE_LOG"; then
        log "✅ ${service} updated successfully"
        rm -f "${service_path}/tmp/deploy_failed"
        if ! snapshot_release "$service"; then
            error "Release snapshot failed for ${service}"
            return 1
        fi
        
        # Send notification (optional - can integrate with Slack/Discord)
        # curl -X POST "$SLACK_WEBHOOK_URL" -H 'Content-type: application/json' \
        #   --data "{\"text\":\"✅ ${service} auto-deployed successfully\"}" 2>/dev/null || true
        
        return 0
    else
        mkdir -p "${service_path}/tmp"
        touch "${service_path}/tmp/deploy_failed"
        error "❌ ${service} update failed"
        
        # Send failure notification
        # curl -X POST "$SLACK_WEBHOOK_URL" -H 'Content-type: application/json' \
        #   --data "{\"text\":\"❌ ${service} auto-deploy FAILED - check logs\"}" 2>/dev/null || true
        
        return 1
    fi
}

update_database() {
    local db_path="${TOOLS_PATH}/KTI-DB"
    if [ ! -d "${db_path}/.git" ]; then
        error "KTI-DB checkout missing at ${db_path}"
        return 1
    fi

    log "Updating migration authority..."
    cd "$db_path"
    git fetch git@github.com:KiwiTon-Tech/KTI-DB.git main 2>&1 | tee -a "$UPDATE_LOG"
    git reset --hard FETCH_HEAD 2>&1 | tee -a "$UPDATE_LOG"

    log "Applying tracked database migrations..."
    "$TOOLS_PYTHON" - "$BASE_PATH/KTI-Broker-Service/.env" "$db_path/python/migrate.py" <<'PY' 2>&1 | tee -a "$UPDATE_LOG"
import os
import subprocess
import sys
from dotenv import dotenv_values

env_file, runner = sys.argv[1:]
env = os.environ.copy()
env.update({key: value for key, value in dotenv_values(env_file).items() if value})
env["NODE_ENV"] = "production"
subprocess.run([sys.executable, runner], check=True, env=env)
PY
}

if ! update_database; then
    error "Database migration failed; service deployment aborted"
    exit 1
fi

# Track results
UPDATED=()
FAILED=()
UP_TO_DATE=()
SKIPPED=()

for service in "${SERVICES[@]}"; do
    service_path="${BASE_PATH}/${service}"
    
    if [ ! -d "$service_path" ]; then
        log "⚠️ ${service} not found at ${service_path}"
        continue
    fi
    
    if needs_update "$service"; then
        log "🔔 ${service} has new commits"
        rc=0
        update_service "$service" || rc=$?
        case "$rc" in
            0) UPDATED+=("$service") ;;
            2) SKIPPED+=("$service") ;;
            *) FAILED+=("$service") ;;
        esac
    else
        UP_TO_DATE+=("$service")
        release_root="/home/kiwiton/releases/${service}"
        current_release=$(readlink -f "${release_root}/current" 2>/dev/null || true)
        if git -C "$service_path" rev-parse -q --verify HEAD >/dev/null 2>&1 \
            && ! has_local_edits "$service" && {
            [ ! -L "${release_root}/current" ] \
            || [ ! -d "$current_release" ] \
            || [ -z "$(find "$current_release" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; }; then
            snapshot_release "$service"
        fi
    fi
done

# Summary
log "=== Auto-update check complete ==="
log "Updated: ${#UPDATED[@]} services"
log "Up-to-date: ${#UP_TO_DATE[@]} services"
log "Failed: ${#FAILED[@]} services"
log "Skipped (local edits): ${#SKIPPED[@]} services"

if [ ${#UPDATED[@]} -gt 0 ]; then
    log "Updated services: ${UPDATED[*]}"
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
    error "Skipped services with server-side edits: ${SKIPPED[*]}"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    error "Failed services: ${FAILED[*]}"
    exit 1
fi

if [ ${#UPDATED[@]} -gt 0 ] && [ -f "/home/kiwiton/bin/production-smoke.py" ]; then
    log "Running production smoke suite after deployment..."
    "$TOOLS_PYTHON" /home/kiwiton/bin/production-smoke.py 2>&1 | tee -a "$UPDATE_LOG"
    log "Production smoke suite passed"
fi

# Cleanup old logs (keep 30 days)
find "$LOG_DIR" -name "auto-update.log" -mtime +7 -exec gzip {} \; 2>/dev/null || true
find "$LOG_DIR" -name "auto-update.log*.gz" -mtime +30 -delete 2>/dev/null || true

exit 0
