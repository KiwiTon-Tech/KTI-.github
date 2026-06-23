#!/bin/bash
# Refresh GitHub App installation token → ~/.git-credentials
# No external Python packages needed — uses openssl + curl + python3 stdlib only.
#
# cPanel cron (every 55 min):
#   */55 * * * * bash /home/kiwiton/bin/refresh-github-token.sh \
#       >> /home/kiwiton/logs/token-refresh.log 2>&1

set -euo pipefail

APP_ID="${KTI_APP_ID:-3600921}"
INSTALLATION_ID="${KTI_INSTALLATION_ID:-129507234}"
PEM_PATH="${KTI_PEM_PATH:-/home/kiwiton/secrets/kti-deploy-bot.pem}"
CREDS_PATH="${HOME}/.git-credentials"
LOG_DIR="/home/kiwiton/logs"
mkdir -p "$LOG_DIR"

TS=$(date '+%Y-%m-%d %H:%M:%S')

# ── JWT helpers ──────────────────────────────────────────────────────────────

b64url() {
    # base64 URL-encode stdin (no padding, URL-safe chars)
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

make_jwt() {
    local now
    now=$(date +%s)
    local iat=$(( now - 60 ))
    local exp=$(( now + 600 ))

    local header
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)

    local payload
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$APP_ID" | b64url)

    local unsigned="${header}.${payload}"

    local signature
    signature=$(printf '%s' "$unsigned" \
        | openssl dgst -sha256 -sign "$PEM_PATH" -binary \
        | b64url)

    printf '%s' "${unsigned}.${signature}"
}

# ── Get installation access token ────────────────────────────────────────────

get_token() {
    local jwt="$1"
    curl -s -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: KTI-Deploy-Bot/1.0" \
        "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token') or sys.exit(d))"
}

# ── Write to ~/.git-credentials ──────────────────────────────────────────────

write_credentials() {
    local token="$1"
    # Remove existing github.com entries, append fresh token
    ( grep -v "github.com" "$CREDS_PATH" 2>/dev/null || true ) > /tmp/kti-git-creds
    printf 'https://x-access-token:%s@github.com\n' "$token" >> /tmp/kti-git-creds
    mv /tmp/kti-git-creds "$CREDS_PATH"
    chmod 600 "$CREDS_PATH"
}

# ── Main ─────────────────────────────────────────────────────────────────────

JWT=$(make_jwt)
TOKEN=$(get_token "$JWT")
write_credentials "$TOKEN"

echo "[${TS}] ✅ GitHub App token refreshed (expires ~1h)"
