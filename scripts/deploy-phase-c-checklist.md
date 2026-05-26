# Phase C Deployment Checklist

**Date**: 2026-05-26  
**Services**: KTI-Market-Data-Service, KTI-Gateway, KTI-DB  
**Reference**: `CPANEL_DEPLOYMENT.md` Part C6 (subsequent deploys)

---

## Prerequisites

✅ Server access restored  
✅ SSH/terminal access to cPanel  
✅ `kti-deploy` alias configured (Part B6)  
✅ Git credential helper configured (Part B5)

---

## Step 1: Deploy KTI-Market-Data-Service

**Commit**: `307e2a6` - "feat(phase-c): add historical, options and crypto orderbook endpoints"

```bash
# SSH into cPanel
ssh kiwiton@server.t-4.net

# Deploy (pulls latest from main, installs deps, restarts Passenger)
kti-deploy KTI-Market-Data-Service

# Verify deployment
curl https://market.kiwiton-investments.com/health
# Expected: {"status":"ok"}

# Smoke test new endpoints
curl "https://market.kiwiton-investments.com/historical/quotes?symbols=AAPL&start=2024-01-01&end=2024-01-31&limit=10"
# Expected: JSON with quotes array

curl "https://market.kiwiton-investments.com/options/chain?underlying_symbol=AAPL"
# Expected: JSON with expirations, strikes, calls, puts

curl "https://market.kiwiton-investments.com/trades/crypto/orderbook?symbol=BTCUSD"
# Expected: JSON with bids and asks arrays
```

**If deployment fails:**
- Check Passenger error log: `tail -100 ~/apps/KTI-Market-Data-Service/tmp/passenger.log`
- Verify `.env` has all required vars: `cat ~/apps/KTI-Market-Data-Service/.env`
- Test import manually: `cd ~/apps/KTI-Market-Data-Service && python passenger_wsgi.py`

---

## Step 2: Deploy KTI-Gateway

**Commit**: `8d6bd2c` - "feat(phase-c): market extensions, account config, SSE events, position exercise"

```bash
# Deploy
kti-deploy KTI-Gateway

# Verify deployment
curl https://api.kiwiton-investments.com/health
# Expected: {"status":"ok"}

# Smoke test new API routes (requires auth token)
TOKEN="your-jwt-token-here"

# Forex
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.kiwiton-investments.com/api/market/forex/latest?base=USD"
# Expected: JSON with rates object

# Logos (should redirect)
curl -I "https://api.kiwiton-investments.com/api/market/logos/AAPL"
# Expected: 302 redirect to parqet.com

# Historical quotes (pass-through to market service)
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.kiwiton-investments.com/api/market/historical-quotes?symbols=AAPL&start=2024-01-01&limit=5"
# Expected: JSON with quotes

# Account config
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.kiwiton-investments.com/api/account/config"
# Expected: JSON config object or 404 if not set yet

# SSE events stream (test in browser or with curl --no-buffer)
curl -H "Authorization: Bearer $TOKEN" --no-buffer \
  "https://api.kiwiton-investments.com/api/account/events?activity_types=FILL&poll_interval=5&max_events=10"
# Expected: text/event-stream with periodic events
```

**If deployment fails:**
- Check Passenger error log: `tail -100 ~/apps/KTI-Gateway/tmp/passenger.log`
- Verify all new blueprints registered: `grep -r "get_blueprint" ~/apps/KTI-Gateway/app/routes/api/__init__.py`
- Test import: `cd ~/apps/KTI-Gateway && python passenger_wsgi.py`

---

## Step 3: Run KTI-DB Migrations

**Migrations**: 009 (price_alerts, trading_config) + 010 (journal fields, portfolio upserts)

```bash
# Navigate to KTI-DB tools directory
cd ~/tools/KTI-DB

# Pull latest migrations
git pull origin main

# Activate the KTI-DB venv (or kti-tools venv if KTI-DB doesn't have its own)
source ~/venvs/kti-tools/bin/activate
# OR: source ~/tools/KTI-DB/venv/bin/activate

# Verify migrations are present
ls -la migrations/009*.sql migrations/010*.sql
# Expected: 
#   migrations/009_price_alerts_trading_config.sql
#   migrations/010_journal_and_portfolio_writes.sql

# Run migrations (idempotent, safe to re-run)
python python/migrate.py

# Expected output:
# Running migration: 009_price_alerts_trading_config.sql
# Running migration: 010_journal_and_portfolio_writes.sql
# All migrations complete.

# Verify new tables exist
psql $PROD_DATABASE_URI -c "\dt price_alerts"
psql $PROD_DATABASE_URI -c "\dt alert_history"
psql $PROD_DATABASE_URI -c "\dt trading_config"
psql $PROD_DATABASE_URI -c "\dt monitoring_events"

# Verify new columns on trades table
psql $PROD_DATABASE_URI -c "\d trades" | grep journal
# Expected: journal_note, journal_tags, journal_rating

# Verify unique constraints on portfolio tables
psql $PROD_DATABASE_URI -c "\d portfolio_allocations" | grep UNIQUE
psql $PROD_DATABASE_URI -c "\d portfolio_positions" | grep UNIQUE
```

**If migrations fail:**
- Check for syntax errors: `cat migrations/009_price_alerts_trading_config.sql`
- Verify database connection: `psql $PROD_DATABASE_URI -c "SELECT 1"`
- Check migration runner logs: `python python/migrate.py 2>&1 | tee migration.log`
- Rollback if needed (migrations are idempotent but check for partial state)

---

## Step 4: End-to-End Smoke Tests

### Test 1: Options Chain
```bash
# Frontend: Visit https://kiwiton-investments.com/options
# Enter symbol: AAPL
# Expected: Option chain loads with strikes, expirations, volume
```

### Test 2: Forex Rates
```bash
# Frontend: Visit https://kiwiton-investments.com/forex
# Select base: USD
# Expected: Exchange rates table loads, major pairs display, converter works
```

### Test 3: Monitoring Grid
```bash
# Frontend: Visit https://kiwiton-investments.com/monitoring
# Expected: 8 microservice status cards display with health indicators
```

### Test 4: SSE Activity Feed
```bash
# Frontend: Open browser console on dashboard
# Check for EventSource connection to /api/account/events
# Expected: "Connected" indicator, events appear when trades execute
```

### Test 5: Journal Notes (Phase B)
```bash
# Frontend: Visit https://kiwiton-investments.com/journal
# Edit a trade note, click Save
# Expected: Note saves successfully, no errors in console
```

---

## Step 5: Verify Service Health

```bash
# Check all service health endpoints
for svc in market api nlp news ml engine backtest broker; do
  echo "=== $svc ==="
  curl -s "https://$svc.kiwiton-investments.com/health" | jq .
done

# Expected: All return {"status":"ok"} or {"status":"healthy"}
```

---

## Rollback Plan (if needed)

### Rollback KTI-Market-Data-Service
```bash
cd ~/apps/KTI-Market-Data-Service
git log --oneline -5  # Find previous commit
git reset --hard <previous-commit-hash>
mkdir -p tmp && touch tmp/restart.txt
```

### Rollback KTI-Gateway
```bash
cd ~/apps/KTI-Gateway
git reset --hard <previous-commit-hash>
mkdir -p tmp && touch tmp/restart.txt
```

### Rollback KTI-DB Migrations
```bash
# Migrations are idempotent but if you need to drop tables:
psql $PROD_DATABASE_URI <<SQL
DROP TABLE IF EXISTS price_alerts CASCADE;
DROP TABLE IF EXISTS alert_history CASCADE;
DROP TABLE IF EXISTS trading_config CASCADE;
DROP TABLE IF EXISTS monitoring_events CASCADE;
ALTER TABLE trades DROP COLUMN IF EXISTS journal_note;
ALTER TABLE trades DROP COLUMN IF EXISTS journal_tags;
ALTER TABLE trades DROP COLUMN IF EXISTS journal_rating;
SQL
```

---

## Post-Deployment Tasks

- [ ] Update `SERVER_ACCESS_ISSUE.md` status to ✅ Resolved
- [ ] Run database index creation (see `KTI-DB/docs/RECOMMENDED_INDEXES.md`)
- [ ] Monitor error rates in Grafana (once Phase 6 observability is complete)
- [ ] Test all new endpoints with Postman/Insomnia collection
- [ ] Update frontend `.env` if API_URL changed

---

## Troubleshooting

### "502 Bad Gateway" after deployment
- Passenger failed to start the app
- Check `~/apps/<service>/tmp/passenger.log` for Python tracebacks
- Verify `.env` has all required variables
- Test import: `cd ~/apps/<service> && python passenger_wsgi.py`

### "ModuleNotFoundError" in logs
- Dependencies not installed in correct venv
- Re-run: `source /home/kiwiton/virtualenv/apps/<service>/3.11/bin/activate && pip install -r requirements.txt`

### "Connection refused" to database
- Verify `PROD_DATABASE_URI` in `.env`
- Test connection: `psql $PROD_DATABASE_URI -c "SELECT 1"`
- Check Postgres is running: `systemctl status postgresql` (if you have access)

### SSE stream not connecting
- Check CORS headers in Gateway
- Verify `EventSource` URL in browser console
- Test with curl: `curl --no-buffer -H "Authorization: Bearer $TOKEN" <sse-url>`

---

**Estimated time**: 15-20 minutes (assuming no issues)

**Next**: Once deployed, proceed with database index creation from `RECOMMENDED_INDEXES.md`
