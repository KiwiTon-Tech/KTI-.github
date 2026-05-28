# KiwiTon Investments — Microservices Architecture

> **Status**: Phase 6 complete (8 services live, structured logging + Prometheus); Phase 7 frontend in progress — Workstreams A (order execution UI) and C (WebSocket layer) shipped, Section 10.2 architectural substrate complete, Sprint 2 page rollouts underway (`/positions`, `/dashboard`, `/trades`, `/signals`, `/models`, `/symbol`, `/backtests`, `/trade` migrated)
> **Last updated**: 2026-05-28
> **Owner**: Zander Bolyanatz

This document describes the target microservices decomposition for the KiwiTon
Investments platform, the responsibilities of each service, how they
communicate, and the rollout plan from the current semi-monolithic layout
(`Kiwiton-Investments-Backend` + `KiwiTon-Strategy-Engine`) into
independently-deployed repositories with their own CI/CD pipelines.

---

## 1. Goals

- **Independent deployability** — each service ships on its own pipeline; a
  broken ML retrain must not block a broker hotfix.
- **Isolated scaling** — WebSocket fan-out, batch backtests, GPU-bound NLP,
  and low-latency strategy execution each have very different resource
  profiles.
- **Single source of truth** — Alpaca is currently wrapped twice (Python +
  TypeScript). Every external dependency should live behind exactly one
  service.
- **Clear ownership** — one repo = one responsibility = one CI/CD workflow.
- **Language-appropriate stacks** — Python where ML/quant lives, TypeScript
  where the BFF lives, nothing forced across the boundary.

---

## 2. Service Catalog

All repos live under the [`KiwiTon-Tech`](https://github.com/KiwiTon-Tech) org
with the `KTI-` prefix. Thirteen repos: nine application services plus four
shared/infra repos.

| # | Repo | Language | Type | Status |
|---|------|----------|------|--------|
| 1 | [`KTI-Gateway`](https://github.com/KiwiTon-Tech/KTI-Gateway) | Python (Flask) | BFF / API gateway | ✅ Live at `api.kiwiton-investments.com` (broker integration complete) |
| 2 | [`KTI-Broker-Service`](https://github.com/KiwiTon-Tech/KTI-Broker-Service) | Python (FastAPI) | Alpaca adapter | ✅ Live at `broker.kiwiton-investments.com` |
| 3 | [`KTI-Market-Data-Service`](https://github.com/KiwiTon-Tech/KTI-Market-Data-Service) | Python (FastAPI + WS) | Streaming | ✅ Live at `market.kiwiton-investments.com` (REST only; WS deferred to Phase 3b) |
| 4 | [`KTI-NLP-Service`](https://github.com/KiwiTon-Tech/KTI-NLP-Service) | Python (FastAPI) | ML inference (FinBERT) | ✅ Live at `nlp.kiwiton-investments.com` |
| 5 | [`KTI-News-Sentiment-Service`](https://github.com/KiwiTon-Tech/KTI-News-Sentiment-Service) | Python (FastAPI) | News ingest + sentiment API | ✅ Live at `news.kiwiton-investments.com` |
| 6 | [`KTI-ML-Service`](https://github.com/KiwiTon-Tech/KTI-ML-Service) | Python (FastAPI) | ML train + predict | ✅ Live at `ml.kiwiton-investments.com` |
| 7 | [`KTI-Strategy-Engine`](https://github.com/KiwiTon-Tech/KTI-Strategy-Engine) | Python (FastAPI) | Strategy orchestrator | ✅ Live at `engine.kiwiton-investments.com` (orchestrator + strategy registry; `/orchestrator/*` + `/strategies/*` proxied via Gateway) |
| 8 | [`KTI-Backtest-Service`](https://github.com/KiwiTon-Tech/KTI-Backtest-Service) | Python (FastAPI) | Job queue + workers | ✅ Live at `backtest.kiwiton-investments.com` (Lumibot engine, SMA crossover reference strategy, Postgres job queue) |
| 9 | [`KTI-Orchestrator`](https://github.com/KiwiTon-Tech/KTI-Orchestrator)* | Python | Control plane | Optional |
| 10 | [`KTI-Observability`](https://github.com/KiwiTon-Tech/KTI-Observability) | Python + YAML | Metrics + logging | ✅ Phase 6 — `structlog` + Prometheus `/metrics` deployed to all 8 services; Grafana Cloud dashboard ready to import |
| 11 | [`KTI-DB`](https://github.com/KiwiTon-Tech/KTI-DB) | SQL + Python + TS | Central schema + DAL | ✅ Deployed (8 migrations applied) |
| 12 | [`KTI-Contracts`](https://github.com/KiwiTon-Tech/KTI-Contracts)* | OpenAPI + codegen | Typed cross-service clients | Optional |
| 13 | [`KTI-.github`](https://github.com/KiwiTon-Tech/KTI-.github) | YAML + MD | Reusable CI workflows + deployment playbook | ✅ Live |

\* Optional — `KTI-Orchestrator` may fold into `KTI-Strategy-Engine`;
`KTI-Contracts` is deferred until more than two services talk to each other.

**Deployment target**: all Python services run on shared cPanel (CloudLinux)
via Phusion Passenger, not Docker. See
[`KTI-.github/docs/CPANEL_DEPLOYMENT.md`](https://github.com/KiwiTon-Tech/KTI-.github/blob/main/docs/CPANEL_DEPLOYMENT.md)
for the playbook.

---

## 3. Service Details

### 3.1 `KTI-Gateway`
**Purpose**: The single public entrypoint. Thin BFF (Backend-for-Frontend)
that the frontend (`KiwiTon Investment Frontend`) talks to.

**Tech Stack**: Flask + flask-smorest + Marshmallow + Gunicorn. Originally
planned as Next.js; pivoted to Flask for consistency with the rest of the
Python service mesh and to leverage existing team expertise. Auto-generated
OpenAPI 3.0 docs at `/docs` (Swagger UI).

**Responsibilities**
- Authentication, session/JWT issuance, CSRF, rate limiting.
- Request routing + response shaping for the UI.
- Aggregation of downstream service responses (e.g. dashboard = broker +
  market-data + ml-service).
- No business logic. No direct Alpaca calls. No database writes except for
  auth/session tables.
- Service health aggregation for frontend status indicators.

**Current State** (as of 2026-05-24): **Frontend ↔ Gateway wiring Phases A/B/C complete — every `api.js` client object has a live Gateway route.** Only remaining stub: `tradingApi.executeTrade` (POST /api/trading/execute) — not yet used by any page and requires safety controls around live order submission.

#### Part 1 — Routes wired (this sprint)

**Broker** (`/broker/*` → `KTI-Broker-Service`)
- `GET    /broker/balance/` — account info
- `GET    /broker/balance/positions` — all open positions
- `GET    /broker/balance/positions/<symbol>` — position by symbol
- `DELETE /broker/balance/positions/<symbol>` — close one position
- `DELETE /broker/balance/positions` — close all positions
- `GET    /broker/balance/portfolio/history` — equity curve
- `GET    /broker/trade/orders` — list orders
- `POST   /broker/trade/orders` — create order
- `GET    /broker/trade/orders/<id>` — order detail
- `DELETE /broker/trade/orders/<id>` — cancel one order
- `DELETE /broker/trade/orders` — cancel all open orders
- `GET    /broker/trade/orders/by-client-id` — order lookup by `client_order_id`
- `GET    /broker/clock/` — trading clock (is_open, next open/close)
- `GET    /broker/clock/calendar` — market calendar
- `GET    /broker/activities/` — account activities (fills, dividends, fees)
- `GET    /broker/watchlists/` — list watchlists
- `POST   /broker/watchlists/` — create watchlist
- `GET    /broker/watchlists/<id>` — get watchlist
- `PUT    /broker/watchlists/<id>` — update watchlist
- `DELETE /broker/watchlists/<id>` — delete watchlist
- `POST   /broker/watchlists/<id>/assets` — add asset to watchlist
- `DELETE /broker/watchlists/<id>/assets` — remove asset from watchlist
- `GET    /broker/assets/` — list tradable assets
- `GET    /broker/assets/<symbol_or_id>` — asset reference data

**Market Data** (`/market/*` → `KTI-Market-Data-Service`)
- `GET /market/bars/` — historical OHLCV bars (stocks + crypto)
- `GET /market/bars/latest` — latest bar per symbol
- `GET /market/quotes/latest` — latest bid/ask per symbol
- `GET /market/trades/latest` — latest trade per symbol
- `GET /market/snapshots/` — full snapshot per symbol
- `GET /market/news/` — Alpaca news feed
- `GET /market/crypto/bars` — historical bars for crypto pairs
- `GET /market/crypto/bars/latest` — latest bar for crypto pairs
- `GET /market/crypto/quotes/latest` — latest quote for crypto pairs
- `GET /market/crypto/snapshots` — snapshot for crypto pairs
- `GET /market/crypto/trades` — historical trades for crypto pairs
- `GET /market/crypto/orderbook` — latest orderbook (bids + asks) for crypto pairs
- `GET /market/screener/most-actives` — most-active US equities by volume/trades
- `GET /market/screener/movers` — top gaining/losing US equities
- `GET /market/historical/quotes` — historical quotes per symbol (stocks + crypto)
- `GET /market/historical/trades` — historical trades per symbol (stocks + crypto)
- `GET /market/historical/auctions` — historical auction prices (US equities)
- `GET /market/historical/corporate-actions` — splits, dividends, spin-offs
- `GET /market/options/contracts` — option contracts with filters (underlying, expiry, strike, type)
- `GET /market/options/chain` — full option chain for an underlying symbol
- `GET /market/options/snapshots` — option snapshots (greeks + quote + latest trade)
- `GET /market/options/bars` — historical bars for option symbols
- `GET /market/options/trades` — historical trades for option symbols
- `GET /market/options/quotes` — latest quotes for option symbols

**Backtest** (`/backtest/*` → `KTI-Backtest-Service`)
- `GET  /backtest/jobs/` — list jobs
- `POST /backtest/jobs/` — submit job
- `GET  /backtest/jobs/<id>` — job detail + results
- `POST /backtest/jobs/<id>/cancel` — soft cancel
- `GET  /backtest/strategies/` — strategy catalogue
- `GET  /backtest/jobs/summary` — aggregate stats by strategy/symbol
- `GET  /backtest/jobs/<id>/equity-curve` — extract equity curve from completed job

**DB-backed** (`/trades/*`, `/portfolio/*` → `kti_db` DAL direct)
- `GET    /trades/` — trade history with filters
- `GET    /trades/<id>` — single trade
- `GET    /trades/summary` — aggregate P&L, win rate, avg return
- `PATCH  /trades/<id>` — update journal fields (`journal_note`, `journal_tags`, `journal_rating`)
- `GET    /portfolio/summary` — portfolio-level summary
- `GET    /portfolio/positions` — DB-persisted positions
- `GET    /portfolio/allocations` — target allocations
- `GET    /portfolio/snapshots` — daily equity snapshots
- `GET    /portfolio/rebalances` — rebalance event log
- `GET    /portfolio/constraints` — risk constraints

**Dashboard / Orchestrator** (unchanged)
- `GET /dashboard/` — parallel-aggregated: account + positions + orders + sentiment + orchestrator + service health
- `GET /orchestrator/status`, `POST /orchestrator/start`, `POST /orchestrator/stop`, `POST /orchestrator/kill-switch`, `PUT /orchestrator/capital`

**Service-to-service infrastructure**
- `ServiceClient.base` now has `put()` method; `delete()` accepts `params`.
- `BrokerClient` extended with all new method stubs.
- `MarketDataClient` extended with `get_most_actives()`, `get_movers()`, crypto variants.
- `kti-db` (`psycopg`, `psycopg-pool`) added to `KTI-Gateway/requirements.txt`.

**Frontend `api.js` URL corrections** — 22 endpoints updated from dead `/api/...` legacy
paths to real Gateway paths.

#### Part 2 — `/api/*` Phase A/B/C Routes ✅ COMPLETE (2026-05-24)

All frontend API objects now have a live Gateway route. Below is the full `/api/*` inventory.

**Performance** (`/api/performance/*` → `kti_db` DAL)
- `GET /api/performance/equity-curve` — equity snapshots with optional date range
- `GET /api/performance/metrics` — P&L, win rate, Sharpe, drawdown, total return
- `GET /api/performance/drawdowns` — drawdown history periods
- `GET /api/performance/monthly-returns` — monthly return % series

**Monitoring** (`/api/monitoring/*` → health aggregation + `kti_db`)
- `GET  /api/monitoring/health` — aggregates `/health` from all 8 microservices
- `GET  /api/monitoring/alerts` — fetch monitoring events from DB
- `POST /api/monitoring/alerts` — create monitoring event
- `GET  /api/monitoring/metrics` — proxy Prometheus `/metrics` from each service

**Alerts** (`/api/alerts/*` → `kti_db` `price_alerts` table)
- `GET    /api/alerts/` — list all price alerts
- `POST   /api/alerts/` — create a price alert
- `GET    /api/alerts/<id>` — single alert
- `PATCH  /api/alerts/<id>` — update alert
- `DELETE /api/alerts/<id>` — delete alert
- `GET    /api/alerts/history` — alert firing history

**Statements** (`/api/statements` → `kti_db` trades)
- `GET /api/statements` — P&L statement for `monthly | quarterly | ytd | all | custom` periods

**Trading** (`/api/trading/*` → `kti_db` config + Strategy Engine)
- `GET   /api/trading/status` — orchestrator status + kill-switch state
- `GET   /api/trading/config` — strategy configs from `strategy_configs` table
- `PATCH /api/trading/config` — update strategy config
- `GET   /api/trading/profiles` — list strategy profiles
- `POST  /api/trading/profiles` — switch active profile
- `GET   /api/trading/strategies/<id>/performance` — per-strategy P&L from trades table
- `POST  /api/trading/execute` — ⚠️ **NOT YET WIRED** — live order submission; requires safety controls

**Costs** (`/api/costs/*` → `kti_db` transaction_costs)
- `GET /api/costs/summary` — total costs, avg per trade, by asset class
- `GET /api/costs/by-strategy` — cost breakdown per strategy
- `GET /api/costs/round-trips` — round-trip cost analysis

**ML** (`/api/ml/*` → `kti_db`)
- `GET /api/ml/feature-importance/<model>` — feature importance for a trained model
- `GET /api/ml/predictions` — recent ML prediction log

**Portfolio writes** (`/api/portfolio/*` → `kti_db`)
- `POST /api/portfolio/allocations` — upsert allocation row (keyed on symbol + date)
- `POST /api/portfolio/positions` — upsert position row (keyed on symbol)

**Backtests** (`/api/backtests/*` → KTI-Backtest-Service)
- `GET /api/backtests/by-symbol` — completed backtests grouped by symbol with best Sharpe/return/win-rate

**Market extensions** (`/api/market/*`)
- `GET  /api/market/logos/<symbol>` — 302 redirect to parqet.com CDN logo PNG
- `GET  /api/market/forex/latest` — latest FX rates (open.er-api.com, free, no key)
- `GET  /api/market/forex/historical` — current rates annotated as historical (free tier limitation)
- `GET  /api/market/historical-quotes` — pass-through to `/market/historical/quotes`
- `GET  /api/market/historical-trades` — pass-through to `/market/historical/trades`
- `GET  /api/market/auctions` — pass-through to `/market/historical/auctions`
- `GET  /api/market/corporate-actions` — pass-through to `/market/historical/corporate-actions`
- `GET  /api/market/fixed-income` — returns `501` (Alpaca does not support fixed income)

**Account** (`/api/account/*`)
- `GET   /api/account/config` — account-level config from `trading_config` table (key=`account`)
- `PATCH /api/account/config` — merge-upsert account config JSON
- `GET   /api/account/events` — **SSE stream** (text/event-stream) polling KTI-Broker-Service activities; params: `activity_types`, `poll_interval`, `max_events`

**Position actions** (`/api/positions/*` → KTI-Broker-Service)
- `POST /api/positions/<symbol>/exercise` — submit options exercise order
- `POST /api/positions/<symbol>/do-not-exercise` — submit do-not-exercise instruction

**DB migrations applied for Phase A/B/C:**
- Migration 009: `price_alerts`, `alert_history`, `trading_config`, `monitoring_events` tables
- Migration 010: `journal_note`, `journal_tags`, `journal_rating` columns on `trades`; unique constraints on `portfolio_allocations` (symbol+date) and `portfolio_positions` (symbol) for upsert safety

**Pulled from**: `Kiwiton-Investments-Backend/app/api/auth/**`,
`middleware.ts`, `src/middleware/**`, and thin proxy handlers for everything
under `app/api/*`.

**Exposes**: HTTPS REST to the frontend. All routes behind `/api` prefix
(once deployed to cPanel with subdomain routing).

---

### 3.2 `KTI-Broker-Service`
**Purpose**: The only code that speaks to Alpaca. Provides a stable internal
API so a future broker (IBKR, Tradovate, etc.) can be swapped in without
changing callers.

**Responsibilities**
- Account, orders, positions, portfolio, watchlists, assets, statements.
- Trading clock / calendar.
- Crypto wallet operations.
- Broker-level order streaming (relayed to market-data-service or directly to
  strategy-engine).

**Pulled from**
- Python: `Modules/Alpaca/**`, `api/routes/{account,alpaca_routes,trading,crypto}.py`.
- TS: `src/trading/alpaca/**`,
  `app/api/{account,orders,positions,portfolio,watchlists,assets,statements}/**`.

**Exposes**: internal REST + optional gRPC. Secrets (`ALPACA_KEY`,
`ALPACA_SECRET`) live **only** here.

#### 3.2.1 Future: multi-broker support (e.g. crypto.com)

Alpaca covers ~20 crypto coins, spot only, USD-only quotes, no perps, no
staking. If/when we need broader altcoin coverage, deeper books for
scalping, or derivatives, we add a **second broker adapter** behind the
same internal contract — we do **not** teach `KTI-Strategy-Engine` to
speak two broker APIs.

**Decision rule (don't add early):** introduce a second adapter only when
one of these is actually true:

- A live strategy needs a coin Alpaca doesn't list.
- Scalping requires deeper books / tighter spreads than Alpaca provides.
- A strategy needs perps / leverage / shorts unavailable on Alpaca.
- Portfolio-level risk controls (`utils/risk_management.py`) and the
  kill-switch are battle-tested and survive multi-venue reconciliation.

**Adapter contract (target shape, kept identical across brokers).** Every
broker adapter MUST expose this REST surface. New adapters are accepted
only when they pass a shared contract test suite that exercises each
endpoint against a sandbox/paper account.

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| `GET`  | `/health` | Liveness | No auth. |
| `GET`  | `/ready`  | Broker reachable + creds valid | Probes account endpoint. |
| `GET`  | `/account` | Equity, cash, buying power | Returns canonical `Account` schema (see below). |
| `GET`  | `/positions` | Open positions | Canonical `Position[]`. |
| `GET`  | `/positions/{symbol}` | Single position | 404 if flat. |
| `GET`  | `/orders` | List orders | Filters: `status`, `symbol`, `since`, `limit`. |
| `POST` | `/orders` | Submit order | **Idempotency key required** (`Idempotency-Key` header). |
| `GET`  | `/orders/{id}` | Order detail | |
| `DELETE` | `/orders/{id}` | Cancel | |
| `GET`  | `/clock` | Market open + next open/close | Crypto venues return `is_open: true` 24/7. |
| `GET`  | `/assets` | Tradeable symbols on this venue | Used by gateway for symbol routing. |
| `GET`  | `/portfolio/history` | Equity curve from broker | Optional; may be served from `KTI-DB` instead. |

**Canonical schemas (pinned in `KTI-Contracts` once that repo lands; until
then, mirrored in each adapter's `app/schemas.py`):**

```python
# Order request — venue-agnostic
class OrderRequest(BaseModel):
    symbol: str                    # canonical form: "BTC/USD", "AAPL"
    side: Literal["buy", "sell"]
    qty: Decimal | None = None     # exactly one of qty/notional
    notional: Decimal | None = None
    type: Literal["market", "limit", "stop", "stop_limit"]
    time_in_force: Literal["day", "gtc", "ioc", "fok"]
    limit_price: Decimal | None = None
    stop_price: Decimal | None = None
    client_order_id: str           # used as idempotency key
    venue_hint: str | None = None  # optional override; gateway usually sets

class Order(BaseModel):
    id: str                        # adapter-local id
    venue: Literal["alpaca", "cryptocom", ...]
    client_order_id: str
    symbol: str                    # canonical
    venue_symbol: str              # raw form sent to broker (e.g. "BTC_USDT")
    side: Literal["buy", "sell"]
    qty: Decimal
    filled_qty: Decimal
    avg_fill_price: Decimal | None
    status: Literal["new","partially_filled","filled","canceled","rejected","expired"]
    submitted_at: datetime
    filled_at: datetime | None
    fees: Decimal                  # in quote currency
```

**Symbol normalisation.** Each adapter owns the bidirectional map between
the **canonical KTI symbol** (`BTC/USD`, `AAPL`) and its venue-native form
(`BTC_USDT` on crypto.com, `BTC/USD` on Alpaca). Callers only ever see
canonical symbols. The map lives in `app/symbols.py` per adapter.

**Routing.** `KTI-Gateway` (and `KTI-Strategy-Engine` when calling
directly) decides which adapter to hit using, in order:

1. Explicit `venue` field on the strategy config row in `strategy_configs`.
2. Symbol prefix / asset class lookup (e.g. crypto with `:CDC` suffix → crypto.com).
3. Default broker per asset class (env-configured: `DEFAULT_STOCK_BROKER=alpaca`,
   `DEFAULT_CRYPTO_BROKER=alpaca`).

**Database changes required before second adapter ships:**

- `trades.venue text NOT NULL DEFAULT 'alpaca'`
- `strategy_configs.venue text NOT NULL DEFAULT 'alpaca'`
- `orders.venue text NOT NULL DEFAULT 'alpaca'` (if/when we mirror orders).
- Composite index `(venue, broker_order_id)` for reconciliation.

Migrations land in `KTI-DB` as a single versioned file, gated behind the
go-live of the second adapter.

**Repo layout when added.**

```
KTI-CryptoCom-Broker-Service/      # sibling of KTI-Broker-Service
├── app/
│   ├── main.py                     # same FastAPI shape
│   ├── routes/{account,orders,positions,clock,assets,portfolio}.py
│   ├── schemas.py                  # imports canonical schemas from KTI-Contracts
│   ├── symbols.py                  # BTC/USD ↔ BTC_USDT map
│   └── cryptocom_client.py         # HMAC-SHA256 signed REST + WS
├── tests/contract/                 # shared suite (git submodule from KTI-Contracts)
└── passenger_wsgi.py
```

**Subdomain**: `cryptocom-broker.kiwiton-investments.com` (grey-cloud,
internal-only — same Cloudflare rules as other adapters).

**Out of scope for v1 of the second adapter:** withdrawals/deposits,
staking, derivatives. Spot trading + read endpoints only.

---

### 3.3 `KTI-Market-Data-Service`
**Purpose**: One place that fetches market data and fans it out. Normalises
across asset classes (stocks, crypto, forex, options).

**Responsibilities**
- REST: bars, quotes, trades, snapshots, news, stock screener (most-actives, top-movers), crypto sub-routes.
- Historical data: historical quotes + trades (stocks + crypto), auction prices, corporate actions.
- Options: contracts list, option chain, snapshots (greeks), bars, trades, latest quotes — via Alpaca `OptionHistoricalDataClient`.
- Crypto extended: historical trades, latest orderbook.
- WebSocket: live price/quote/trade streams for stocks + crypto + news.
- Provider adapters (Alpaca today; OANDA/TwelveData for forex deferred — forex rates served from open.er-api.com free tier via Gateway).
- Caching layer: **in-process TTL cache active** (`app/cache.py`) — 1.5s TTL for equities, 5s for crypto, collapses duplicate symbol requests into one Alpaca call. Thread-safe, process-local. **Redis deferred** (confirmed 2026-05-28 — not installed on cPanel, not needed at current scale).

#### Redis Decision Log

**Decision**: Deferred until a concrete trigger below is hit. Do NOT add for speculative performance gains.

**Implement Redis (Upstash — cloud-hosted, connects via `REDIS_URL`, no server install) when any one of these is true:**

1. **WebSocket price streaming** — Real-time frontend price pushes require Redis Pub/Sub. Market Data Service publishes price events; Gateway subscribes and fans out to WebSocket clients. Without it, polling stays at 1.5s — acceptable for now, noticeable for a live trading UI.
2. **Price alert triggers** — Sub-100ms alert firing (e.g. AAPL hits $315 → instant frontend alert) requires Pub/Sub. Current polling approach fires alerts with up to 1.5s lag.
3. **Multiple Passenger workers** — If `PassengerMaxPool` is increased above 1, the in-process cache fragments: each worker has its own dict, causing duplicate Alpaca calls. Redis becomes the shared cache layer.
4. **Cross-service cache sharing** — If KTI-Gateway needs to read a price cached by KTI-Market-Data-Service (or vice versa) without an extra HTTP round-trip.
5. **Rate-limit headroom** — If Alpaca data rate limits become a real constraint (current IEX free tier: 200 requests/min per key), Redis-backed request coalescing across all consumers eliminates duplicate calls.

**Implementation notes (when the time comes):**
- Use `Upstash Redis` (free tier, `rediss://` TLS URL, no VPS required)
- Cache key structure: `kti:mds:{endpoint}:{asset_class}:{sorted_symbols_hash}` — matches existing `CacheKey` dataclass in `app/cache.py`
- TTLs unchanged: 1.5s equities, 5s crypto — just move from `_store` dict to `redis.setex()`
- `app/cache.py` is designed for this migration: same `get()/set()` interface, swap the backend
- Add `REDIS_URL` env var to `KTI-Market-Data-Service/.env` and `.env.example`

**Pulled from**
- TS: `app/api/market/**`.
- Python: `api/routes/market_routes.py`, `Modules/Realtime/**`,
  `utils/forex_data.py`.

**Exposes**: REST for historical, WS (`/stream/...`) for live.

---

### 3.4 `KTI-NLP-Service`
**Purpose**: Stateless sentiment **model** server. Scores arbitrary text.

**Responsibilities**
- `POST /sentiment` — batch text scoring, returns `[{label, score}]` per
  input.
- Model warm-up on boot, GPU-aware.
- No scraping, no DB, no schedule. Pure inference.

**Pulled from**: `Modules/finBERT/**`, `api/routes/finbert_routes.py`.

**Exposes**: internal REST. Has own `Dockerfile` already.

**Consumers**: `KTI-News-Sentiment-Service` (bulk scoring of scraped
articles), `KTI-Strategy-Engine` (ad-hoc scoring of live headlines from
the news WebSocket), and any future "score this tweet/filing" caller.

---

### 3.5 `KTI-News-Sentiment-Service`
**Purpose**: End-to-end market-sentiment pipeline. Scrapes financial news,
tags ticker mentions, scores each article via `KTI-NLP-Service`, persists
to the shared Postgres, and serves per-symbol aggregates for the dashboard
and strategies.

**Responsibilities**
- **Scrape**: RSS feeds configured via `RSS_FEEDS` env var (categorised
  `stocks|url, crypto|url, forex|url`). Falls back to per-URL retries on
  feed-parse failures, logged but not fatal.
- **Schedule**: continuous background thread; re-runs every
  `SCRAPE_INTERVAL_SECONDS` (default 600 = every 10 min). `POST /refresh`
  triggers a one-off pass. No APScheduler needed.
- **Ticker extraction**: cashtags (`$AAPL`) are always extracted; bare
  uppercase tokens are only extracted if they appear in
  `SYMBOL_ALLOWLIST`. Avoids false positives like "CEO", "USA".
- **Score**: batched `POST /sentiment` to `KTI-NLP-Service` (batch size
  configurable). TextBlob remains an option for a fast baseline but is not
  required for v1.
- **Persist**: via `kti_db.dal.news_sentiment` against the central schema
  in `KTI-DB` (tables `news_articles`, `news_article_symbols`,
  `news_daily_summaries`). **No ORM in this service.**
- **Serve** (internal REST, consumed by `KTI-Gateway` and
  `KTI-Strategy-Engine`):
  - `GET /health` — liveness.
  - `GET /ready` — DB reachable + NLP reachable + sources configured.
  - `GET /articles?symbol=AAPL&category=stocks&since_hours=24&limit=100`
    — recent scored articles with all filters optional.
  - `GET /sentiment/aggregate?symbol=AAPL&hours=24` — per-label counts,
    avg scores, and a single `weighted_score ∈ [-1, 1]` for strategies.
  - `POST /refresh` — token-gated manual trigger.

**Pulled from**
- `Modules/NLP/nlp.py` — URL lists (migrated to RSS), scraping logic.
- `Modules/NLP/sentiment_db.py` — replaced by `kti_db.dal.news_sentiment`.

**Cleanups during extraction**
- Drop `tkinter` + `selenium` + `chromedriver` (unused in the real pipeline).
- Drop Alpaca imports (belong in `KTI-Strategy-Engine`).
- FinBERT lives in exactly one place (`KTI-NLP-Service`), called over HTTP.
- SQLite → Postgres via `KTI-DB` central schema (see §3.11).

**Operational notes**
- Passenger uses `a2wsgi` which does NOT propagate ASGI lifespan events.
  The background pipeline thread is started explicitly from
  `passenger_wsgi.py` — same workaround as `KTI-NLP-Service`.
- Subdomain: `news.kiwiton-investments.com`, Cloudflare DNS-only.

**Exposes**: internal REST.

---

### 3.6 `KTI-ML-Service`
**Purpose**: Feature engineering, signal model training, prediction serving,
and model registry.

**Responsibilities**
- `POST /predict` — given OHLCV + features, return signal + confidence.
- `POST /train` / scheduled retrain — walk-forward retraining with artifact
  versioning.
- Feature store (technical indicators, etc.).
- Expected value + adaptive threshold computations.
- Model registry (track metrics, promote/demote models).

**Pulled from**: `utils/{features,signal_classifier,ml_trading,model_registry,
retraining_pipeline,adaptive_thresholds,expected_value}.py`,
`app/api/ml/**`.

**Exposes**: internal REST. Artifacts stored in S3/GCS (or on-disk for dev).

---

### 3.7 `KTI-Strategy-Engine`
**Purpose**: The actual trading bots. Long-running workers that subscribe to
market data and execute trades.

**Responsibilities**
- Stock / crypto / forex / scalping strategies.
- Multi-symbol portfolio manager.
- Risk management, kill-switch enforcement, transaction cost modelling.
- Order book analysis + execution for scalping.

**Pulled from**: `Strategies/Prod/**`,
`utils/{risk_management,kill_switch,transaction_costs,scalping_execution,orderbook_analyzer}.py`.

**Talks to** (client, does not serve traffic to frontend):
`KTI-Broker-Service`, `KTI-Market-Data-Service`, `KTI-ML-Service`, `KTI-NLP-Service`,
`KTI-News-Sentiment-Service`.

**Exposes**: small control REST (`/status`, `/start`, `/stop`) consumed by
the orchestrator / `KTI-Gateway`.

---

### 3.8 `KTI-Backtest-Service`
**Purpose**: Run backtests without affecting live trading.

**Responsibilities**
- **Persistent job queue in Postgres.** `backtest_jobs` table (KTI-DB
  migration 006) holds the queue; workers claim rows with `SELECT ...
  FOR UPDATE SKIP LOCKED` (implemented in `app/dal/backtest_jobs.py`
  ported to psycopg 3 with `Jsonb` adapter). No Redis dep — we already
  have Postgres and scale (≤10 concurrent jobs ever) doesn't justify
  another moving part.
- **Cron-spawned ephemeral workers.** `* * * * * python -m app.worker
  --max-jobs=1 --max-runtime=290` per concurrency slot. Each tick spawns
  a fresh process, claims one job, runs it, exits. Solves the "no
  long-running daemons on shared cPanel" problem we hit in Phase 3b
  without the keep-alive watchdog tax. Worker loop
  (`app/worker._run_loop`) implements claim→run→persist→exit with
  cooperative cancel via `cancel_requested` flag checked between
  Lumibot iterations.
- **Backtest engine: Lumibot.** Picked over `backtesting.py` because the
  existing prod strategies (`MLTrader`, `CryptoTrader`, `ForexTrader`)
  are already Lumibot `Strategy` subclasses, and Lumibot's
  broker-abstraction lets the same class run live via Alpaca with no
  code change. Cold-start tax (~2–3s of imports per cron tick) is
  negligible against typical 30s–5min backtest runtimes. Engine
  abstraction (`app/engine/base.py` protocol +
  `app/engine/lumibot_engine.py` adapter) isolates Lumibot so a future
  swap to `backtesting.py` or `vectorbt` is a contained change. Yahoo
  data backend wired for now (zero-cred); Polygon/Alpaca backends
  deferred.
- **Strategy registry.** In-tree registry (`app/strategies/registry.py`)
  with lazy class resolution so chassis tests don't pay Lumibot's import
  cost. Phase 4b ships one reference strategy (`sma_crossover`); Phase 5
  wires real Strategy-Engine strategies (`MLTrader`, `CryptoTrader`,
  `ForexTrader`) in via registry entries pointing at
  `KiwiTon-Strategy-Engine` import paths.
- **Concurrency cap.** Hard ceiling of 2 simultaneously-running
  backtests across all workers (per `LIVE_BACKTESTING_SPEC.md` Decision
  5). Cron entries enforce this implicitly (run N parallel workers);
  API also rejects `POST /backtests` at the cap (via
  `jobs_dal.count_active()`) to surface a fast 429.
- **Soft cancel.** `cancel_requested` flag on the job row; worker checks
  via `jobs_dal.is_cancel_requested()` between Lumibot iterations and
  raises `CancelledError` at the next checkpoint. Route handler
  (`POST /backtests/{id}/cancel`) sets the flag; returns `409` on
  terminal jobs.
- **Results persistence.** On success, worker writes summary row to
  `backtest_results` (KTI-DB migration 002, `app/dal/backtest_results.py`)
  and full result blob (equity curve + trades + metrics) to
  `backtest_jobs.result` (jsonb). Foreign key links the two so the
  read-only `/backtests` history page picks up completed runs.

**Pulled from**: `Back_Testing/**`, `backtest_runner.py`,
`KiwiTon-Strategy-Engine/api/routes/backtest_routes.py` (ported to
FastAPI in `app/routes/backtests.py`),
`KiwiTon-Strategy-Engine/backend/db/backtest_jobs.py` (ported to
psycopg 3 in `app/dal/backtest_jobs.py`),
`KiwiTon-Strategy-Engine/LIVE_BACKTESTING_SPEC.md` (design doc with all
Decision 1–8 answers).

**Exposes**: REST (all behind `X-KTI-Token` except `/health` and `/ready`)
- `GET  /health` — liveness probe (public).
- `GET  /ready` — verifies `PROD_DATABASE_URI` set + Postgres `SELECT 1`
  succeeds. Does NOT probe Lumibot import (that's paid once per worker
  spawn, not per readiness check).
- `POST /backtests` — enqueue a job; returns `202 Accepted` + job row.
  Validates strategy exists, asset class supported, date range sane,
  concurrency cap not hit.
- `GET  /backtests` — list recent jobs (summary columns only; `result`
  jsonb omitted), optional `?status=queued|running|completed|error|cancelled`
  filter.
- `GET  /backtests/{id}` — full job row including `result` jsonb when
  terminal.
- `POST /backtests/{id}/cancel` — sets soft-cancel flag; idempotent;
  returns `409` on terminal jobs.
- `GET  /strategies` — catalogue of registered strategies + default
  params for frontend dropdown.

**Testing**: comprehensive unit + integration coverage. Registry tests
(no Lumibot import), route tests (DAL mocked), worker tests (engine +
DAL mocked), integration test scaffold (1-month SPY backtest, skipped by
default via `pytest -m integration`). All non-integration tests run in
CI without Lumibot installed.

---

### 3.9 `KTI-Orchestrator` *(optional)*
**Purpose**: Control plane for strategy-engine instances. Capital allocation,
heartbeats, auto-restart, kill-switch coordination.

**Pulled from**: `orchestrator/strategy_orchestrator.py`,
`app/api/orchestrator/**`, `utils/kill_switch.py`.

**Keep folded into** `KTI-Strategy-Engine` until horizontal scaling is
actually needed.

---

### 3.10 `KTI-Observability`
**Purpose**: Shared logging / metrics / alerting stack as
infrastructure-as-code.

**Contents**
- Prometheus + Grafana dashboards (including `kiwiton-trading.json`).
- ELK (Elasticsearch, Logstash, Kibana, Filebeat) compose + configs.
- Alertmanager rules, Slack / PagerDuty / webhook configs.
- Reusable logging/metrics libraries (`structured_logger.py`,
  `prometheus_metrics.py`, `alerting.py`) published as a package.

**Pulled from**: `docker/{prometheus,grafana,logstash,filebeat,alertmanager}/**`,
`docker/docker-compose.{elk,monitoring}.yml`, `utils/{structured_logger,
prometheus_metrics,alerting}.py`, `app/api/monitoring/**`.

---

### 3.11 `KTI-DB` *(central schema + DAL)*
**Purpose**: Single source of truth for the shared PostgreSQL schema and the
data-access layer imported by every persistent KTI service.

**Layout**

```
KTI-DB/
├── migrations/
│   ├── 001_initial_schema.sql
│   ├── ... (one versioned SQL file per change)
│   ├── 008_news_article_symbols.sql
│   ├── 009_price_alerts_trading_config.sql   — price_alerts, alert_history, trading_config, monitoring_events
│   └── 010_journal_and_portfolio_writes.sql  — journal columns on trades; unique constraints for portfolio upserts
├── python/                 — pip-installable as `kti_db`
│   ├── pyproject.toml
│   ├── connection.py        — psycopg_pool singleton + query/execute helpers
│   ├── migrate.py           — standalone migration runner
│   └── dal/                 — hand-written DAL modules
│       ├── news_sentiment.py
│       ├── trades.py         — + update_journal() (Phase B)
│       ├── portfolio.py      — + upsert_allocation(), upsert_position() (Phase B)
│       ├── performance.py    — equity curve, metrics, drawdowns, monthly returns (Phase A)
│       ├── alerts.py         — price alert CRUD + history (Phase A)
│       ├── costs.py          — transaction cost queries (Phase A)
│       └── ...
└── typescript/             — npm-installable as `@kiwiton-tech/kti-db`
    ├── connection.ts
    ├── migrate.ts
    ├── seed.ts
    └── dal/                 — mirrored DAL for TS services (gateway)
```

**Exposes**
- Python services: `pip install git+https://github.com/KiwiTon-Tech/KTI-DB.git@main#subdirectory=python`
  → `from kti_db.dal import news_sentiment`.
- TS services: `@kiwiton-tech/kti-db` (private npm, served from the repo).
- Ops: `python migrate.py` (or `npm run migrate`) run once per deploy
  against the shared cPanel Postgres.

**Schema change workflow**
1. PR against `KTI-DB` with a new `migrations/NNN_*.sql` and the matching
   DAL functions (both Python and TS where relevant).
2. CI runs migrations against a throwaway Postgres to verify idempotency.
3. On merge, run `python migrate.py` against production Postgres.
4. Dependent services `pip install --upgrade` the package (or cPanel
   pulls main) and are restarted. `kti_db` is importable; no ORM is
   required in consumer services.

**Why central?** A single Postgres instance on cPanel means schema changes
must be coordinated. Centralising both SQL and DAL prevents drift and
ensures every service agrees on table shape, indexes, constraints, and
query patterns.

---

## 4. Communication & Data Flow

### 4.1 Topology

```
                   ┌──────────────────────┐
                   │   Frontend (Next.js) │
                   └─────────┬────────────┘
                             │  HTTPS
                   ┌─────────▼────────────┐
                   │   KTI-Gateway        │  (auth, routing, aggregation)
                   └─┬──────┬──────┬──────┘
          ┌──────────┘      │      └──────────────┐
          │                 │                     │
    ┌─────▼────────┐ ┌──────▼──────────┐ ┌────────▼───────────┐
    │ Broker-Svc   │ │ Market-Data-Svc │ │ News-Sentiment-Svc │
    │ (Alpaca)     │ │ (REST + WS)     │ │ (scrape+store+API) │
    └─────▲────────┘ └──────▲──────────┘ └────────┬───────────┘
          │                 │                     │ POST /sentiment
          │                 │                     ▼
          │                 │              ┌──────────────┐
          │                 │              │ NLP-Service  │
          │                 │              │ (finBERT)    │
          │                 │              └──────▲───────┘
          │                 │                     │
          │   ┌─────────────┴─────────────────────┴────┐
          └───┤          KTI-Strategy-Engine           │
              │   (live bots: stock/crypto/forex/scalp) │
              └─┬───────────────┬───────────────────────┘
                │               │
         ┌──────▼──────┐ ┌──────▼──────────┐
         │ ML-Service  │ │ Backtest-Svc    │
         │ (predict)   │ │ (queue+workers) │
         └─────────────┘ └─────────────────┘

  Cross-cutting:  KTI-Observability  •  KTI-DB (Postgres)  •  Redis
```

### 4.2 Synchronous vs asynchronous

| Path | Transport | Why |
|------|-----------|-----|
| Frontend → gateway | HTTPS REST | Public, cache-friendly |
| Gateway → any service | Internal REST (`X-KTI-Token` header) | Simple, debuggable |
| Strategy-engine → broker-svc | REST, idempotency keys on orders | Must not double-submit |
| Strategy-engine ← market-data-svc | **WebSocket** | Sub-second latency |
| Strategy-engine ← ml-service / nlp-service | REST (batched) | Low QPS, high latency tolerance |
| News-sentiment-svc → nlp-service | REST (batched) | Bulk scoring after each scrape run |
| News-sentiment-svc loop | In-process background thread | Runs every `SCRAPE_INTERVAL_SECONDS` (default 10 min) |
| Gateway ← news-sentiment-svc | REST | Dashboard "Market Sentiment" panel |
| Backtest-svc jobs | Postgres `backtest_jobs` table (SKIP LOCKED claim) | Persistent queue; survives restarts. Cron-spawned ephemeral workers claim+process+exit. No Redis needed. |
| All services → observability | Prometheus scrape + Filebeat tail | Pull + push hybrid |

### 4.3 Shared data

- **Postgres** (single cPanel instance, DB name configured per environment) —
  trades (+ journal fields), equity snapshots, strategy configs, ML model runs, trade signals,
  monthly performance, `news_articles`, `news_article_symbols`, `news_daily_summaries`,
  `price_alerts`, `alert_history`, `trading_config`, `monitoring_events`,
  `portfolio_allocations` (upsertable), `portfolio_positions` (upsertable),
  `transaction_costs`, `round_trip_costs`. **Schema + DAL owned by `KTI-DB`**; every service
  imports `kti_db` (Python) or `@kiwiton-tech/kti-db` (TS) rather than
  writing its own ORM. Gateway, strategy-engine, ml-service,
  news-sentiment-service, and backtest-service write; gateway reads for
  dashboards.
- **Redis** — originally planned for market-data cache + backtest job
  queue + rate-limit counters. **Deferred indefinitely.** Phase 3b'
  proved an in-process TTL cache covers the market-data use case;
  Phase 4b uses Postgres `SELECT ... FOR UPDATE SKIP LOCKED` for the
  job queue. Will revisit only if (a) we move off shared cPanel, or
  (b) cross-service pub/sub becomes a real requirement.
- **S3 / GCS** — ML model artifacts, backtest reports. (Deferred.)

### 4.4 Example: a live trade

1. `market-data-service` streams a new bar for AAPL over WS.
2. `kiwiton-strategy-engine` (Stock_Trade_Strategy) receives the bar.
3. It calls `nlp-service` with the latest AAPL headlines → sentiment score.
4. It calls `ml-service` `/predict` with features + sentiment → signal +
   confidence.
5. If signal + risk checks + kill-switch all pass, it calls `broker-service`
   `/orders` with an idempotency key.
6. `broker-service` submits to Alpaca, returns the order ID.
7. Strategy-engine writes the trade to Postgres and emits structured logs +
   Prometheus metrics.
8. `kiwiton-observability` (Grafana) shows the trade on the dashboard; the
   gateway surfaces it to the frontend via `/api/trades`.

### 4.5 Example: news sentiment → frontend

1. Background thread inside `KTI-News-Sentiment-Service` ticks every
   `SCRAPE_INTERVAL_SECONDS` (default 600).
2. For each configured RSS feed in `RSS_FEEDS`, `feedparser` downloads the
   feed and yields `FeedItem(url, title, summary, published_at, source)`.
3. Across all items, the service extracts ticker mentions (cashtags +
   allowlist match against `SYMBOL_ALLOWLIST`) and tags the article's
   `category` from its feed configuration.
4. The service **batches** `title + summary` texts and sends one or more
   `POST /sentiment` calls to `KTI-NLP-Service` (`NLP_BATCH_SIZE` per call)
   → receives `[{label, score}]` from FinBERT.
5. Each article is upserted via `kti_db.dal.news_sentiment.upsert_article_with_symbols()`
   into Postgres (`news_articles` + `news_article_symbols`), with the
   FinBERT label/score stored in the same row.
6. Prometheus counters increment (later phase) for scrapes, errors, and
   NLP calls; Alertmanager pages on sustained failures.
7. Frontend dashboard calls `KTI-Gateway`:
   - `GET /api/news/articles?symbol=AAPL&since_hours=24&limit=20`
   - `GET /api/news/sentiment/aggregate?symbol=AAPL&hours=24`
8. Gateway proxies to `KTI-News-Sentiment-Service /articles` and
   `/sentiment/aggregate`, applies auth + response caching, returns JSON.
9. A **Market Sentiment** widget on the dashboard renders:
   - A `weighted_score` gauge in `[-1, 1]` per watched symbol.
   - Per-label counts (positive / neutral / negative).
   - The most-recent scored headlines (linking out to the source).

### 4.6 Example: strategy using sentiment

1. `Stock_Trade_Strategy` on an AAPL bar calls
   `KTI-News-Sentiment-Service /sentiment/aggregate?symbol=AAPL&hours=6`
   (replaces the legacy in-process FinBERT call).
2. Receives `{ weighted_score, article_count, buckets, latest_published_at }`.
   If `weighted_score > 0.3` AND `article_count >= 3`, combines with the
   `KTI-ML-Service` signal (dual-signal gate) and proceeds to order
   placement via `KTI-Broker-Service`.

Why the split is worth it: the heavyweight scrape + model call runs on its
own interval, while strategies read a single pre-aggregated number in
milliseconds — no article re-download, no model reload.

---

## 5. Cross-Cutting Concerns

### 5.1 Authentication
- **Public**: gateway verifies user JWT.
- **Service-to-service**: shared-secret header (`X-KTI-Token`), validated by
  every service when `SHARED_AUTH_TOKEN` is set. mTLS is deferred until we
  move off shared cPanel; the token is rotated by updating the env var on
  each service and the caller.

### 5.2 Secrets
- **Runtime secrets** (Alpaca keys, DB password, shared auth token) live in
  cPanel Python App environment variables (or `.env` mode 600 inside each
  app root). Never in GitHub.
- **CI secrets** (SSH key, cPanel host) live at the **repo level** on GitHub
  (free plan has no org-level secrets for private repos). See
  `KTI-.github/docs/CPANEL_DEPLOYMENT.md` Part A5.
- **GitHub access from cPanel** is mediated by the `KTI-Deploy-Bot`
  GitHub App whose private key lives at `~/secrets/kti-deploy-bot.pem`
  on the server with mode 600. A token-fetcher script mints 1-hour
  installation tokens on demand.
- Each secret lives in **exactly one** place. Broker credentials are never
  mounted into `KTI-Strategy-Engine`; it calls `KTI-Broker-Service` instead.

### 5.3 Versioning
- Internal APIs are unversioned for v0; a `/v1/` prefix will be added once
  we have a live consumer outside the first deploying team.
- Breaking changes currently require coordinated deploys; this is fine
  while the whole stack ships together.

### 5.4 Observability
- All services expose `/health` (liveness) and `/ready` (readiness). Already
  true for `KTI-NLP-Service` and `KTI-News-Sentiment-Service`.
- Structured JSON logs + Prometheus `/metrics` + Alertmanager are deferred
  to the `KTI-Observability` phase.

### 5.5 CI/CD per repo
Every `KTI-*` repo has its own GitHub Actions workflow that `uses:` the
reusable workflow in `KTI-.github`:

1. Lint + unit tests on every PR and push to `main`.
2. **No push-based deploy from CI.** Shared cPanel blocks inbound SSH, so
   the cPanel server pulls via the `KTI-Deploy-Bot` GitHub App on demand
   (`kti-deploy <KTI-Service-Name>`).
3. Deploy playbook: `KTI-.github/docs/CPANEL_DEPLOYMENT.md`.

---

## 6. Rollout Plan

The current repos keep working throughout — services are carved out one at
a time. ✅ = done, 🚧 = in progress, ⬜ = pending.

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Freeze feature work on `backend/`, `api/`, `kiwiton_graphql/`. Pick one as the survivor (recommend `api/`). Delete `ai_bot/` duplicates and empty `ai-bot/`. | ⬜ |
| 0a | **Stand up `KTI-.github`** — reusable CI workflows + cPanel deployment playbook. | ✅ |
| 0b | **Stand up `KTI-DB`** — SQL migrations + Python/TS DAL. Central schema repo all services depend on. | ✅ Deployed at `~/tools/KTI-DB` on cPanel; 8 migrations applied |
| 1 | **Extract `KTI-NLP-Service`** — FinBERT over FastAPI, zero shared state. | ✅ Live at `nlp.kiwiton-investments.com` |
| 1b | **Extract `KTI-News-Sentiment-Service`** — RSS scrape + NLP call + KTI-DB persistence. Drop tkinter/selenium/alpaca. | ✅ Live at `news.kiwiton-investments.com`; 88 articles scored in first run |
| 2 | **Extract `KTI-Broker-Service`** — biggest DRY win; kills the Python/TS Alpaca duplication. | ✅ Live at `broker.kiwiton-investments.com` (account, orders w/ idempotency, positions, clock, calendar, portfolio history, watchlists, assets, statements via direct REST bypass for `/v2/account/activities`) |
| 3a | **Extract `KTI-Market-Data-Service`** (REST) — frontend + strategies share one feed. | ✅ Live at `market.kiwiton-investments.com` (`/bars`, `/bars/latest`, `/quotes/latest`, `/trades/latest`, `/snapshots`, `/news`; stocks + crypto). **Route Expansion Sprint added:** `/screener/most-actives`, `/screener/movers`; crypto sub-routes (`/bars`, `/bars/latest`, `/quotes/latest`, `/snapshots`) proxied via Gateway `/market/crypto/*`. |
| 3b | **`KTI-Market-Data-Service` WebSocket fan-out** — separate cPanel daemon re-broadcasting `alpaca.data.live.{Stock,Crypto}DataStream` to internal subscribers (Redis pub/sub once available). Passenger doesn't speak WS, so this can't run inside the FastAPI app. | ⏸️ Deferred. Polling `/{bars,quotes,trades}/latest` is sufficient for current strategies; revisit when (a) a strategy's loop is faster than 2s, (b) consumers exceed ~5/symbol and Alpaca rate-limits bite even with caching, or (c) we move off shared cPanel and have somewhere stable to run a long-running daemon. Phase 3b' shipped instead: TTL cache in front of `/latest` endpoints + `kti-marketdata-client` polling SDK so callers don't reinvent backoff/batching. |
| 4a | **Extract `KTI-ML-Service`** — separates ML train/predict from the strategy engine. | ✅ Live at `ml.kiwiton-investments.com`. End-to-end pipeline confirmed: `/train SPY` (730d bars from market-data + 34 features + walk-forward XGBoost in 38s) → registry → `/predict SPY` returns signal+confidence+version_id. Phase 4b: adaptive thresholds, expected-value gating, scheduled retrain via cron, async `/train` for the full symbol list. |
| 4b | **Extract `KTI-Backtest-Service`** — queue + workers for historical simulations. | ✅ Live at `backtest.kiwiton-investments.com`. **Session 1 (2026-05-14):** chassis + health probes + worker scaffold + cPanel deploy. **Session 2 (2026-05-18):** (a) ported `backtest_jobs` + `backtest_results` DAL to psycopg 3 with `Jsonb` adapter + `SELECT ... FOR UPDATE SKIP LOCKED` claim, (b) ported Flask routes to FastAPI (`POST /backtests`, `GET /backtests`, `GET /backtests/{id}`, `POST /backtests/{id}/cancel`, `GET /strategies`) behind `X-KTI-Token`, (c) pinned Lumibot 3.8.16 + pandas/numpy/yfinance in requirements.txt, (d) built engine abstraction (`app/engine/base.py` protocol + `app/engine/lumibot_engine.py` adapter with Yahoo backend), (e) built in-tree strategy registry (`app/strategies/registry.py` with lazy class resolution + `app/strategies/sma_crossover.py` reference strategy), (f) replaced worker stub with real claim→run→persist→exit loop respecting `cancel_requested` + cooperative cancel via `CancelledError`, (g) comprehensive test suites (registry, routes with mocked DAL, worker with mocked engine, integration scaffold skipped by default), (h) improved `/ready` to probe Postgres connectivity. **Deferred to follow-up:** Polygon/Alpaca backends (Yahoo only for now), Forex support (`_pick_backend` rejects `strategy_type='forex'`), real DB integration test (needs CI Postgres service), frontend "Running Backtests" panel (gateway repo). Cron entries for concurrency cap pending ops task. |
| 5 | **Slim `KTI-Strategy-Engine`** down to strategies + orchestrator. Slim `Kiwiton-Investments-Backend` into `KTI-Gateway`. | ✅ **Phase 5b complete (2026-05-19).** Gateway fully wired: all nine services proxied. `KTI-Strategy-Engine` live at `engine.kiwiton-investments.com` (FastAPI + a2wsgi + Passenger). `StrategyEngineClient` + `/orchestrator/*` + `/strategies/*` proxy routes added to Gateway. Frontend `orchestratorApi` updated to use gateway paths. Ruff lint clean. `kti-deploy` alias installed on cPanel. End-to-end smoke test passing: `GET /orchestrator/status` → `{running:false, total_capital:100000, kill_switch_active:false}`. |
| 5c | **Gateway Route Expansion Sprint** — wire all active frontend pages to real Gateway endpoints; document Part 2 deferred routes. | ✅ **Complete (2026-05-19).** 50+ new routes added across broker, market-data, backtest, and DB-backed layers. 22 dead `/api/...` paths fixed in `api.js`. DB-backed `/trades/*` + `/portfolio/*` routes wired directly to `kti_db` DAL. Screener + crypto sub-routes added to Market Data Service and Gateway. See §3.1 Part 1/Part 2 for full inventory. |
| 5d | **Frontend ↔ Gateway Full Wiring (Phases A/B/C)** — implement all `/api/*` routes deferred in 5c; wire every `api.js` client object to a live endpoint. | ✅ **Complete (2026-05-26).** **Phase A** (5 broken pages fixed): `performanceApi`, `monitoringApi`, `alertsApi`, `statementsApi`, `tradingStatusApi`/`profilesApi` — new `/api/performance/*`, `/api/monitoring/*`, `/api/alerts/*`, `/api/statements`, `/api/trading/*` blueprints + matching DAL modules + DB migration 009. **Phase B** (write endpoints): `PATCH /trades/:id` for journal notes (migration 010), `POST /api/portfolio/allocations|positions`, `/api/costs/*`, `GET /api/backtests/by-symbol`. `tradeJournalApi` added to `api.js`; `journal/page.js` `handleSave` replaced. **Phase C** (market data extensions + new pages): `AlpacaDataClient` extended with 15 new methods; `routes/historical.py` + `routes/options.py` added to `KTI-Market-Data-Service`; crypto trades + orderbook added to trades router; Gateway blueprints `api/market.py` (logos/forex/fixed-income), `api/account.py` (config + SSE events stream), `api/positions.py` (exercise/do-not-exercise), `market_data/market_historical.py`, `market_data/market_options.py`. **New frontend pages**: `/options` (chain explorer with ITM/OTM indicators), `/forex` (live rates + converter using open.er-api.com), `/monitoring` (enhanced with 8-service microservices grid), `<ActivityFeed>` component (SSE live event stream for fills/dividends). **Database indexes**: `KTI-DB/docs/RECOMMENDED_INDEXES.md` created with 13 high/medium priority indexes for Phase A/B/C query optimization. Only remaining unimplemented stub: `POST /api/trading/execute`. Frontend commit `f02fb637e`, KTI-DB commit `83d739a`. |
| 6 | **Stand up `KTI-Observability`** — structured JSON logging + Prometheus `/metrics` on all services + Grafana Cloud dashboards + Alertmanager. | 🚧 In progress — `structlog` (`app/logging_config.py`) + `prometheus-fastapi-instrumentator` / `prometheus-flask-exporter` deployed to all 8 services (2026-05-19). Grafana Cloud stack created (`kti.grafana.net`). Prometheus scrape config + dashboard import (`kti-services-overview.json`) pending. **UptimeRobot monitors ✅ live**. |
| 7 | **Frontend UX Modernization** — component library, state management, real-time layer, AI/ML surfaces. See [Phase 7 Frontend Plan](#10-phase-7--frontend-ux-modernization) below. | ⬜ Planned — 8 sprints covering architectural foundations (shadcn/ui, TanStack Query, Zustand), day-trading features (command palette, trade ticket, watchlist), AI differentiation (trade ideas feed, ML reasoning panel, co-pilot chat), and polish (settings, onboarding, mobile). |
| 8 | **Critical Backend Infrastructure** — live order execution, real strategy backtesting, WebSocket streaming, ML artifact storage. See [Phase 7 Implementation Plan](./PHASE_7_IMPLEMENTATION_PLAN.md). | ⬜ Planned — 4 workstreams: (A) `POST /api/trading/execute` with 6-layer safety stack, (B) wire MLTrader/CryptoTrader/ForexTrader into backtest registry + Polygon backend, (C) Redis Pub/Sub + WebSocket price streaming, (D) Cloudflare R2 for ML models. |

Every phase ends with a working system; nothing is a big-bang migration.

---

## 7. Cleanup Done Along the Way

- Delete `KiwiTon-Strategy-Engine/ai_bot/` (duplicates `Modules/`,
  `Strategies/`, `Back_Testing/`).
- Delete `KiwiTon-Strategy-Engine/backend/{app_minimal.py,simple_api.py,app.py}`
  — keep one Flask entrypoint.
- Decide REST vs GraphQL: keep `api/` or `kiwiton_graphql/`, not both.
- Delete empty `Kiwiton-Investments-Backend/ai-bot/`.

---

## 8. Operational Lessons Learned

Captured from Phase 1 / 1b deploys so future services don't re-hit them.
Deep dive in [`docs/CPANEL_DEPLOYMENT.md`](./CPANEL_DEPLOYMENT.md).

### cPanel / Passenger

- **cPanel overwrites `passenger_wsgi.py`** when you create a Python App,
  replacing our file with a generic `imp.load_source('wsgi', 'passenger_wsgi.py')`
  template that recursively imports itself (infinite recursion on boot).
  **Always run `git checkout -- passenger_wsgi.py`** immediately after
  creating the Python App.
- **`a2wsgi.ASGIMiddleware` does NOT fire ASGI lifespan events.** Any
  FastAPI `lifespan` hook is silently skipped under Passenger. Workaround:
  call the startup logic explicitly from `passenger_wsgi.py`
  (`initialize()` or `load_model()`). Applied to `KTI-NLP-Service` and
  `KTI-News-Sentiment-Service`.
- **Passenger swallows stderr.** Don't waste time hunting log files \u2014
  run `python passenger_wsgi.py` directly from the app venv to get the
  real traceback.
- **`.env` must be loaded into `os.environ` explicitly** for dependencies
  that use `os.getenv()` directly (e.g. `kti_db.connection`).
  Pydantic-settings reads `.env` into its model but does NOT populate
  `os.environ`. Call `load_dotenv(APP_ROOT/".env")` at the top of
  `passenger_wsgi.py`.
- **System `python3` on CloudLinux is Python 3.6** \u2014 unusable for modern
  deps. Use `/opt/alt/python311/bin/python3.11` for any standalone tooling;
  services use the cPanel-managed app venv.
- **cPanel Postgres does not grant superuser.** `CREATE EXTENSION` fails.
  Use `gen_random_uuid()` (built into PG 13+) instead of `uuid-ossp`'s
  `uuid_generate_v4()`.

### alpaca-py SDK gaps

- **Account activities are Broker-API-only in alpaca-py 0.34.0.**
  `GetAccountActivitiesRequest` lives in `alpaca.broker.requests` and the
  `get_account_activities` method exists only on `BrokerClient`, not
  `TradingClient`. Importing it from `alpaca.trading.requests` raises
  `ImportError`. The underlying Trading REST endpoint
  `GET /v2/account/activities` works fine for personal accounts though,
  so `KTI-Broker-Service` calls it directly via `httpx` with the same
  `APCA-API-KEY-ID` / `APCA-API-SECRET-KEY` headers it already holds, and
  wraps each response row in `SimpleNamespace` so the existing serializer
  (which uses `getattr`) keeps working. Pattern to remember when porting
  more endpoints: when alpaca-py is missing a wrapper, drop down to the
  raw REST API rather than fight the SDK.
- **Plain-text 500s leak when an exception escapes FastAPI.** Without a
  generic `Exception` handler, an unhandled error (e.g., the
  `ImportError` above at first request) bubbles into `a2wsgi` and
  Passenger renders an HTML/plain-text 500. Combined with Passenger
  swallowing stderr, this is unusably opaque. Every KTI service should
  register an `@app.exception_handler(Exception)` that returns
  `{"detail": "{type(exc).__name__}: {exc}"}` as JSON 500. Already on
  `KTI-Broker-Service` and `KTI-Market-Data-Service`; copy into the
  next service. *Caveat:* Passenger still returns a bare HTML 502 if
  the worker errors before FastAPI can write the response body (e.g.
  Pydantic raising during request-construction in the route — see the
  `NewsRequest` symbols-as-string gotcha below). Diagnose those by
  invoking the SDK call directly via `python` in the venv, not just
  the curl response.
- **`pytz` is a hidden alpaca-py 0.34.0 transitive dep that pandas 3.x
  dropped.** alpaca-py imports `pytz` at module load. With pandas 1.x
  / 2.x it was pulled in transitively; pandas 3.0 dropped the hard dep
  on pytz, so `pip install alpaca-py==0.34.0` no longer brings it in
  automatically. Symptom: `/ready` returns
  `Alpaca data probe failed`, and direct endpoint calls return JSON
  500 `ModuleNotFoundError: No module named 'pytz'`. Fix: pin
  `pytz==2024.2` explicitly in every KTI service's `requirements.txt`
  that depends on alpaca-py (broker + market-data so far).
- **`NewsRequest.symbols` is a comma-separated string, not a list.**
  Unlike `StockBarsRequest` / `CryptoBarsRequest` (which take
  `symbol_or_symbols: list[str]`), `NewsRequest.symbols` is validated
  as `str` and expects `"AAPL,MSFT"`-style input. Passing a list
  raises `pydantic.ValidationError` inside the route, which (per the
  caveat above) escapes as a Passenger 502. The market-data service
  joins symbols with `","` inside `AlpacaDataClient.get_news()` so
  callers can still pass `?symbols=AAPL,MSFT` like every other
  endpoint.
- **`NewsSet.data["news"]`, not `NewsSet.news`.** alpaca-py's
  `NewsSet` exposes the article list at `result.data["news"]`, not via
  a `.news` attribute (which only exists on the underlying `News`
  models, confusingly). `dir(NewsSet)` shows `data` and
  `next_page_token` as the only payload-bearing attrs.
  `KTI-Market-Data-Service` reads via `getattr(result, "data", None)`
  with fall-throughs for the other shapes the SDK sometimes returns.

### Cloudflare

- **Grey-cloud every internal service** (`nlp`, `news`, future `broker`,
  `market`, `ml`). Proxied subdomains silently time-out long-running POSTs
  (e.g. FinBERT batches of 32), breaking service-to-service pipelines.
  Only public / browser-facing subdomains should be Proxied (orange):
  `api`, `www`, apex.
- **Proxied subdomains break AutoSSL** \u2014 the HTTP-01 challenge hits
  Cloudflare's edge and 404s. For proxied public domains, issue a
  Cloudflare **Origin Certificate** (15-year) and install it on cPanel
  with SSL/TLS mode set to **Full (strict)**.

### Pydantic-settings

- **`list[T]` and `dict[T]` fields are JSON-decoded before validators**
  unless annotated with `NoDecode`:
  ```python
  from typing import Annotated
  from pydantic_settings import NoDecode
  rss_feeds: Annotated[list[FeedSpec], NoDecode] = Field(default_factory=list)
  ```
  Without this, any env value that isn't valid JSON (e.g. our
  `"stocks|url,crypto|url"` CSV) raises `SettingsError` at boot.

### KTI-DB migrations

- **Run each migration in its own transaction.** A single transaction
  for all migrations rolls back successful earlier ones when a later one
  fails. `connection.run_migrations()` now commits per-file.
- Expose an **idempotent migration runner**: all migrations use
  `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ... IF NOT EXISTS` / etc.
  so re-running after a partial failure is safe.

### Cross-service env var conventions

- **`PROD_DATABASE_URI` is the canonical name** for the shared kti-db
  DSN across every KTI service on cPanel — *not* `DATABASE_URL` (despite
  `KTI-DB/.env.example` also documenting `DATABASE_URL` for legacy
  reasons). Originally adopted by `KTI-News-Sentiment-Service` and the
  legacy `KiwiTon-Strategy-Engine/backend/db/connection.py`. New
  services must mirror this key so a single sed/grep against any one
  service's `.env` produces the value to drop into every other.
  `KTI-Backtest-Service` had to rename `DATABASE_URL` →
  `PROD_DATABASE_URI` post-deploy when `/ready` reported `degraded`
  despite the value being copied correctly.
- **`SHARED_AUTH_TOKEN`** is per-service — each service generates and
  holds its own; callers configure their target's token under a name
  like `MARKET_DATA_TOKEN` or `NEWS_SENTIMENT_TOKEN`. Don't reuse one
  token across services even if it's tempting; a leak compromises the
  whole mesh.
- **Templates rot fast.** When a service renames an env key, every
  `.env` already deployed on cPanel still has the old key, and `sed`
  substitutions like `s|^PROD_DATABASE_URI=.*|...|` silently no-op on
  the missing key. Workflow: `cp .env.example .env` (overwriting)
  *before* re-injecting secrets, so the new template's keys are
  present for `sed` to target. Discovered during `KTI-Backtest-Service`
  session 1 deploy.

### GitHub / CI

- **GitHub Free disallows org-level secrets on private repos** \u2014 must set
  per-repo. See `docs/CPANEL_DEPLOYMENT.md` Part A5 for the `gh secret`
  bulk-seeding loop.
- **Never push credentials back in chat or commits.** Use URL-encoded
  connection strings in `.env` files (mode 600) and keep `.env` in
  `.gitignore`. `.env.example` is the shared template.
- **Git credential helper on cPanel** (configured globally in Part B5 of
  the playbook) makes `pip install git+https://github.com/KiwiTon-Tech/...`
  Just Work — no manual token plumbing per repo.
- **GitHub Actions runners do NOT inherit that.** A fresh runner has no
  credentials, so `pip install -r requirements.txt` fails with
  `fatal: could not read Username for 'https://github.com'` on any line
  pulling a private `KiwiTon-Tech` dep (e.g. `kti-db`). Symptom: every
  `lint-and-test` run fails at the "Install dependencies" step before
  the deploy job ever queues, so production stays on whatever was last
  hand-deployed even though `main` has long since moved on. Fix:
  1. Create a fine-grained PAT at the **org** level (KiwiTon-Tech) with
     **Contents: Read** on the private deps repos (`KTI-DB` today;
     extend as needed). Recommended name: `KiwiTon-Tech CI deps reader`.
  2. Store as the org-level Actions secret `GH_DEPS_TOKEN`.
  3. The shared workflow `KTI-.github/.github/workflows/python-cpanel.yml`
     accepts `GH_DEPS_TOKEN` (optional secret) and configures
     `git config --global url."https://x-access-token:${GH_DEPS_TOKEN}@github.com/".insteadOf "https://github.com/"`
     before `pip install`. Per-service workflows use `secrets: inherit`
     so no per-repo plumbing is needed.
  4. Verify: a CI run on a service that depends on `kti-db` should now
     reach the deploy step. Watch for `Restart Passenger` in the run log.
- **Bump `kti-db` version on every DAL change.** Services depend on
  `kti-db @ git+https://github.com/KiwiTon-Tech/KTI-DB.git@main#subdirectory=python`.
  pip skips already-satisfied requirements, so without a version bump in
  `KTI-DB/python/pyproject.toml` the cPanel boxes happily reinstall the
  same wheel and miss new DAL functions. Minor bump per added function;
  major bump per breaking change. Rule: if you add a function to
  `kti_db.dal`, bump the version in the same commit.

---

## 9. Open Questions

- **Service mesh / mTLS?** — Deferred. Shared cPanel means we can't run
  Envoy/Istio anyway. The `X-KTI-Token` shared-secret pattern is good
  enough until we move to a cluster.
- **Event bus?** — Most flows are request/response. The one async
  workload (`KTI-Backtest-Service`) is served by a Postgres job table
  with `SELECT ... FOR UPDATE SKIP LOCKED`, which is plenty for our
  scale. Revisit Kafka/NATS only if cross-service fan-out grows beyond
  point-to-point REST.
- **Monorepo vs polyrepo?** — Polyrepo (13 GitHub repos) is the committed
  approach: independent deploys, per-repo CI, clear ownership. Revisit with
  Nx/Turborepo only if coordination pain becomes real.
- **Schema isolation?** — Resolved: single Postgres instance, single schema
  (`public`), tables namespaced by prefix (`news_*`, `trade_*`). Schema and
  DAL centralised in `KTI-DB`.
- **When to leave shared cPanel?** — Decision point: first time we need
  always-on GPU, a real queue, or SSH ingress. Until then, cPanel + Passenger
  is cheaper and sufficient.
- **Second broker adapter (crypto.com, IBKR, etc.)?** — Deferred. Sketched
  in §3.2.1 with the canonical adapter contract, symbol normalisation
  rules, routing strategy, and required `KTI-DB` migrations. Trigger:
  any of (a) a strategy needs a coin Alpaca doesn't list, (b) scalping
  needs deeper books than Alpaca provides, (c) we want
  perps/leverage/shorts. Until then, all crypto flows through
  `KTI-Broker-Service` (Alpaca) — adding a second venue before
  portfolio-level risk controls and kill-switch are battle-tested
  doubles blast radius for no current upside.

---

## 10. Phase 7 — Frontend UX Modernization

**Status**: ✅ Section 10.2 Substrate complete (Sprint 1A–1D shipped 2026-05-28); 🟡 Sprint 2 page rollouts in progress — `/positions`, `/dashboard`, `/trades`, `/signals`, `/models`, `/symbol`, `/backtests`, `/trade` migrated. `/sentiment`, `/portfolio`, `/orchestrator`, `/risk`, `/alerts`, `/journal`, `/strategies`, `/monitoring`, `/performance`, `/statements`, `/execution`, `/options`, `/forex`, `/market-search` still pending.
**Repo**: `KiwiTon Investment Frontend`  
**Goal**: Transform the frontend from functional MVP into a production-grade day-trading platform with AI/ML differentiation.

**Phase 7 Frontend Workstreams (separate from §10.2 substrate):**
- ✅ **Workstream A — Live Order Execution UI** — `OrderConfirmDialog` (paper/live banner, ack checkbox, 3s countdown), `TradeTicket` form (idempotency-key generation, 403/422/409 inline error mapping), `/trade` route. **Backend route still stubbed** — UI ready when Gateway implements `POST /api/trading/execute`.
- ✅ **Workstream C — WebSocket Realtime** — `src/lib/realtime.js` native `WebSocket` client with exponential-backoff reconnect, `useRealtimePrice` hook, `ConnectionStatus` indicator (green/amber/red dot in navbar). Wire format matches Gateway flask-sock raw WS. **Backend Pub/Sub still pending** — frontend lights up when ready.
- ⏳ **Workstream B — Real Strategy Backtesting** — frontend was ready before this phase (`/backtests` already fetches dynamic strategies); blocked on backend registering `MLTrader`/`CryptoTrader`/`ForexTrader` in the Backtest Service registry.
- ⏳ **Workstream D — ML Artifact Storage (S3/R2)** — backend-only, no frontend work.

### 10.1 Problem Statement

Original state (Phase 6):
- ✅ All backend services live and wired
- ✅ Every `api.js` endpoint has a real Gateway route
- ✅ 24 pages, ~13K LOC, functional but not polished
- ❌ **UX debt**: every page hand-rolls buttons, cards, modals, tables, loading states
- ❌ **No component library**: `components/ui/` only has `PullToRefresh.js`
- ❌ **No state management**: `useApiData` hook rebuilds cache/refetch logic per page
- ❌ **Chart library bloat**: ships `recharts` + `apexcharts` + `chart.js` (~600KB overlap)
- ❌ **Polling-only**: 1.5s cadence unusable for day trading (scalping needs <100ms)
- ❌ **ML/AI underutilized**: heavy backend investment (ML Service, Sentiment, NLP) barely surfaced in UI

**As of 2026-05-28**:
- ✅ Substrate (§10.2) complete — primitives + TanStack Query + chart consolidation + WebSocket layer all shipped
- 🟡 Page rollouts (Sprint 2) in progress — 8 of 24 pages migrated to the new primitives
- ❌ AI/ML differentiation (§10.4) still pending — biggest remaining gap

### 10.2 Architectural Foundations (Sprint 1 — Required First)

These aren't "features" — they're the substrate that makes every subsequent feature 10× faster to ship.

#### 10.2.1 Component Library (`src/components/ui/*`) — ✅ SHIPPED (Sprint 1A + 1C)

**Stack**: shadcn-style hand-authored primitives on Radix + CVA + `clsx`/`tailwind-merge`. Tailwind v4 `@theme` block extended with shadcn HSL design tokens (light + dark) + `tailwindcss-animate` plugin loaded via `@plugin` directive. No CLI used — primitives are hand-written for full control over the v4 alpha integration.

**Core primitives shipped** (`src/components/ui/`):
- ✅ `Button` (CVA variants: `primary | secondary | ghost | danger | success | outline | link | gradient`, sizes `sm | md | lg | icon`, `asChild` via Slot)
- ✅ `Card` family (`Card`, `CardHeader`, `CardTitle`, `CardDescription`, `CardContent`, `CardFooter`)
- ✅ `Dialog` family (Radix-backed: `Dialog`, `DialogContent`, `DialogHeader`, `DialogTitle`, `DialogDescription`, `DialogFooter`, `DialogTrigger`, `DialogClose`) — focus trap, ESC handling, click-outside dismiss free
- ✅ `Tabs` (Radix-backed)
- ✅ `Input`, `Label` (Radix-backed)
- ✅ `Badge` (variants `default | secondary | outline | success | warning | danger`)
- ✅ `Skeleton`
- ✅ `Toaster` — confirmed already mounted in `providers.js` via `sonner`; legacy doc line was wrong

**Deferred** (build when first page actually needs them):
- ⏳ `Select` (Radix-backed, large primitive — defer to first surface that needs it)
- ⏳ `Combobox`, `Slider`, `Toggle`, `RadioGroup`, `Tooltip`, `Popover`, `DropdownMenu`, `ContextMenu`, `Sheet`, `Drawer`, `IconButton`, `ButtonGroup`, `EmptyState`, `ErrorState`, `LoadingState`
- ⏳ Virtualised `Table` (`@tanstack/react-table` + `react-virtuoso`) — current pages don't have list sizes that warrant virtualisation

**Trading-specific primitives shipped** (`src/components/ui/`):
- ✅ `Sparkline` — pure SVG line chart, auto-colored by trend, optional gradient fill
- ✅ `PriceCell` — flashes green/red for `flashMs` ms on price change; first render never flashes
- ✅ `PnLBadge` — auto sign/color, variants `inline | soft | solid`, sizes `sm | md | lg`, optional percent suffix
- ✅ `SignalChip` — buy/sell/hold pill with optional SVG confidence ring (uses `ConfidenceRing` sub-component)
- ✅ `ConfidenceBar` — promoted from `models/page.js`; color zones at ≥0.7 / ≥0.5 / <0.5
- ✅ `SymbolBadge` — symbol display with parqet logo (equities only) and letter-avatar fallback for crypto/forex/options
- ✅ `AssetClassPill` — color-coded pill (`stock` blue, `crypto` amber, `forex` violet, `option` cyan)
- ✅ `CandlestickChart` — TradingView Lightweight Charts wrapper, theme-aware, candles/line mode toggle, volume histogram overlay (covered in §10.2.3)

#### 10.2.2 State Management with TanStack Query — ✅ SHIPPED (Sprint 1B)

**Stack**: `@tanstack/react-query@latest` + `@tanstack/react-query-devtools` (dev-only mount).

**Provider**: `QueryClientProvider` wraps `Auth` + `Theme` providers in `src/app/providers.js`. Lazy `useState` initialiser keeps the client singleton across React 18 strict-mode double-renders. Defaults: `staleTime: 30s`, `gcTime: 5min`, `refetchOnWindowFocus: true`, `retry: 1` (mutations: `retry: 0`).

**Shared key factory**: `src/lib/query-keys.js` exports `brokerKeys`, `orchestratorKeys`, `monitoringKeys`, `tradingKeys`, `marketKeys`, `mlKeys`, `tradeKeys`, `backtestKeys`. Cross-page cache dedup is real: `/dashboard`, `/positions`, and TradeTicket all hit `brokerKeys.account()` and `brokerKeys.positions()` — opening one then another renders instantly from cache.

**Migrated to React Query**:
- ✅ `/backtests` (3 list/summary/by-symbol queries + strategies query + run mutation with cache invalidation)
- ✅ TradeTicket component (account + latest-bar queries + executeTrade mutation)
- ✅ `/positions` (positions query, 15s staleTime)
- ✅ `/dashboard` (5 parallel queries: account, positions, orchestrator status, system health 30s polling, strategies)
- ✅ `/trades` (list + summary queries with shared `tradeKeys`)
- ✅ `/signals` (ML predictions + recent trades — shares `tradeKeys.list()` cache with `/trades`)

**Still on legacy `useApiData`**:
- ⏳ `/alerts`, `/portfolio`, `/orchestrator`, `/risk`, `/sentiment`, `/strategies`, `/monitoring`, `/performance`, `/statements`, `/execution`, `/options`, `/forex`, `/journal`, `/symbol` (uses raw `useEffect` rather than `useApiData`)

**`useApiData` retired path**: Will be deleted entirely once the remaining 14 pages migrate. Currently kept for backwards compatibility.

#### 10.2.3 Chart Library Consolidation — ✅ SHIPPED (Sprint 1A + 1D)

**Removed** (Sprint 1A — were entirely unused in `src/`): `apexcharts`, `chart.js`, `react-chartjs-2`, `react-apexcharts`. ~600 kB gzip out of the bundle.

**Added** (Sprint 1D): `lightweight-charts@5.2.0` (~40 kB gzip).

**Current chart stack**:
- `recharts` — kept for analytics dashboards (`/performance`, `/statements`)
- `lightweight-charts` — TradingView candlesticks for intraday charts. Wrapped in `src/components/ui/candlestick-chart.js` with theme-aware (light/dark) palette swap on `theme` change, `autoSize: true`, candles/line mode toggle, volume histogram overlay, proper `IChartApi` cleanup on unmount
- Used on `/symbol` (replaced bespoke SVG line chart). `/symbol` First Load JS jumped 137 kB → 220 kB; route-scoped, paid only when user navigates there

**Future**: dynamic-import `CandlestickChart` if a second page needs it, so the 40 kB lives in a shared chunk.

#### 10.2.4 Real-Time WebSocket Layer — ✅ SHIPPED (Phase 7 Workstream C, 2026-05-28)

**Frontend scaffolding** (independent of backend Phase 8C timing):
- ✅ `src/lib/realtime.js` — `RealtimeClient` singleton using **native `WebSocket`** (not `socket.io-client` — backend Gateway uses `flask-sock` which serves raw WS frames). Exponential-backoff reconnect (1s → 30s capped), per-symbol listener registry, JSON `subscribe`/`unsubscribe` control frames, status broadcast (`connecting | connected | disconnected`)
- ✅ `src/hooks/useRealtimePrice(symbol)` — returns `{ price, lastUpdate }`, lazy-opens connection on first subscribe, callers fall back to a REST snapshot when `price` is `null`
- ✅ `src/components/layout/ConnectionStatus.js` — green/amber/red dot + label, mounted in Navbar (logged-in users only)
- ✅ Wire format: `{ symbol, price, size, timestamp, asset_class }` per tick (matches Market Data Service publishing format from Phase 7 Workstream C plan §4.3)

**Channels not yet wired**: `orders.fills`, `alerts.fired`, `orchestrator.status` — backend Pub/Sub channels need to exist first.

**Polling fallback**: not yet implemented; the hook returns `null` on disconnect and callers are expected to use REST snapshots. Adding automatic polling fallback is a future ~30-line addition.

**Status**: Frontend lights up automatically when backend Pub/Sub + flask-sock `/ws/prices` route is deployed (Phase 8C).

#### 10.2.5 Global State with Zustand

Lightweight (~1KB), no boilerplate. Slices:
- `useUserStore` — auth, theme, prefs
- `useWatchlistStore` — user-managed multi-watchlists with localStorage persistence
- `useLayoutStore` — saved dashboard layouts
- `useTradingStore` — selected symbol, order ticket state, paper/live mode

#### 10.2.6 Error Boundaries + Suspense

- `<ErrorBoundary>` per page-section (prevents one crashed widget from blanking whole page)
- Pair with `<Suspense fallback={<Skeleton />}>`
- Would have prevented the `e.price.toFixed` whitepage (2026-05-28)

---

### 10.3 Day-Trading Power Features (Sprints 2–4)

#### 10.3.1 Command Palette (`Cmd/Ctrl + K`) — Sprint 2

**Component**: `<CommandPalette>` indexing symbols, pages, strategies, alerts, recent trades, ML models.

**Quick actions**:
- "Buy 100 AAPL market"
- "Show AAPL chart"
- "Toggle kill switch"
- "Run backtest MLTrader on TSLA last 30d"

Pro traders live in this.

#### 10.3.2 Universal Trade Ticket (Slide-over Drawer) — Sprint 3

**Component**: `<TradeTicket symbol={...} side={...} />` accessible from any page (ticker card, position row, signal row, search result).

**Features**:
- Side toggle (Buy/Sell), order type (Market/Limit/Stop/Bracket)
- Quantity OR notional OR % of buying power
- Live preview: estimated fill, fees (from `transaction_costs` table), buying power impact
- **AI assist**: shows current ML signal + sentiment + regime → recommends position size based on confidence
- **Risk preflight**: warns on overconcentration, drawdown threshold, kill-switch state
- Paper-vs-Live indicator front-and-center (red banner if live)
- Hotkeys: `B` Buy, `S` Sell, `Esc` close

#### 10.3.3 Multi-Pane Watchlist Workspace — Sprint 3

**Rebuild**: `/market-search` as persistent customizable watchlist instead of hardcoded symbol lists.

**Features**:
- User-created watchlists (Tech, Crypto, Earnings This Week, Custom)
- Drag-to-reorder, multi-column sort, density toggle
- Inline sparkline (5-day, 1-day, intraday)
- Live `PriceCell` flash on tick
- One-click "Open ticket" / "Add alert" / "Open chart" per row
- Right-click `<ContextMenu>`
- Saved per-user via Zustand + localStorage; sync to backend later

#### 10.3.4 Pro Charting on `/symbol` — Sprint 4

**Replace** current chart with **TradingView `lightweight-charts`**:
- Candlestick + volume + ML overlay (entry/exit markers from `trade_signals`)
- Multi-timeframe quick-switch (1m/5m/15m/1h/1D)
- Drawing tools (trendlines, fibs, horizontal levels) — saved per-symbol per-user
- Indicator stack: SMA/EMA/RSI/MACD/Bollinger (matches `KTI-ML-Service` features)
- **Overlay sentiment ribbon**: green/red intensity bar for `news_daily_summaries.weighted_score`
- **ML signal markers**: arrow on each historical prediction with confidence; click to expand reasoning

#### 10.3.5 Heatmap Component — Sprint 4

**Reusable**: `<HeatMap>` using `recharts.Treemap` or custom SVG.

**Variants**:
- Portfolio heatmap (positions sized by weight, colored by today's P&L)
- Sector heatmap (S&P sectors → individual stocks; uses existing `sp500.js`)
- Strategy heatmap (which strategies winning/losing)
- Crypto heatmap (top 50 by market cap)

Surface on dashboard, portfolio, market-search.

#### 10.3.6 Live P&L Ribbon — Sprint 2

**Sticky bar** above page content (toggleable):
- Total equity, day P&L $/%, open positions P&L
- Pulses green/red on tick
- Click → `/positions`
- Hidden when offline / disabled in settings

#### 10.3.7 Notifications Center (Bell in Navbar) — Sprint 2

**Single source** for all events. Replaces per-page alert lists.

**Events**:
- Order fills, alert triggers, kill-switch fired, model retrain complete, backtest done, daily P&L summary
- Filtering, mark-as-read, click → relevant page
- Push via WS channel + degrades to polling

---

### 10.4 AI/ML Differentiation (Sprints 5–6 — Where You Win)

Heavy backend investment (ML Service, Sentiment, NLP). Frontend barely surfaces it. **This is the biggest competitive gap.**

#### 10.4.1 "AI Trade Ideas" Feed — Sprint 5 ⭐ **Killer Feature**

**New page**: `/ideas` or dashboard widget.

**Content**: Daily ranked list of trade candidates:
- Symbol, signal, confidence, expected value, time horizon
- **"Why" card**: 3-bullet plain-English reasoning derived from feature importance + sentiment + regime + ML model output
  - Example: *"AAPL Buy — 78% confidence. Drivers: RSI oversold (35), positive sentiment (+0.42, 18 articles), trending regime, MLTrader v3 historical accuracy on similar setups: 64%."*
- One-click "Open ticket" with size pre-filled by Kelly fraction × confidence
- Track CTR + post-trade outcome → feed back to retraining (closes the loop)

#### 10.4.2 ML Reasoning Panel — Sprint 5

**Reusable**: `<ReasoningPanel signalId={...}>`

**Content**:
- Top features ranked (already partially in `/models`)
- **SHAP-style waterfall**: how each feature pushed prediction toward buy/sell
- Sentiment tape: latest 5 articles with score
- Regime context
- Similar historical setups with outcomes (kNN over feature space — backend addition needed)

**Show in**:
- `/signals` row expansion
- `/trades` row drill-down
- `/positions` "Why am I in this?" link

#### 10.4.3 AI Co-Pilot Chat (Sidebar Drawer) — Sprint 6 ⭐ **Wow Factor**

**Right-edge slide-out** with chat:
- "Show me oversold tech with positive sentiment"
- "Analyze my AAPL position"
- "What's the best strategy backtested on TSLA last quarter?"
- "Why did MLTrader buy NVDA today?"

**Implementation**: Thin LLM router (OpenAI/Anthropic function-calling) translating natural language → API calls already exposed (`/api/ml/predictions`, `/sentiment/aggregate`, `/backtest/jobs`, etc.) and rendering results inline.

**Not a replacement for UI** — augments it.

**Scope**: v1 (read-only queries) → v2 (ticket pre-fill) → v3 (auto-execute with confirmation).

#### 10.4.4 Strategy Comparison Lab — Sprint 5

**Revamp**: `/backtests/page.js` (currently 1,817 lines — maintenance ship-stopper).

**Break into**:
- `<BacktestForm>` — symbol, date range, strategy multi-select
- `<BacktestResultCard>` — collapsible per-run
- `<ComparisonChart>` — overlay equity curves of N strategies
- `<MetricsGrid>` — Sharpe, drawdown, win-rate side-by-side
- `<TradeListTable>` — virtualized, filterable

**Add**: head-to-head (pick 2 strategies → see diff in trades + outcomes).

#### 10.4.5 Confidence Calibration Widget — Sprint 5

**Pro ML feature**. Plot predicted confidence vs realized win-rate:
- Perfect diagonal = well-calibrated
- Below diagonal = overconfident (warning)
- Above diagonal = underconfident

**Place on**: `/models` per-model. Reusable `<CalibrationChart>`.

#### 10.4.6 Sentiment Pulse Widget — Sprint 5

**Real-time sentiment** for watched symbols + market overall. 3 modes:
- **Per-symbol gauge**: weighted score with article count and trend arrow
- **Market mood meter**: aggregate across S&P (already have data in `news_daily_summaries`)
- **Sentiment-vs-price divergence detector** — alerts when sentiment turns positive while price still falling (and vice versa)

---

### 10.5 Operations & Risk (Sprint 7 — Polish Existing)

#### 10.5.1 Risk Dashboard Widget

**Reusable**: `<RiskGauges>` summarizing:
- Current drawdown vs max drawdown limit (radial gauge)
- Position concentration (largest position % of portfolio)
- Leverage / margin usage
- Daily loss limit progress bar
- Kill-switch status (already partially surfaced)

Surface on dashboard top-right. Click → `/risk`.

#### 10.5.2 Kill-Switch UX Upgrade

**Current**: `KillSwitchBanner.js` shows state.

**Add**:
- Confirmation dialog with countdown ("Hold 3s to engage")
- Reason input (logged to `monitoring_events`)
- Auto-trigger conditions config (loss threshold, max trades/day, etc.)

#### 10.5.3 Strategy Health Cards

**On `/strategies`** — for each strategy, show:
- Status (running/stopped/error)
- Last 7-day P&L, Sharpe, win-rate
- Trade count, avg holding time
- Toggle on/off (with confirm)
- "Backtest this" button → preloads backtest form

#### 10.5.4 Order Book Depth Widget (for Scalping)

**For symbols** where Alpaca crypto provides L2 (`/market/crypto/orderbook`):
- Visual ladder, bid/ask totals, spread
- Click level to set limit price in trade ticket

---

### 10.6 Mobile / Responsive (Sprint 8)

Already have `BottomNav.js` and `PullToRefresh`. Build on it:

#### 10.6.1 Mobile-first Trade Ticket
Bottom-sheet variant of `<TradeTicket>` with biometric confirm.

#### 10.6.2 Quick Actions Floating Button
Mobile FAB → ticket / search / kill-switch / alerts.

#### 10.6.3 Compact Dashboard
`density: comfortable | compact | dense` toggle persisted per user.

#### 10.6.4 Haptic Feedback
On order submit, alert fire, etc. (`navigator.vibrate`).

---

### 10.7 Onboarding & Discoverability (Sprint 8)

#### 10.7.1 First-Run Tour
Library: `react-joyride` or `driver.js`. Interactive walkthrough of dashboard, paper-mode banner, kill switch, strategies.

#### 10.7.2 Empty States with Calls-to-Action
Every list page (`/trades`, `/alerts`, `/portfolio` etc.) gets `<EmptyState>` with primary action.

#### 10.7.3 Live API Status Page
Move `/api-test` → user-facing `/status` showing 8 services' health from `/api/monitoring/health`. Lightweight transparency.

#### 10.7.4 Settings Page
New `/settings` consolidating:
- Theme, density, default chart timeframe
- Default order params (TIF, size mode)
- Notification prefs (which events → bell, which → email)
- Paper/live toggle
- Watchlist management
- Saved dashboard layouts
- Hotkey customization

---

### 10.8 Performance & Polish (Sprint 8)

#### 10.8.1 Code-split Heavy Charts
Already using `dynamic()` in some places — extend to all chart pages.

#### 10.8.2 Streaming SSR for Next.js App Router
`/dashboard` should stream welcome banner immediately and stream stats as ready.

#### 10.8.3 Optimistic UI Everywhere
Journal edits, alert toggles, watchlist add/remove — feel instant.

#### 10.8.4 Animations
`framer-motion` for page transitions, list reorder, modal enter/exit. Consistent, not gratuitous.

#### 10.8.5 Accessibility
- Add `<SkipLink>` to layout
- Audit all modals for focus-trap + Esc
- Color-contrast pass on red/green badges
- Table `<caption>` and `aria-sort` on sortable columns
- `prefers-reduced-motion` respect

---

### 10.9 Sprint Breakdown

| Sprint | Focus | Deliverables | Status |
|---|---|---|---|
| **1A** | Substrate — UI primitives | shadcn primitives (Button, Card, Dialog, Input, Label, Badge, Skeleton, Tabs), Tailwind v4 token wiring, drop unused chart deps | ✅ Shipped |
| **1B** | Substrate — TanStack Query | QueryClientProvider, shared `query-keys.js`, migrate `/backtests` + TradeTicket | ✅ Shipped |
| **1C** | Substrate — Trading primitives | Sparkline, PriceCell, PnLBadge, SignalChip, ConfidenceBar, SymbolBadge, AssetClassPill; migrate `/models` | ✅ Shipped |
| **1D** | Substrate — TradingView charts | `lightweight-charts` install, `CandlestickChart` wrapper, `/symbol` migration | ✅ Shipped |
| **2** | Page rollouts (the high-leverage move) | Migrate remaining 16 pages to primitives + TanStack Query | 🟡 In progress (8/24 done: `/positions`, `/dashboard`, `/trades`, `/signals`, `/models`, `/symbol`, `/backtests`, `/trade`) |
| **3** | Core Workflow | Universal Trade Ticket on more surfaces, Watchlist workspace | TradeTicket component ✅; mount on more pages ⏳ |
| **4** | Real-time + Notifications | Wire `useRealtimePrice` into rows, Live P&L ribbon, Notifications center, Command Palette | Frontend client ✅, awaiting backend Pub/Sub |
| **5** | AI Differentiation | AI Trade Ideas feed, ML Reasoning Panel, Confidence Calibration, Strategy Comparison Lab, Sentiment Pulse | ⏳ |
| **6** | AI Wow Factor | AI Co-Pilot Chat (read-only v1) | ⏳ |
| **7** | Pro-Trader Confidence | Risk dashboard, Strategy health, Kill-switch UX | ⏳ |
| **8** | Retention | Settings, Onboarding, Mobile polish, Performance, Accessibility | ⏳ |

---

### 10.10 Quick Wins (< 1 Day Each)

Ship value immediately while sprints run:

- ✅ **Toaster wiring** — verified already mounted in `providers.js` via `sonner` (legacy doc claim was wrong); `TradeTicket` and others use `toast.success`/`toast.error` correctly
- ✅ **Skeleton states** — `Skeleton` primitive shipped Sprint 1A; consumed by `/positions`, `/dashboard`, `/trades`, `/signals`. Other pages still on `animate-pulse` divs.
- ✅ **Number flash** on ticker price updates — `PriceCell` primitive shipped Sprint 1C, used on `/positions` and `/symbol`. Animation triggers on prop changes; will activate fully when `useRealtimePrice` is wired into rows
- ✅ **Connection indicator** in navbar — green/amber/red `ConnectionStatus` shipped Phase 7 Workstream C
- ⏳ **Currency-aware formatters** in `lib/format.js` — partial: each migrated page now uses `PnLBadge` for P&L formatting, but local `formatCurrency`/`fmt` helpers remain. Centralizing into `lib/format.js` is a future cleanup
- ⏳ **Paper/Live banner** — `OrderConfirmDialog` has it; need a global banner component for top-of-page on trading surfaces when `account.is_paper === true`
- ⏳ **Error boundary** on dashboard — not yet shipped
- ⏳ **Markdown reasoning** in signals — current `/signals` shows structured `DetailCard` items; markdown rendering deferred

---

### 10.11 Success Criteria

- 🟡 **Sprint 1**: All pages use `<Button>`, `<Card>`, `<Table>` from component library; zero hand-rolled modals
  - ✅ Component library + 7 trading primitives shipped
  - ✅ TanStack Query + shared key factories shipped
  - ✅ Chart consolidation done
  - ✅ WebSocket layer + `ConnectionStatus` indicator live
  - 🟡 8/24 pages migrated; 16 still hand-roll modals/buttons
- 🟡 **Sprint 2**: WebSocket connection indicator live (✅); P&L ribbon updates <100ms on tick (⏳ — depends on backend Pub/Sub)
- ⏳ **Sprint 3**: Trade ticket accessible from 10+ surfaces (✅ component shipped, mounted on `/trade` only — future surfaces TBD); watchlist supports drag-to-reorder
- 🟡 **Sprint 4**: `/symbol` chart renders candlesticks (✅ via lightweight-charts, no ML markers yet); heatmap on dashboard (⏳)
- ⏳ **Sprint 5**: AI Trade Ideas feed shows 10+ ranked candidates with "Why" cards; confidence calibration chart on `/models`
- ⏳ **Sprint 6**: AI Co-Pilot answers "Show me oversold tech with positive sentiment" in <2s
- ⏳ **Sprint 7**: Risk dashboard shows all 5 gauges; kill-switch requires 3s hold + reason
- ⏳ **Sprint 8**: Settings page consolidates 8+ preference categories; first-run tour completes

---

### 10.12 Dependencies on Phase 8 (Backend)

Frontend Phase 7 can proceed **independently** of backend Phase 8, with graceful degradation:

| Frontend Feature | Backend Dependency | Fallback | Status |
|---|---|---|---|
| WebSocket layer | Phase 8C (Redis Pub/Sub + flask-sock `/ws/prices`) | Polling (current) | Frontend ✅ shipped, awaiting backend |
| Live order execution | Phase 8A (`POST /api/trading/execute`) | Paper-mode only | Frontend ✅ shipped (`/trade`), awaiting backend route |
| Trade Ticket AI assist | Phase 8B (real strategies in backtest) | Static recommendations | Frontend uses snapshot REST today |
| AI Trade Ideas feed | `/api/ml/predictions` (already live) | None — works today | ⏳ frontend page not yet built |
| ML Reasoning Panel | `/api/ml/feature-importance` (already live) | None — works today | ⏳ frontend not yet built |
| Real-strategy Backtests | Phase 8B (MLTrader/CryptoTrader/ForexTrader registered in registry) | SMA Crossover only | Frontend ✅ already dynamic |

**Status**: Sprint 1 substrate (§10.2) complete. Sprint 2 page rollouts in progress (8/24 pages migrated). Sprints 3–8 can run in parallel with Phase 8 backend work.

---
