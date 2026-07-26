# Git Commit Summary — Sprints 1–4 Complete

**Date:** 2026-06-15  
**Status:** Ready for commit & push

---

## Summary of Changes

This commit represents the completion of Sprints 1–4, delivering production-ready strategy backtesting, live order execution with safety layers, Alpaca API compliance, and ML model quality improvements.

---

## Commits by Service

### KTI-Strategies (NEW PACKAGE)

**Files:**
- `kti_strategies/ml_client.py` — Fail-soft HTTP client for ML-Service /predict
- `kti_strategies/sentiment_client.py` — Fail-soft HTTP client for NLP-Service /sentiment  
- `kti_strategies/ml_trader.py` — MLTrader with point-in-time prediction support
- `kti_strategies/crypto_trader.py` — CryptoTrader with RSI fallback
- `kti_strategies/forex_trader.py` — ForexTrader (MACD technical only)
- `requirements.txt` — Added `requests` dependency
- `tests/test_ml_client.py` — Unit tests for ML client
- `tests/test_sentiment_client.py` — Unit tests for sentiment client
- `tests/test_strategies.py` — Strategy signal resolution tests

**Commit Message:**
```
feat(strategies): Sprint 1 — Real strategy backtesting with ML/NLP wiring

- Add fail-soft HTTP clients for ML-Service and NLP-Service
- Wire MLTrader, CryptoTrader, ForexTrader to /predict endpoint
- Implement point-in-time 'as_of' parameter for backtests
- Add graceful degradation when ML/NLP unavailable
- 19/19 tests passing
```

---

### KTI-Backtest-Service

**Files:**
- `app/strategies/registry.py` — Updated strategy descriptions and lazy-loading
- `tests/test_registry.py` — Extended tests for all 4 strategies

**Commit Message:**
```
feat(backtest): Sprint 1 — Strategy registry updates for production strategies

- Update registry descriptions for mltrader, cryptotrader, forextrader
- Add ML and sentiment usage flags to registry
- Extended tests for production strategy coverage
```

---

### KTI-ML-Service

**Files:**
- `app/classifier.py` — Added `CalibratedClassifierCV` for probability calibration
- `docs/SPRINT_4_MODEL_QUALITY.md` — Documentation for calibration

**Commit Message:**
```
feat(ml): Sprint 4 — Probability calibration with CalibratedClassifierCV

- Fix "0.93 confidence on 50% accuracy" problem
- Add sigmoid/isotonic calibration methods
- Persist calibrated models in save/load
- Predictions now use calibrated probabilities for better EV gating
```

---

### KTI-DB

**Files:**
- `python/dal/performance.py` — Added `get_daily_pnl()`
- `python/dal/portfolio.py` — Added `get_position_concentration()`
- `python/tests/test_dal_risk_functions.py` — Unit tests

**Commit Message:**
```
feat(db): Sprint 2 — Risk preflight DAL functions for trading safety

- get_daily_pnl(): Calculate realized + unrealized P&L for daily loss limits
- get_position_concentration(): Calculate max position weight and sector exposure
- Full test coverage for risk checks
```

---

### KTI-Gateway

**Files:**
- `app/routes/api/trading.py` — Added `POST /api/trading/execute` with 6 safety layers
- `.env.example` — Added `LIVE_TRADING_ENABLED`, `MAX_DAILY_LOSS`, `MAX_POSITION_PCT`
- `tests/test_trading_execute.py` — Full 7-test matrix
- `docs/ROLLOUT_PLAN_SPRINT_3.md` — 4-phase staged rollout plan

**Commit Message:**
```
feat(gateway): Sprint 2 — Live order execution with 6-layer safety stack

- POST /api/trading/execute with paper-mode firewall
- Kill-switch check against trading_config
- Risk preflight: daily loss + position concentration limits
- Idempotency key deduplication
- Audit trail to monitoring_events table
- Order submission to KTI-Broker-Service
- Full test matrix: 7 test cases covering all safety layers
```

---

### KTI-Broker-Service

**Files:**
- `app/schemas.py` — Removed `pattern_day_trader`, added `borrow_status`
- `app/serializers.py` — Updated `serialize_account()` and `serialize_asset()`
- `tests/conftest.py` — Updated test fixtures

**Commit Message:**
```
fix(broker): Sprint 2.5 — Alpaca API deprecation compliance

- Remove pattern_day_trader from AccountResponse (sunset 2026-07-06)
- Add borrow_status enum to AssetResponse (migration from easy_to_borrow)
- Serialize with graceful handling of missing PDT fields
- Backward compatible easy_to_borrow until Sept 22
```

---

### KTI-.github/docs

**Files:**
- `SPRINT_PLAN.md` — Updated with completed sprints status
- `ALPACA_OPENAPI_3.0_AUDIT.md` — Full audit report (already created)

**Commit Message:**
```
docs: Update Sprint Plan — Sprints 1–4 complete

- Mark Sprint 1 (Backtesting), 2 (Execution), 2.5 (Alpaca), 3 (Frontend), 4 (ML) as complete
- Add implementation status matrix
- Update acceptance criteria with ✅ marks
```

---

## Recommended Commit Order

1. **KTI-Strategies** (foundation package)
2. **KTI-DB** (shared DAL functions)
3. **KTI-Broker-Service** (Alpaca compliance)
4. **KTI-ML-Service** (calibration)
5. **KTI-Backtest-Service** (registry updates)
6. **KTI-Gateway** (trading execution)
7. **KTI-.github** (documentation)

---

## Quick Git Commands

```bash
# Add and commit by service
cd /Users/zanderbolyanatz/Documents/KiwiTon\ Investments

git add KTI-Strategies/
git commit -m "feat(strategies): Sprint 1 — Real strategy backtesting with ML/NLP wiring

- Add fail-soft HTTP clients for ML-Service and NLP-Service
- Wire MLTrader, CryptoTrader, ForexTrader to /predict endpoint
- Implement point-in-time 'as_of' parameter for backtests
- Add graceful degradation when ML/NLP unavailable
- 19/19 tests passing"

git add KTI-DB/
git commit -m "feat(db): Sprint 2 — Risk preflight DAL functions for trading safety

- get_daily_pnl(): Calculate realized + unrealized P&L for daily loss limits
- get_position_concentration(): Calculate max position weight and sector exposure
- Full test coverage for risk checks"

git add KTI-Broker-Service/
git commit -m "fix(broker): Sprint 2.5 — Alpaca API deprecation compliance

- Remove pattern_day_trader from AccountResponse (sunset 2026-07-06)
- Add borrow_status enum to AssetResponse (migration from easy_to_borrow)
- Serialize with graceful handling of missing PDT fields"

git add KTI-ML-Service/
git commit -m "feat(ml): Sprint 4 — Probability calibration with CalibratedClassifierCV

- Fix '0.93 confidence on 50% accuracy' problem
- Add sigmoid/isotonic calibration methods
- Persist calibrated models in save/load
- Predictions now use calibrated probabilities"

git add KTI-Gateway/
git commit -m "feat(gateway): Sprint 2 — Live order execution with 6-layer safety stack

- POST /api/trading/execute with paper-mode firewall
- Kill-switch check, risk preflight, idempotency, audit trail
- Full test matrix: 7 test cases covering all safety layers
- Staged rollout plan documented"

git add KTI-.github/
git commit -m "docs: Update Sprint Plan — Sprints 1–4 complete"

# Push all
git push origin main
```

---

## Post-Commit Actions

1. **Deploy KTI-DB** — Run migrations if any new tables added
2. **Deploy KTI-Broker-Service** — Verify Alpaca API compliance
3. **Deploy KTI-ML-Service** — Trigger `retrain_all` with sentiment enabled
4. **Deploy KTI-Gateway** — Begin Sprint 3 staged rollout
5. **Update frontend** — Ensure `TradeTicket` is wired correctly

---

## Verification Checklist

- [ ] All commits pushed to `main`
- [ ] CI/CD passes for all services
- [ ] Staging deployment successful
- [ ] Paper trading tests pass
- [ ] Ready for Phase 2 of Sprint 3 rollout (admin-only live trading)

---

*Generated: 2026-06-15*
