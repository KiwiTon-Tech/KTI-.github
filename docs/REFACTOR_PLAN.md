# Real-Strategy Backtesting Refactor — Cross-Repo Plan

**Status:** in progress. Created on a feature branch in the backend repo; Python
side not started. Context handoff document for the next Windsurf session.

**Branch name (both repos):** `feat/real-strategy-backtesting`

---

## Why this refactor exists

The TS backtester (`Kiwiton-Investments-Backend/src/trading/backtesting/backtestRunner.ts`)
implements 5 hardcoded **toy/textbook strategies** — `sma_crossover`,
`rsi_mean_reversion`, `macd`, `momentum`, `bollinger_bands`. They have nothing
to do with the real production strategies, which live in Python at
`KiwiTon-Strategy-Engine/Strategies/Prod/`:

- `MLTrader` (stock) — ML + FinBERT sentiment
- `CryptoTrader` — ML + sentiment for crypto
- `ScalpingStrategy` — currently crypto/stock, needs forex extension
- `UIStrategy`, plus portfolio manager / multi-symbol helpers

Backtesting today therefore produces meaningless results. Goal: make the backend
delegate backtesting to the Python engine, so results reflect the strategies
that actually trade.

---

## Target architecture

```
Frontend (backtest screen)
   │
   ▼
Next.js backend  (Kiwiton-Investments-Backend)
   - POST /api/backtests/run       (thin proxy)
   - POST /api/backtests/run-all   (batch proxy)
   - GET  /api/backtests/strategies (dynamic list passthrough)
   - Persists results in Postgres via backtestsDAL
   │  (HTTP)
   ▼
Python engine  (KiwiTon-Strategy-Engine, Flask on :5000)
   - GET  /api/v1/backtest/strategies
   - POST /api/v1/backtest/run
   - Wraps BacktestRunner in backtest_runner.py
   - Uses Lumibot + Polygon for historical data
   │
   ▼
Alpaca (live trading only)  |  Polygon (historical data, ~15 yrs)
```

- **Polygon** = historical data for backtesting (~15 yrs of stock history).
- **Alpaca** = live trading execution. Not used for backtesting anymore.

---

## User requirements (confirmed)

1. Dynamic date range: backtests default to **last 10 years → today**.
2. "Run all strategies" for a given symbol in one call.
3. Strategy list must come from `Strategies/Prod/` only — no toy strategies.
4. **Keep Monte Carlo** simulation on backtest results.
5. **Add forex backtesting** — extend `Scalping.py` (or add a new strategy) to
   support forex scalping.
6. Frontend asset-class selector: `stocks`, `crypto`, `forex`.

---

## Work breakdown

### Phase 1 — Python engine (KiwiTon-Strategy-Engine)

1. **Extend `BacktestRunner`** in `backtest_runner.py`:
   - Accept explicit `start_date` / `end_date` in `__init__` (currently only `days`).
   - Add `return_trades=True` option so `_extract_lumibot_metrics` returns the
     full trade list (needed for Monte Carlo).
   - Add `run_forex_strategy(symbol, **kwargs)` method mirroring the stock/crypto
     ones but using `PolygonDataBacktesting` with `type='forex'`.

2. **New forex strategy** `Strategies/Prod/Forex_Trade_Strategy.py` OR adapt
   `Scalping.py`:
   - Inherit Lumibot `Strategy` base so it can run in `PolygonDataBacktesting`.
   - Reuse scalping logic from `Scalping.py` (MarketAnalyzer, RiskManagement).
   - Symbols like `EURUSD`, `GBPUSD`, etc.
   - Register in `Strategies/Prod/__init__.py`.

3. **New Flask blueprint** `api/routes/backtest_routes.py`:
   - `GET /api/v1/backtest/strategies`
     - Returns: `[{ id, display_name, asset_classes: [...], uses_ml, uses_sentiment }]`
     - Sourced dynamically from `Strategies/Prod/__init__.py` (not hardcoded).
   - `POST /api/v1/backtest/run`
     - Body: `{strategy, symbol, strategy_type, start_date, end_date, initial_capital, params}`
     - Dispatches to `run_stock_strategy` / `run_crypto_strategy` / `run_forex_strategy`.
     - Returns standardized metrics dict + trade list.

4. **Register blueprint** in `api/app.py` (url_prefix `/api/v1/backtest`).

5. **Env vars required:** `POLYGON_API_KEY`, `ALPACA_CREDS` (existing).

### Phase 2 — TS backend (Kiwiton-Investments-Backend)

1. **Gut** `src/trading/backtesting/backtestRunner.ts`:
   - Delete: `STRATEGY_LABELS`, `generateSignals`, all per-strategy cases,
     `calculateSMA/RSI/MACD/Bollinger`, `simulate`, `runWalkForward`.
   - **Keep**: `BacktestRequest`, `BacktestResult` types; `runMonteCarlo`
     (will operate on Python-supplied trade list).
   - **Add**: `strategyEngineClient.ts` — axios/fetch wrapper for Python API
     with `STRATEGY_ENGINE_URL` env var (default `http://localhost:5000`).

2. **Rewrite `runBacktest`** as a thin proxy:
   - POSTs to `${STRATEGY_ENGINE_URL}/api/v1/backtest/run`.
   - Takes the trade list from the response.
   - Runs `runMonteCarlo` locally on those trades (preserves MC feature).
   - Returns same `BacktestResult` shape the frontend expects.

3. **Add `listStrategies()`** — proxies `GET /api/v1/backtest/strategies`.
   Cached in-process (5 min TTL).

4. **Update** `app/api/backtests/run/route.ts` and `.../run-all/route.ts`:
   - Drop static `VALID_STRATEGIES = Object.keys(STRATEGY_LABELS)`.
   - Validate strategy name against dynamic list from `listStrategies()`.

5. **New route** `app/api/backtests/strategies/route.ts`:
   - `GET` — thin passthrough returning the Python strategy list.

6. **Env:** add `STRATEGY_ENGINE_URL=http://localhost:5000` to `.env.example`.

### Phase 3 — Frontend (separate repo, not in workspace)

Update the backtest screen to:
- Fetch strategies from `GET /api/backtests/strategies` instead of hardcoding.
- Populate the asset-class dropdown from the selected strategy's `asset_classes`.
- Tolerate optional fields in the result (no walk-forward, MC is optional).

Not blocking Phases 1 & 2.

---

## Already committed on `feat/real-strategy-backtesting` (backend repo)

Commit `e64d6a295` — `feat(backtest): dynamic date range + run-all endpoint`:

- Modified `app/api/backtests/run/route.ts` — `startDate`/`endDate` optional;
  `yearsBack` param (default 10) → today.
- New `src/trading/backtesting/dateRange.ts` — `resolveDateRange()` helper.
- New `app/api/backtests/run-all/route.ts` — runs every strategy for a symbol
  in parallel, returns ranking + per-strategy success/error outcomes.

These are a stepping stone; the strategy list they validate against is still
the toy list and will be replaced in Phase 2.

---

## Known issues the next session needs to handle first

### 1. Broken rebase in backend repo

User ran `git rebase origin/dev` which failed on add/add conflicts
(`.DS_Store`, `README.md`, `package.json`) because `main` and `dev` have
divergent histories.

**Resolution:**
```bash
cd "/Users/zanderbolyanatz/Documents/KiwiTon Investments/Kiwiton-Investments-Backend"
git rebase --abort
git status    # should show clean, on feat/real-strategy-backtesting
git log --oneline -5
git log --oneline origin/dev -5
git merge-base main origin/dev   # likely prints nothing = unrelated histories
```

If histories are unrelated, cherry-pick the feature commit onto dev instead
of rebasing:
```bash
git checkout origin/dev -b dev
git cherry-pick e64d6a295
git checkout -b feat/real-strategy-backtesting   # recreate from dev
```

### 2. `.DS_Store` tracked in repo

Macos junk keeps causing merge conflicts. After recovery:
```bash
echo ".DS_Store" >> .gitignore
git rm --cached .DS_Store 2>/dev/null
git add .gitignore && git commit -m "chore: ignore .DS_Store"
```

### 3. Strategy-Engine branch state unknown

Run `git status` + `git branch` there and create
`feat/real-strategy-backtesting` off `dev` (or `main` if no `dev` exists).

---

## Reopening the workspace correctly

Close current Windsurf window. Open folder:
`/Users/zanderbolyanatz/Documents/KiwiTon Investments`

This makes both `Kiwiton-Investments-Backend/` and `KiwiTon-Strategy-Engine/`
visible as siblings. Semantic search and grep will work across both repos.

Start the next chat with: *"Continue the real-strategy-backtesting refactor
per REFACTOR_PLAN.md in the workspace root. Begin Phase 1 (Python engine)."*

---

## Consequences user accepted

- Forex backtesting is being ADDED (previously fake in TS, now real in Python).
- Monte Carlo is being KEPT (runs in TS on Python-supplied trade list).
- Walk-forward analysis is being REMOVED (was tied to toy strategies).
- Data source for backtesting = Polygon. Alpaca stays for live trading only.
- Python service must be running alongside Next.js in dev and prod.
