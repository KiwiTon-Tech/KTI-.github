# Server Access Issue

**Date**: 2026-05-26  
**Status**: 🔴 Blocked  
**Impact**: Cannot deploy Phase C changes to production

---

## Issue

Unable to access cPanel server to deploy the following services:
- `KTI-Market-Data-Service` (Phase C: historical, options, crypto orderbook endpoints)
- `KTI-Gateway` (Phase C: market extensions, account config, SSE events, position exercise)
- `KTI-DB` migrations 009 + 010 (price_alerts, trading_config, journal fields, portfolio upserts)

## Pending Deployments

### KTI-Market-Data-Service
- **Commit**: `307e2a6` - "feat(phase-c): add historical, options and crypto orderbook endpoints"
- **Changes**: 
  - 15 new AlpacaDataClient methods
  - `routes/historical.py`, `routes/options.py`
  - Crypto trades + orderbook in `routes/trades.py`
- **Target**: `market.kiwiton-investments.com`

### KTI-Gateway
- **Commit**: `8d6bd2c` - "feat(phase-c): market extensions, account config, SSE events, position exercise"
- **Changes**:
  - 20 new files (1753 insertions)
  - `routes/api/market.py`, `routes/api/account.py`, `routes/api/positions.py`
  - `routes/market_data/market_historical.py`, `routes/market_data/market_options.py`
  - Extended `clients/market_data.py` with 13 proxy methods
- **Target**: `api.kiwiton-investments.com`

### KTI-DB
- **Commit**: `b8c7079` - "feat(phase-a-b-c): migrations 009/010 and new DAL modules"
- **Changes**:
  - Migration 009: `price_alerts`, `alert_history`, `trading_config`, `monitoring_events`
  - Migration 010: `journal_note/tags/rating` on trades; unique constraints for portfolio upserts
  - New DAL: `performance.py`, `alerts.py`, `costs.py`
- **Action needed**: Run migrations against production Postgres

## Workaround

Proceeding with frontend UI development using mock data / local dev servers until server access is restored.

## Resolution Steps (when access restored)

1. SSH into cPanel server
2. Deploy KTI-Market-Data-Service:
   ```bash
   cd ~/KTI-Market-Data-Service
   git pull origin main
   touch tmp/restart.txt  # Passenger restart
   ```
3. Deploy KTI-Gateway:
   ```bash
   cd ~/KTI-Gateway
   git pull origin main
   touch tmp/restart.txt
   ```
4. Run KTI-DB migrations:
   ```bash
   cd ~/tools/KTI-DB
   git pull origin main
   source venv/bin/activate
   python python/migrate.py
   ```
5. Verify health probes:
   - `https://market.kiwiton-investments.com/health`
   - `https://api.kiwiton-investments.com/health`
6. Smoke test Phase C endpoints (see `PHASE_C_TESTING.md`)

---

**Next update**: When server access is restored or alternative deployment method is established.
