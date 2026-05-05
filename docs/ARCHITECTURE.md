# KiwiTon Investments — Microservices Architecture

> **Status**: In progress (Phase 1b complete)
> **Last updated**: 2026-05-05
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
| 1 | [`KTI-Gateway`](https://github.com/KiwiTon-Tech/KTI-Gateway) | TS (Next.js) | BFF / API gateway | Pending |
| 2 | [`KTI-Broker-Service`](https://github.com/KiwiTon-Tech/KTI-Broker-Service) | Python (FastAPI) | Alpaca adapter | Pending |
| 3 | [`KTI-Market-Data-Service`](https://github.com/KiwiTon-Tech/KTI-Market-Data-Service) | Python (FastAPI + WS) | Streaming | Pending |
| 4 | [`KTI-NLP-Service`](https://github.com/KiwiTon-Tech/KTI-NLP-Service) | Python (FastAPI) | ML inference (FinBERT) | ✅ Live at `nlp.kiwiton-investments.com` |
| 5 | [`KTI-News-Sentiment-Service`](https://github.com/KiwiTon-Tech/KTI-News-Sentiment-Service) | Python (FastAPI) | News ingest + sentiment API | ✅ Live at `news.kiwiton-investments.com` |
| 6 | [`KTI-ML-Service`](https://github.com/KiwiTon-Tech/KTI-ML-Service) | Python (FastAPI) | ML train + predict | Pending |
| 7 | [`KTI-Strategy-Engine`](https://github.com/KiwiTon-Tech/KTI-Strategy-Engine) | Python | Long-running worker | Pending |
| 8 | [`KTI-Backtest-Service`](https://github.com/KiwiTon-Tech/KTI-Backtest-Service) | Python | Job queue + workers | Pending |
| 9 | [`KTI-Orchestrator`](https://github.com/KiwiTon-Tech/KTI-Orchestrator)* | Python | Control plane | Optional |
| 10 | [`KTI-Observability`](https://github.com/KiwiTon-Tech/KTI-Observability) | YAML / shell | Infra config | Pending |
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
**Purpose**: The single public entrypoint. Thin Next.js BFF that the frontend
(`KiwiTon Investment Frontend`) talks to.

**Responsibilities**
- Authentication, session/JWT issuance, CSRF, rate limiting.
- Request routing + response shaping for the UI.
- Aggregation of downstream service responses (e.g. dashboard = broker +
  market-data + ml-service).
- No business logic. No direct Alpaca calls. No database writes except for
  auth/session tables.

**Pulled from**: `Kiwiton-Investments-Backend/app/api/auth/**`,
`middleware.ts`, `src/middleware/**`, and thin proxy handlers for everything
under `app/api/*`.

**Exposes**: HTTPS REST (`/api/...`) to the frontend.

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

---

### 3.3 `KTI-Market-Data-Service`
**Purpose**: One place that fetches market data and fans it out. Normalises
across asset classes (stocks, crypto, forex, options).

**Responsibilities**
- REST: bars, quotes, trades, snapshots, news, options chains, screener,
  logos, corporate actions.
- WebSocket: live price/quote/trade streams for stocks + crypto + news.
- Provider adapters (Alpaca today, OANDA/TwelveData for forex tomorrow).
- Caching layer (Redis) for frequently-hit endpoints.

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
- Queue (Redis / RabbitMQ) of backtest jobs.
- Worker pool that runs historical simulations.
- Persists results to Postgres; serves them via REST.

**Pulled from**: `Back_Testing/**`, `backtest_runner.py`,
`api/routes/backtest_routes.py`, `app/api/backtests/**`,
`src/trading/backtesting/**`, `LIVE_BACKTESTING_SPEC.md`.

**Exposes**: REST (`/jobs`, `/jobs/{id}`, `/results/{id}`).

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
│   └── 008_news_article_symbols.sql
├── python/                 — pip-installable as `kti_db`
│   ├── pyproject.toml
│   ├── connection.py        — psycopg_pool singleton + query/execute helpers
│   ├── migrate.py           — standalone migration runner
│   └── dal/                 — hand-written DAL modules
│       ├── news_sentiment.py
│       ├── trades.py
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
| Backtest-svc jobs | Redis/RabbitMQ queue | Bursty, async by nature |
| All services → observability | Prometheus scrape + Filebeat tail | Pull + push hybrid |

### 4.3 Shared data

- **Postgres** (single cPanel instance, DB name configured per environment) —
  trades, equity snapshots, strategy configs, ML model runs, trade signals,
  monthly performance, `news_articles`, `news_article_symbols`,
  `news_daily_summaries`. **Schema + DAL owned by `KTI-DB`**; every service
  imports `kti_db` (Python) or `@kiwiton-tech/kti-db` (TS) rather than
  writing its own ORM. Gateway, strategy-engine, ml-service,
  news-sentiment-service, and backtest-service write; gateway reads for
  dashboards.
- **Redis** — market-data cache, backtest job queue, rate-limit counters.
  (Deferred; introduced when the first service actually needs it.)
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
| 2 | **Extract `KTI-Broker-Service`** — biggest DRY win; kills the Python/TS Alpaca duplication. | ⬜ |
| 3 | **Extract `KTI-Market-Data-Service`** — frontend + strategies share one feed. | ⬜ |
| 4 | **Extract `KTI-ML-Service`** and **`KTI-Backtest-Service`** — separates batch from online workloads. | ⬜ |
| 5 | **Slim `KTI-Strategy-Engine`** down to strategies + orchestrator. Slim `Kiwiton-Investments-Backend` into `KTI-Gateway`. | ⬜ |
| 6 | **Stand up `KTI-Observability`** — structured logging + Prometheus + Grafana. | ⬜ |

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

### GitHub / CI

- **GitHub Free disallows org-level secrets on private repos** \u2014 must set
  per-repo. See `docs/CPANEL_DEPLOYMENT.md` Part A5 for the `gh secret`
  bulk-seeding loop.
- **Never push credentials back in chat or commits.** Use URL-encoded
  connection strings in `.env` files (mode 600) and keep `.env` in
  `.gitignore`. `.env.example` is the shared template.
- **Git credential helper on cPanel** (configured globally in Part B5 of
  the playbook) makes `pip install git+https://github.com/KiwiTon-Tech/...`
  Just Work \u2014 no manual token plumbing per repo.

---

## 9. Open Questions

- **Service mesh / mTLS?** — Deferred. Shared cPanel means we can't run
  Envoy/Istio anyway. The `X-KTI-Token` shared-secret pattern is good
  enough until we move to a cluster.
- **Event bus?** — Most flows are request/response. Only `KTI-Backtest-Service`
  genuinely needs a queue. Revisit Kafka/NATS only if fan-out grows.
- **Monorepo vs polyrepo?** — Polyrepo (13 GitHub repos) is the committed
  approach: independent deploys, per-repo CI, clear ownership. Revisit with
  Nx/Turborepo only if coordination pain becomes real.
- **Schema isolation?** — Resolved: single Postgres instance, single schema
  (`public`), tables namespaced by prefix (`news_*`, `trade_*`). Schema and
  DAL centralised in `KTI-DB`.
- **When to leave shared cPanel?** — Decision point: first time we need
  always-on GPU, a real queue, or SSH ingress. Until then, cPanel + Passenger
  is cheaper and sufficient.
