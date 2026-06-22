#!/bin/bash
# Auto-Update Script for KTI Services
# Run via cron: */5 * * * * /home/kiwiton/bin/auto-update.sh >> /home/kiwiton/logs/auto-update.log 2>&1

set -e

# Configuration
BASE_PATH="/home/kiwiton/apps"
LOG_DIR="/home/kiwiton/logs"
LOCK_FILE="/tmp/kti-auto-update.lock"

# Services to auto-update (in order of dependency)
# KTI-DB is excluded (usually needs manual migration coordination)
SERVICES=(
    "KTI-Gateway"
    "KTI-ML-Service"
    # Add more services as they get deploy.sh:
    # "KTI-Broker-Service"
    # "KTI-Market-Data-Service"
    # "KTI-News-Sentiment-Service"
    # "KTI-NLP-Service"
    # "KTI-Strategy-Engine"
    # "KTI-Backtest-Service"
)

# Branch to track for each service (default: main)
declare -A SERVICE_BRANCHES
SERVICE_BRANCHES=(
    ["KTI-Gateway"]="main"
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
    
    cd "$service_path"
    
    # Fetch latest from origin
    git fetch origin "$branch" 2>/dev/null || return 1
    
    LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git rev-parse origin/${branch} 2>/dev/null || echo "")
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        return 0  # Needs update
    else
        return 1  # Up to date
    fi
}

# Function to update a service
update_service() {
    local service=$1
    local service_path="${BASE_PATH}/${service}"
    local branch="${SERVICE_BRANCHES[$service]:-main}"
    
    log "Updating ${service} (branch: ${branch})..."
    
    cd "$service_path"
    
    # Check if deploy.sh exists
    if [ ! -f "${service_path}/deploy.sh" ]; then
        log "⚠️ ${service} missing deploy.sh - skipping"
        return 1
    fi
    
    # Run deploy script
    if bash "${service_path}/deploy.sh" production "$branch" 2>&1 | tee -a "$UPDATE_LOG"; then
        log "✅ ${service} updated successfully"
        
        # Send notification (optional - can integrate with Slack/Discord)
        # curl -X POST "$SLACK_WEBHOOK_URL" -H 'Content-type: application/json' \
        #   --data "{\"text\":\"✅ ${service} auto-deployed successfully\"}" 2>/dev/null || true
        
        return 0
    else
        error "❌ ${service} update failed"
        
        # Send failure notification
        # curl -X POST "$SLACK_WEBHOOK_URL" -H 'Content-type: application/json' \
        #   --data "{\"text\":\"❌ ${service} auto-deploy FAILED - check logs\"}" 2>/dev/null || true
        
        return 1
    fi
}

# Track results
UPDATED=()
FAILED=()
UP_TO_DATE=()

for service in "${SERVICES[@]}"; do
    service_path="${BASE_PATH}/${service}"
    
    if [ ! -d "$service_path" ]; then
        log "⚠️ ${service} not found at ${service_path}"
        continue
    fi
    
    if needs_update "$service"; then
        log "🔔 ${service} has new commits"
        if update_service "$service"; then
            UPDATED+=("$service")
        else
            FAILED+=("$service")
        fi
    else
        UP_TO_DATE+=("$service")
    fi
done

# Summary
log "=== Auto-update check complete ==="
log "Updated: ${#UPDATED[@]} services"
log "Up-to-date: ${#UP_TO_DATE[@]} services"
log "Failed: ${#FAILED[@]} services"

if [ ${#UPDATED[@]} -gt 0 ]; then
    log "Updated services: ${UPDATED[*]}"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    error "Failed services: ${FAILED[*]}"
    exit 1
fi

# Cleanup old logs (keep 30 days)
find "$LOG_DIR" -name "auto-update.log" -mtime +7 -exec gzip {} \; 2>/dev/null || true
find "$LOG_DIR" -name "auto-update.log*.gz" -mtime +30 -delete 2>/dev/null || true

exit 0
