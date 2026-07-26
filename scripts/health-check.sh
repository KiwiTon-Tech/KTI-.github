#!/bin/bash
# Health Check & Monitoring Script for KTI Services
# Run via cron: */5 * * * * /home/kiwiton/bin/health-check.sh

set -e

# Configuration
BASE_PATH="/home/kiwiton/apps"
LOG_DIR="/home/kiwiton/logs"
ALERT_LOG="${LOG_DIR}/health-alerts.log"
STATUS_FILE="${LOG_DIR}/service-status.json"

# Service endpoints (name:health_url:restart_method)
declare -a SERVICES=(
    "KTI-Gateway:http://localhost:8080/health:passenger"
    "KTI-ML-Service:http://localhost:8081/health:passenger"
    # Add more as they get health endpoints:
    # "KTI-Broker-Service:http://localhost:8082/health:passenger"
    # "KTI-Market-Data-Service:http://localhost:8083/health:passenger"
)

# Alert thresholds
MAX_RESTARTS_PER_HOUR=3
HEALTH_TIMEOUT=10

# Logging
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$ALERT_LOG"
}

alert() {
    local service=$1
    local message=$2
    log "🚨 ALERT: ${service} - ${message}"
    
    # Optional: Send to Slack/Discord
    # curl -X POST "$HEALTH_ALERT_WEBHOOK" \
    #   -H 'Content-type: application/json' \
    #   --data "{\"text\":\"🚨 ${service}: ${message}\"}" 2>/dev/null || true
}

# Function to check service health
check_health() {
    local service=$1
    local url=$2
    
    if curl -sf --max-time "$HEALTH_TIMEOUT" "$url" > /dev/null 2>&1; then
        return 0  # Healthy
    else
        return 1  # Unhealthy
    fi
}

# Function to restart a service
restart_service() {
    local service=$1
    local method=$2
    local service_path="${BASE_PATH}/${service}"
    
    log "Attempting to restart ${service} (method: ${method})..."
    
    case $method in
        passenger)
            if [ -d "${service_path}/tmp" ]; then
                touch "${service_path}/tmp/restart.txt"
                log "✅ ${service} restart signal sent (Passenger)"
                return 0
            else
                log "❌ ${service} tmp directory not found"
                return 1
            fi
            ;;
        systemd)
            # For future use if migrating to systemd
            systemctl restart "$service" 2>/dev/null || return 1
            return 0
            ;;
        *)
            log "Unknown restart method: $method"
            return 1
            ;;
    esac
}

# Function to track restarts (rate limiting)
count_restarts() {
    local service=$1
    local log_file="${LOG_DIR}/${service}-restarts.log"
    local one_hour_ago=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-1H '+%Y-%m-%d %H:%M:%S')
    
    # Count restarts in last hour
    if [ -f "$log_file" ]; then
        grep -c "^\[$one_hour_ago" "$log_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

log_restart() {
    local service=$1
    local log_file="${LOG_DIR}/${service}-restarts.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restart triggered by health check" >> "$log_file"
}

# Initialize status tracking
declare -A STATUS
declare -A RESTART_COUNT

# Main health check loop
log "=== Health check started ==="

for svc_config in "${SERVICES[@]}"; do
    IFS=':' read -r service url method <<< "$svc_config"
    
    if check_health "$service" "$url"; then
        STATUS[$service]="healthy"
        log "✅ ${service} is healthy"
    else
        STATUS[$service]="unhealthy"
        alert "$service" "Health check failed"
        
        # Check restart rate
        restart_count=$(count_restarts "$service")
        if [ "$restart_count" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
            alert "$service" "CRITICAL: Max restarts (${MAX_RESTARTS_PER_HOUR}/hour) exceeded - manual intervention needed"
            continue
        fi
        
        # Attempt restart
        if restart_service "$service" "$method"; then
            log_restart "$service"
            
            # Wait and re-check
            log "Waiting 10s for ${service} to recover..."
            sleep 10
            
            if check_health "$service" "$url"; then
                STATUS[$service]="recovered"
                alert "$service" "Recovered after restart"
            else
                STATUS[$service]="failed"
                alert "$service" "Still unhealthy after restart"
            fi
        else
            STATUS[$service]="restart_failed"
            alert "$service" "Restart failed - check manually"
        fi
    fi
done

# Generate JSON status report
{
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"services\": {"
    
    first=true
    for svc in "${!STATUS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo -n "    \"${svc}\": \"${STATUS[$svc]}\""
    done
    echo ""
    echo "  }"
    echo "}"
} > "$STATUS_FILE"

# Summary
HEALTHY_COUNT=0
UNHEALTHY_COUNT=0

for status in "${STATUS[@]}"; do
    if [ "$status" = "healthy" ]; then
        ((HEALTHY_COUNT++)) || true
    else
        ((UNHEALTHY_COUNT++)) || true
    fi
done

log "=== Health check complete ==="
log "Healthy: ${HEALTHY_COUNT}, Issues: ${UNHEALTHY_COUNT}"

# Cleanup old logs
find "$LOG_DIR" -name "*-restarts.log" -mtime +7 -delete 2>/dev/null || true
find "$LOG_DIR" -name "health-alerts.log" -mtime +7 -exec gzip {} \; 2>/dev/null || true

exit 0
