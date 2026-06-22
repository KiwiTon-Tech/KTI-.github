# KiwiTon Investments — Sprint Plan

**Status**: Sprints 1–6 Partially Complete — Sprint 5 pending CF Worker deploy; Sprint 6 D complete
**Created**: 2026-06-09
**Updated**: 2026-06-22
**Owner**: Zander Bolyanatz

This plan captures the remaining work to finish **Phase 7** (critical backend & trading infrastructure) plus model-quality and tech-debt items, based on a full repo audit. It supersedes the planning sections of `PHASE_7_IMPLEMENTATION_PLAN.md` with verified code state.

---

## 1. Current State Assessment

**Live in production (Phases 1–6 complete):**

- `KTI-Gateway` — JWT auth, rate limiting, CSRF, broker/market/ML/news/backtest proxies, dashboard aggregation, Google OAuth.
- `KTI-Broker-Service`, `KTI-Market-Data-Service`, `KTI-NLP-Service`, `KTI-News-Sentiment-Service` — all wired.
- `KTI-ML-Service` — Phase 4b shipped (EV gating, sentiment features, async `/train`, nightly cron).
- `KTI-Strategy-Engine` — orchestrator live (start/stop/kill-switch/heartbeat/capital).
- Frontend — fully wired to Gateway (Phases A/B/C complete per `WIRING_AUDIT.md`).

**Completed Sprints 1–4:**

| Workstream | Sprint | Status | Code Location |
|---|---|---|---|
| **A — Live Order Execution** | 2 | ✅ **Complete** | `KTI-Gateway/app/routes/api/trading.py` |
| **B — Real Strategy Backtesting** | 1 | ✅ **Complete** | `KTI-Strategies/kti_strategies/`, `KTI-Backtest-Service/` |
| **Alpaca API Maintenance** | 2.5 | ✅ **Complete** | `KTI-Broker-Service/app/serializers.py` (PDT fields removed) |
| **Order Execution Frontend** | 3 | ✅ **Complete** | `KiwiTon Investment Frontend/src/components/trading/` |
| **ML Model Quality** | 4 | ✅ **Implemented** | `KTI-ML-Service/app/classifier.py` (calibration) |
| **C — WebSocket Streaming** | 5 | 🚧 **In Progress** | `KTI-CF-WS-Worker/`, `KTI-Price-Publisher/` scaffolded; deploy pending |
| **D — ML Artifact Storage** | 6 | ✅ **Complete** | `KTI-ML-Service/app/storage.py` — R2 live, cold-start restore verified |

---

## 2. Sprint Plan

Assumes 2-week sprints, solo/small-team velocity. Ordered by risk-adjusted value.
Critical path: **B → A → A-frontend → ML quality → C → D**.

### Sprint 1 — Real Strategy Backtesting (Workstream B finish) ✅ COMPLETE

*Completed: 2026-06-15*

- [x] Replace placeholder signals with real logic in `KTI-Strategies/kti_strategies/ml_trader.py`, `crypto_trader.py`, `forex_trader.py` — wire HTTP calls to `KTI-ML-Service /predict` + `KTI-NLP-Service /sentiment`.
- [x] Add an offline/backtest mode so strategies can pull historical ML predictions without hammering live services (or gracefully degrade to technicals when ML unavailable).
- [x] Frontend dynamic strategy dropdown — verify `/backtests` page fetches `GET /backtest/strategies/` instead of a hardcoded list.
- [x] Tests — registry lazy-loads all 4 strategies; one end-to-end backtest per strategy completes with populated Sharpe/metrics.

**Acceptance:** ✅ Backtest MLTrader on SPY (30d) completes <60s with real ML signals; frontend shows all 4 strategies. **19/19 tests passing.**

### Sprint 2 — Live Order Execution Safety Stack (Workstream A) ✅ COMPLETE

*Completed: 2026-06-15*

- [x] New DAL functions in `KTI-DB`: `get_daily_pnl()`, `get_position_concentration()`.
- [x] Build `POST /api/trading/execute` in Gateway with all 6 safety layers: paper-mode firewall (`LIVE_TRADING_ENABLED`), kill-switch check, risk preflight (daily-loss + concentration), idempotency key, audit trail to `monitoring_events`.
- [x] Env vars: `LIVE_TRADING_ENABLED=false`, `MAX_DAILY_LOSS`, `MAX_POSITION_PCT`.
- [x] Full test matrix — reject on each safety layer; accept valid order; dedupe on idempotency key.

**Acceptance:** ✅ All 7 test cases pass; route hard-rejects when `LIVE_TRADING_ENABLED=false`.

### Sprint 2.5 — Alpaca API Maintenance (Compliance) ✅ COMPLETE

*Completed: 2026-06-15*

**Before July 6, 2026 (FINRA PDT rule change):**
- [x] Remove `daytrade_count`, `daytrading_buying_power`, `pattern_day_trader` from dashboard/account display
- [x] Update `KTI-Broker-Service` account serializer to handle missing PDT fields gracefully
- [x] Test: account response without deprecated fields doesn't crash

**Before September 22, 2026:**
- [x] Migrate `easy_to_borrow` → `borrow_status` in asset serializer (boolean → enum)
- [x] Add `margin_requirement_long`/`margin_requirement_short` to assets schema + serializer (2026-06-22)

**Documentation:**
- [x] `docs/ALPACA_OPENAPI_3.0_AUDIT.md` — Full audit report with deadlines

**Acceptance:** ✅ All tests pass; no references to deprecated PDT fields in codebase.

### Sprint 3 — Order Execution Frontend + Staged Rollout ✅ COMPLETE

*Completed: 2026-06-15 (components pre-existing, rollout plan added)*

- [x] `OrderConfirmDialog` with paper/live banner, "I understand" checkbox, 3-second countdown.
- [x] Wire `TradeTicket` to send idempotency key + handle 403 safety rejections.
- [x] Rollout: dev (paper) → staging (paper, full stack) → prod admin-only with $100 cap → general after 1 incident-free week.
- [ ] Monitoring: Grafana alert on any `/api/trading/execute` 403 (pending Grafana setup)

**Documentation:**
- [x] `KTI-Gateway/docs/ROLLOUT_PLAN_SPRINT_3.md` — 4-phase rollout plan with emergency procedures

**Acceptance:** ✅ Admin can place a guarded paper order end-to-end with confirmation UX.

### Sprint 4 — ML Model Quality (close Phase 4b DoD) ✅ IMPLEMENTED

*Code complete: 2026-06-15; Pending: sentiment enablement + retrain*

- [ ] Flip `NEWS_SENTIMENT_ENABLED=true` and run full `retrain_all` with sentiment features (requires deployment).
- [x] Probability calibration (`CalibratedClassifierCV`) to fix the "0.93 confidence on 50% model" problem.
- [ ] Use Sprint 1's backtester to measure whether new models beat old ones (pending retrain).
- [ ] Verify nightly cron runs unattended 7+ days (pending deployment).

**Implementation:**
- [x] `CalibratedClassifierCV` integration in `SignalClassifier`
- [x] Persist/load calibrated models
- [x] `calibration_method` parameter (`sigmoid`/`isotonic`)

**Documentation:**
- [x] `KTI-ML-Service/docs/SPRINT_4_MODEL_QUALITY.md` — Testing & validation guide

**Acceptance (Phase 4b DoD):** ≥1 symbol clears 55% accuracy; cron stable 7 days. **(Pending retrain)**

### Sprint 5 — WebSocket Price Streaming Backend (Workstream C) 🚧 IN PROGRESS

*Frontend is already built and currently pointing at a dead endpoint.*

**Architecture chosen (2026-06-21): Fly.io publisher → HTTP POST → Cloudflare Worker + Durable Object**
- Direct POST eliminates polling latency and Redis from the hot path (<10ms publisher→browser p99)
- `PriceHub` Durable Object maintains `Map<symbol, Set<WebSocket>>` and broadcasts in-memory
- REST traffic on `api.kiwiton-investments.com` passes through Cloudflare transparently to cPanel

- [x] Decide path: **direct HTTP POST from Fly.io → CF Worker Durable Object** (no Redis needed for tick delivery)
- [x] Scaffold `KTI-CF-WS-Worker` — Cloudflare Worker + `PriceHub` Durable Object (`/ws/prices`, `/internal/tick`, `/health`)
- [x] Scaffold `KTI-Price-Publisher` — Fly.io Python service (alpaca-py `StockDataStream`/`CryptoDataStream` → POST to CF Worker)
- [x] TypeScript type-check passes clean (`npm run type-check`)
- [ ] **DNS**: Orange-cloud `api.kiwiton-investments.com` in Cloudflare dashboard
- [ ] **Deploy CF Worker**: `wrangler secret put INTERNAL_SECRET` + `npm run deploy` in `KTI-CF-WS-Worker/`
- [ ] **Deploy Fly.io publisher**: `fly apps create kti-price-publisher` + `fly secrets set ...` + `fly deploy`
- [ ] Smoke test: `wscat -c wss://api.kiwiton-investments.com/ws/prices` → subscribe AAPL → receive ticks

**Acceptance:** `wss://api.kiwiton-investments.com/ws/prices` delivers ticks <100ms p99; existing `useRealtimePrice` hook lights up live.

### Sprint 6 — WebSocket Frontend Polish + ML Artifact Storage (Workstream D) ✅ COMPLETE

*Completed: 2026-06-22*

- [x] C frontend: `ConnectionStatus` wired into desktop + mobile navbar; `useRealtimePrice` now falls back to `marketApi.getLatestTrades` polling (5s interval) when WS disconnected; exposes `wsStatus` return value.
- [x] D: `KTI-ML-Service/app/storage.py` — `R2ModelStorage` (boto3 S3-compatible); `ModelRegistry` mirrors every `.pkl` + manifest to R2 on `save_version`; auto-restores from R2 on cold-start if local `models/` is empty.
- [x] **Provision R2 bucket**: `kti-ml-models` bucket live; R2 credentials set in cPanel `.env`.
- [x] Smoke-test R2: 16 pkl files + manifest uploaded; cold-start restore verified (manifest appears in empty `models/` on Passenger init).
- [ ] Load test (post-WS-deploy): 100 conns × 10 symbols with `wscat` / k6.

**Acceptance:** ✅ ML model reloads from R2 after restart confirmed. Live price streaming pending Sprint 5 deploy.

---

## 3. Infrastructure & DevOps (Deployment Automation Complete)

### Deployment Automation (✅ Complete — 2026-06-22)

Auto-deploy and monitoring scripts for cPanel/Passenger. All services deploy within 5 min of a push to `main`.

- [x] `deploy.sh` in every cPanel service — git pull, pip install, Passenger restart, health check
- [x] `auto-update.sh` — Polls GitHub every 5 min, auto-deploys on new commits; bootstrap-pulls `deploy.sh` if missing
- [x] `health-check.sh` — Monitors services, auto-restarts unhealthy (cron)
- [x] `install-deployment-automation.sh` — One-command setup
- [x] Cron installed: `*/5 * * * * /home/kiwiton/bin/auto-update.sh`
- [x] lumibot/thetadata workaround for KTI-Backtest-Service (pip 26 + py3.11 yanked-package fix)

**Services tracked by auto-update:** KTI-Gateway, KTI-Broker-Service, KTI-Market-Data-Service, KTI-News-Sentiment-Service, KTI-NLP-Service, KTI-Backtest-Service, KTI-Strategy-Engine, KTI-ML-Service

**Documentation:** [`docs/DEPLOYMENT_AUTOMATION.md`](./docs/DEPLOYMENT_AUTOMATION.md)

**Usage:**
```bash
# Manual deploy
/home/kiwiton/apps/KTI-Gateway/deploy.sh

# Check status
/home/kiwiton/bin/kti-status

# View logs
tail -f /home/kiwiton/logs/auto-update.log
```

---

## 4. Backlog / Tech Debt (not sprint-critical)

- **Frontend:** GraphQL codegen migration + `.js`→`.tsx` audit (`FRONTEND_TODO.md`); commit `package-lock.json` + enforce `npm ci` to stop server-pull drift.
- **Gateway:** unit/integration test suite for dashboard aggregation partial-failure paths.
- **Strategy Engine:** persist orchestrator state (daemon threads die on Passenger restart).
- **Regime features** for ML (VIX, SPY 50/200 cross) — big lever, deferred per Phase 4b.

---

## 5. Summary

**Completed:** Sprints 1–4 deliver real strategy backtesting, safely-executable trading with 6-layer safety stack, Alpaca API compliance (July 6 ready), probability-calibrated ML models, and full deployment automation. Sprint 6 (Workstream D) complete — ML artifact storage live on Cloudflare R2 with cold-start restore. All 8 cPanel services on 5-min auto-deploy cron.

**Next:** Sprint 5 deployment — orange-cloud DNS, deploy CF Worker (`wrangler deploy`), deploy Fly.io publisher (`fly deploy`), smoke-test `wss://api.kiwiton-investments.com/ws/prices`.
