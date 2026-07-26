#!/bin/bash
# Installation Script for KTI Deployment Automation
# Run this on your cPanel server as the kiwiton user

set -e

echo "=========================================="
echo "KTI Deployment Automation Setup"
echo "=========================================="
echo ""

BASE_DIR="/home/kiwiton"
APPS_DIR="${BASE_DIR}/apps"
BIN_DIR="${BASE_DIR}/bin"
LOG_DIR="${BASE_DIR}/logs"
SCRIPTS_DIR="/Users/zanderbolyanatz/Documents/KiwiTon Investments/KTI-.github/scripts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on cPanel
if [ ! -d "/home/kiwiton" ]; then
    log_error "This script must run on the cPanel server as the kiwiton user"
    exit 1
fi

# Create directory structure
log_info "Creating directory structure..."
mkdir -p "$BIN_DIR"
mkdir -p "$LOG_DIR"

# Copy scripts to bin directory
log_info "Installing deployment scripts..."

# Copy auto-update script
if [ -f "${SCRIPTS_DIR}/auto-update.sh" ]; then
    cp "${SCRIPTS_DIR}/auto-update.sh" "${BIN_DIR}/auto-update.sh"
    chmod +x "${BIN_DIR}/auto-update.sh"
    log_info "✅ auto-update.sh installed"
else
    log_warn "auto-update.sh not found - run this script from the repo root"
fi

# Copy health-check script
if [ -f "${SCRIPTS_DIR}/health-check.sh" ]; then
    cp "${SCRIPTS_DIR}/health-check.sh" "${BIN_DIR}/health-check.sh"
    chmod +x "${BIN_DIR}/health-check.sh"
    log_info "✅ health-check.sh installed"
else
    log_warn "health-check.sh not found - run this script from the repo root"
fi

# Verify deploy.sh exists in target services
SERVICES=("KTI-Gateway" "KTI-ML-Service")

log_info "Checking service deploy scripts..."
for service in "${SERVICES[@]}"; do
    service_path="${APPS_DIR}/${service}"
    if [ -d "$service_path" ]; then
        if [ -f "${service_path}/deploy.sh" ]; then
            chmod +x "${service_path}/deploy.sh"
            log_info "✅ ${service} has deploy.sh"
        else
            log_warn "${service} missing deploy.sh - copy from repo"
        fi
    else
        log_warn "${service} not found at ${service_path}"
    fi
done

# Create log rotation config
log_info "Setting up log rotation..."
mkdir -p "${BASE_DIR}/etc/logrotate.d"

cat > "${BASE_DIR}/etc/logrotate.d/kti-services" << 'EOF'
/home/kiwiton/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644 kiwiton kiwiton
}

/home/kiwiton/logs/*-deploy.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 kiwiton kiwiton
}
EOF

log_info "Log rotation config created at ${BASE_DIR}/etc/logrotate.d/kti-services"

# Setup cron jobs
log_info "=========================================="
log_info "CRON SETUP REQUIRED"
log_info "=========================================="
echo ""
echo "Add these entries to your crontab (crontab -e):"
echo ""
echo "# KTI Auto-Update (every 5 minutes)"
echo "*/5 * * * * ${BIN_DIR}/auto-update.sh >> ${LOG_DIR}/auto-update.log 2>&1"
echo ""
echo "# KTI Health Check (every 5 minutes, offset by 2 min)"
echo "2-59/5 * * * * ${BIN_DIR}/health-check.sh >> ${LOG_DIR}/health-check.log 2>&1"
echo ""
echo "# Log rotation (daily)"
echo "0 0 * * * /usr/sbin/logrotate -f ${BASE_DIR}/etc/logrotate.d/kti-services >> ${LOG_DIR}/logrotate.log 2>&1"
echo ""

# Test scripts
log_info "Testing installed scripts..."

if [ -f "${BIN_DIR}/auto-update.sh" ]; then
    echo ""
    log_info "Running auto-update.sh test mode..."
    bash "${BIN_DIR}/auto-update.sh" --help 2>/dev/null || true
fi

# Create status command
cat > "${BIN_DIR}/kti-status" << EOF
#!/bin/bash
# Quick status check for all KTI services

echo "=== KTI Service Status ==="
echo ""

echo "KTI-Gateway:"
curl -sf http://localhost:8080/health 2>/dev/null && echo "  ✅ Healthy" || echo "  ❌ Unavailable"

echo ""
echo "KTI-ML-Service:"
curl -sf http://localhost:8081/health 2>/dev/null && echo "  ✅ Healthy" || echo "  ❌ Unavailable"

echo ""
echo "Recent deploy logs:"
ls -lt ${LOG_DIR}/*-deploy.log 2>/dev/null | head -5 || echo "  No deploy logs found"

echo ""
echo "Recent updates:"
tail -5 ${LOG_DIR}/auto-update.log 2>/dev/null || echo "  No auto-update log"
EOF

chmod +x "${BIN_DIR}/kti-status"

# Summary
echo ""
echo "=========================================="
log_info "Installation Complete!"
echo "=========================================="
echo ""
echo "Installed commands:"
echo "  ${BIN_DIR}/auto-update.sh  - Auto-deploy when git changes detected"
echo "  ${BIN_DIR}/health-check.sh - Monitor and restart unhealthy services"
echo "  ${BIN_DIR}/kti-status       - Quick health check of all services"
echo ""
echo "Next steps:"
echo "  1. Add cron jobs (see above)"
echo "  2. Test manually: ${BIN_DIR}/kti-status"
echo "  3. Check logs: tail -f ${LOG_DIR}/auto-update.log"
echo ""
echo "Service-specific deploy:"
echo "  ${APPS_DIR}/KTI-Gateway/deploy.sh"
echo "  ${APPS_DIR}/KTI-ML-Service/deploy.sh"
echo ""
