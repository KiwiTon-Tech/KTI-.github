# KiwiTon Investments — Sprint Plan

**Status**: Active
**Created**: 2026-06-09
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

**Remaining work is Phase 7** (`docs/PHASE_7_IMPLEMENTATION_PLAN.md`). Verified code state:

| Workstream | Plan Status | Actual Code State | Priority |
|---|---|---|---|
| **A — Live Order Execution** | Planned | No `/api/trading/execute` route exists in Gateway | **P0** |
| **B — Real Strategy Backtesting** | Planned | Registry wired to `kti_strategies` + Polygon backend done, **but strategies are SMA/RSI/MACD placeholders** | **P0** |
| **C — WebSocket Streaming** | Planned | Frontend client built (`realtime.js`, `useRealtimePrice`), **backend WS endpoint missing — frontend calls a dead `wss://` URL** | **P1** |
| **D — ML Artifact Storage** | Planned | No `storage.py`; models still on local disk (lost on restart) | **P2** |
| **ML Model Quality** | Phase 4b done | Models still ~50% (coin-flip); 55% DoD not cleared | **P1** |
| **Strategy ML/NLP wiring (7.1)** | Deferred | Placeholders only; no HTTP calls to ML/NLP services | **P1** |

---

## 2. Sprint Plan

Assumes 2-week sprints, solo/small-team velocity. Ordered by risk-adjusted value.
Critical path: **B → A → A-frontend → ML quality → C → D**.

### Sprint 1 — Real Strategy Backtesting (Workstream B finish)

*Lowest risk, unblocks all strategy validation. Foundation already half-built.*

- [ ] Replace placeholder signals with real logic in `KTI-Strategies/kti_strategies/ml_trader.py`, `crypto_trader.py`, `forex_trader.py` — wire HTTP calls to `KTI-ML-Service /predict` + `KTI-NLP-Service /sentiment` (the deferred "Phase 7.1").
- [ ] Add an offline/backtest mode so strategies can pull historical ML predictions without hammering live services (or gracefully degrade to technicals when ML unavailable).
- [ ] Frontend dynamic strategy dropdown — verify `/backtests` page fetches `GET /backtest/strategies/` instead of a hardcoded list.
- [ ] Tests — registry lazy-loads all 4 strategies; one end-to-end backtest per strategy completes with populated Sharpe/metrics.

**Acceptance:** Backtest MLTrader on SPY (30d) completes <60s with real ML signals; frontend shows all 4 strategies.

### Sprint 2 — Live Order Execution Safety Stack (Workstream A)

*P0 but highest risk — real money. Do not rush.*

- [ ] New DAL functions in `KTI-DB`: `get_daily_pnl()`, `get_position_concentration()`.
- [ ] Build `POST /api/trading/execute` in Gateway with all 6 safety layers: paper-mode firewall (`LIVE_TRADING_ENABLED`), kill-switch check, risk preflight (daily-loss + concentration), idempotency key, audit trail to `monitoring_events`.
- [ ] Env vars: `LIVE_TRADING_ENABLED=false`, `MAX_DAILY_LOSS`, `MAX_POSITION_PCT`.
- [ ] Full test matrix — reject on each safety layer; accept valid order; dedupe on idempotency key.

**Acceptance:** All 7 test cases pass; route hard-rejects when `LIVE_TRADING_ENABLED=false`.

### Sprint 3 — Order Execution Frontend + Staged Rollout

- [ ] `OrderConfirmDialog` with paper/live banner, "I understand" checkbox, 3-second countdown.
- [ ] Wire `TradeTicket` to send idempotency key + handle 403 safety rejections.
- [ ] Rollout: dev (paper) → staging (paper, full stack) → prod admin-only with $100 cap → general after 1 incident-free week.
- [ ] Monitoring: Grafana alert on any `/api/trading/execute` 403.

**Acceptance:** Admin can place a guarded paper order end-to-end with confirmation UX.

### Sprint 4 — ML Model Quality (close Phase 4b DoD)

*Models are currently un-tradeable; this gates real profitability.*

- [ ] Flip `NEWS_SENTIMENT_ENABLED=true` and run full `retrain_all` with sentiment features.
- [ ] Probability calibration (`CalibratedClassifierCV`) to fix the "0.93 confidence on 50% model" problem.
- [ ] Use Sprint 1's backtester to measure whether new models beat old ones (not just fold accuracy).
- [ ] Verify nightly cron runs unattended 7+ days.

**Acceptance (Phase 4b DoD):** ≥1 symbol clears 55% accuracy; cron stable 7 days.

### Sprint 5 — WebSocket Price Streaming Backend (Workstream C)

*Frontend is already built and currently pointing at a dead endpoint.*

- [ ] Decide path: Cloudflare Worker + Upstash Redis is the chosen route since cPanel/Passenger can't do WS upgrades.
- [ ] Provision Upstash Redis, scaffold the Alpaca WS consumer (Fly.io free tier) publishing to `prices.*`, and the Cloudflare Worker at `/ws/prices` fanning out to clients.
- [ ] Cloudflare DNS — orange-cloud only the `/ws/*` path.

**Acceptance:** `wss://api.kiwiton-investments.com/ws/prices` delivers ticks <100ms p99; existing `useRealtimePrice` hook lights up live.

### Sprint 6 — WebSocket Frontend Polish + ML Artifact Storage (Workstream D)

- [ ] C frontend: connection status indicator in navbar, fallback-to-snapshot, load test (100 conns × 10 symbols).
- [ ] D: `KTI-ML-Service/app/storage.py` with Cloudflare R2 (boto3 S3 API); save/load models to R2 + version metadata in DB; verify model survives Passenger restart.

**Acceptance:** Live prices stream in UI with status indicator; ML model reloads from R2 after restart.

---

## 3. Backlog / Tech Debt (not sprint-critical)

- **Frontend:** GraphQL codegen migration + `.js`→`.tsx` audit (`FRONTEND_TODO.md`); commit `package-lock.json` + enforce `npm ci` to stop server-pull drift.
- **Gateway:** unit/integration test suite for dashboard aggregation partial-failure paths.
- **Strategy Engine:** persist orchestrator state (daemon threads die on Passenger restart).
- **Regime features** for ML (VIX, SPY 50/200 cross) — big lever, deferred per Phase 4b.

---

## 4. Summary

Sprints 1–3 deliver real, safely-executable trading; Sprint 4 makes the models actually profitable; Sprints 5–6 deliver day-trading UX and durable model storage.
