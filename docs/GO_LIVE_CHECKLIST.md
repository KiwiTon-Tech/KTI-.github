# Go-Live Checklist — Start Investing This Week

**Status**: Active
**Created**: 2026-09-20
**Owner**: Zander Bolyanatz

Everything required to place the first real trades this week, plus the crypto
win-rate improvement workstream derived from Craig Percoco's published strategy
framework ([@craig_percoco on YouTube](https://www.youtube.com/@craig_percoco/videos)).

---

## 0. Verified Repo State (2026-09-20 audit)

**Done and live:** Sprints 1–6 — `POST /api/trading/execute` 6-layer safety
stack, real-strategy backtesting (`kti_strategies` wired into Backtest
Service), WebSocket price streaming (CF Worker + PriceHub DO), R2 model
storage + cold-start restore, deployment automation (5-min auto-deploy cron),
order execution frontend (`TradeTicket` + `OrderConfirmDialog`).

**In progress / stale:** Sprint 7 retrain was started 2026-07-08 and the plan
was last updated that day — results were never recorded. Sprint 8 (Grafana
alerting) is not done. Sprint 10 (live trading staged rollout) is this week.

**Critical gap found in audit:**
`KTI-Strategy-Engine` has **no live strategy runners**. Nothing in that repo
imports `kti_strategies` or Lumibot — the orchestrator registers placeholder
entries with `instance=None` and logs *"register it first"* on start. Manual
orders via the UI work today; **automated strategies cannot trade live until a
live runner is built** (Track B below).

---

## Track A — Go-Live Readiness (blocking, do first)

### A1. Verify Sprint 7 ML retrain results
- [ ] Pull `model_manifest.json` + per-symbol metrics from R2 (`kti-ml-models`
      bucket) or the server `models/` dir and record accuracy per symbol.
- [ ] Acceptance from Sprint 7: accuracy ≥ 48.7% (OHLCV-only ceiling) on the
      majority of the 26 symbols; ≥ 55% on SPY/AAPL. If not met, keep
      ML-gated strategies in paper mode and trade technical/sentiment-only.
- [ ] Confirm the nightly/weekly retrain cron has run unattended 7+ days
      (check `kti-status` + retrain logs on cPanel).

### A2. Paper-mode end-to-end smoke test (half a day)
- [ ] Confirm all 8 services healthy: `kti-status` on cPanel.
- [ ] Place a paper order through the real UI: `TradeTicket` →
      `OrderConfirmDialog` → `POST /api/trading/execute`.
- [ ] Verify: order fills at Alpaca paper; audit row appears in
      `monitoring_events`; duplicate retry with same `Idempotency-Key`
      returns 200 (no double fill); SSE `/api/account/events` streams the fill.

### A3. Production safety configuration
- [ ] Set on the server `.env` (Gateway): `LIVE_TRADING_ENABLED=false` for
      paper phase; flip to `true` only for the staged live rollout.
      Conservative starting limits: `MAX_DAILY_LOSS=500`, `MAX_POSITION_PCT=10`.
- [ ] Kill-switch drill: activate via orchestrator endpoint → confirm
      `/api/trading/execute` returns 403 `kill_switch` → confirm strategy
      halt → deactivate.
- [ ] Confirm `SHARED_AUTH_TOKEN` is set on every service (blank token
      disables inter-service auth).

### A4. Minimum alerting before real money (Sprint 8, reduced scope)
- [ ] Grafana Cloud: import the ready dashboard from `KTI-Observability`.
- [ ] Alert: any 403 from `/api/trading/execute` (Slack/email).
- [ ] Alert: any service `/health` failing > 2 min; orchestrator heartbeat
      stale > 5 min.

### A5. Staged live rollout (Sprint 10, per `KTI-Gateway/docs/ROLLOUT_PLAN_SPRINT_3.md`)
- [ ] Stage 1 (days 1–2): paper account, `LIVE_TRADING_ENABLED=true`, full
      safety stack — real code path, fake money.
- [ ] Stage 2: live Alpaca account, admin user only, $100 max order size.
- [ ] Stage 3: general enable after 1 incident-free week.

---

## Track A′ — Infra issues found during the 2026-09-20 server C5 attempt

- [ ] **`deploy.sh` treats pip failures as success** — `pip install -r
      requirements.txt` failed to clone kti-strategies (dead GitHub token)
      and the deploy still reported "✅ Deployment successful", leaving the
      OLD strategy code installed. Make deploy abort loudly when pip fails.
- [ ] **`refresh-github-token.sh` cron is stale/broken** — HTTPS GitHub ops
      on cPanel fail auth ("Invalid username or token"). Verify the */55
      cron actually runs and updates insteadOf entries; consider switching
      requirements pins to `git+ssh://` (deploys already use SSH).
- [ ] Auto-deploy pulls caused silent dep drift before — add a post-deploy
      assert (e.g. `pip show kti-strategies` commit hash vs GitHub main).

---

## Track B — Automated Live Strategies (the bots)

> Manual UI orders work today (Track A). This track makes `CryptoTrader` /
> `MLTrader` run unattended.

- [ ] **B1.** Build live runner in `KTI-Strategy-Engine`: instantiate
      `kti_strategies` Lumibot strategies with the Alpaca broker config and
      call `orchestrator.register_strategy()` on boot, so persisted state
      (Sprint 9 JSON snapshots) auto-starts previously-running strategies.
- [ ] **B2.** Register `CryptoTrader` on BTC/USD only, paper broker, small
      capital_pct; verify heartbeat, restart-on-crash, and kill-switch halt.
- [ ] **B3.** Add heartbeat metric + Grafana alert for crashed strategies.
- [ ] **B4.** Expand to remaining crypto symbols after 1 clean week.

---

## Track C — Crypto Win-Rate Improvements (Craig Percoco framework)

Audit finding: `CryptoTrader` currently risks **25% of cash per trade**, has
**no stop-loss or take-profit** (exits only on an opposite signal or 10%
portfolio drawdown sell-all), and its technical fallback buys a falling knife
(naked `RSI < 30`). This is the opposite of Percoco's framework, which is:
enter only in high-probability confluence zones, fixed 1R risk, structure-based
stops, partial profits + break-even, trail winners, ~40–55% win rate with
4–8R winners, and measure everything.

### C1. Risk model (highest impact) — ✅ IMPLEMENTED 2026-09-20
- [x] Replace `cash_at_risk=0.25` with **fixed-fractional 1R sizing**:
      risk 0.5–1% of equity per trade; `qty = risk$ / (entry − stop)`
      (`risk_pct=0.01` default; legacy `cash_at_risk` still accepted as a
      notional-cap override so old registry configs don't crash).
- [x] **Structure-based stops**: stop at the swing low of the last
      `stop_lookback=10` bars (`_swing_stop`), managed in the strategy loop
      every iteration since Alpaca crypto has no bracket/OCO orders.
- [x] **Trade management**: partial take-profit at 2R (`take_profit_pct=0.5`)
      → stop to break-even → trail under rising swing lows
      (`trail_lookback=5`), never ratcheting down or above price.
- [x] **R-multiple journaling**: every close appends `{qty, exit_price,
      r_multiple, reason}` to `trade_log` with confluence snapshot at entry.
      19 new unit tests in `tests/test_crypto_risk_model.py` (39/39 pass).
- [ ] Persist `trade_log` R-multiples to the `trades` table journal columns
      when the live runner lands (Track B).

### C2. Entry quality (win-rate knob) — 🚧 PARTIAL 2026-09-20
- [x] **Trend filter**: long entries only when close > `trend_sma` (200D
      default, 0 disables). Unknown trend (insufficient history) blocks
      entries but never exits.
- [x] **Replace the RSI fallback**: oversold (`RSI < 30`) now requires a
      bullish confirmation bar (close above the prior 3 bars' highs) before
      buying. Overbought exits unchanged.
- [ ] **BTC trend gate for alts**: block altcoin longs when BTC is below
      its 200D SMA (Percoco: trade alts in the direction of BTC).
- [ ] **Confluence scoring gate**: entries are journaled with a confluence
      snapshot (signal source, trend, RSI, sentiment) but not yet gated on
      an N-of-M score. Tune selectivity vs trade-count in backtests.

### C3. Portfolio construction (Percoco 75/25 model)
- [ ] Encode 75% core / 25% high-risk split via orchestrator `capital_pct`:
      core = BTC (and ETH) with the conservative config; high-risk =
      SOL/AVAX/LINK/DOT/LTC with smaller 1R risk.

### C4. Measurement ("you cannot improve what you do not measure")
- [ ] Journal every trade: write entry reason, confluence snapshot, and
      R-multiple to the `trades` table journal columns (migration 010).
- [ ] Weekly report: win rate, avg win R, avg loss R, expectancy, per-symbol
      and per-confluence breakdown. Review before widening capital.

### C5. Validation gate (before enabling any of C1–C4 live)

**Local run 2026-09-20 — FAILED on sample size, PASSED on risk containment.**
`KTI-Backtest-Service/scripts/c5_crypto_validation.py`, window
2024-09-21→2026-09-19 (2y, Polygon daily aggregates — plan caps history there;
first ~200 sessions are SMA-200 warmup), 10 bps fees, `use_ml=False`
(technical-fallback path only), $100k:

| Symbol | Trades | Win | Expectancy (net) | Max DD | Verdict |
|---|---|---|---|---|---|
| BTC | 1 | 0% | −$1,320 (−1.29R) | 1.9% | FAIL |
| ETH | 2 | 0% | −$1,132 (−1.12R) | 3.4% | FAIL |
| SOL | 1 | 0% | −$1,108 (−1.09R) | 2.1% | FAIL |
| AVAX | 0 | — | — | — | FAIL |
| LINK | 3 | 33% | −$568 (−0.52R) | 4.4% | FAIL |
| DOT | 0 | — | — | — | FAIL |
| LTC | 1 | 100% | +$853 (+0.87R) | 0.2% | FAIL (<5 trades) |

Read-out:
- **Risk model works as designed**: no loss worse than ~1.3R (daily-bar
  gap-through-stop explains >1R), max DD ≤ 4.4% everywhere — the C1 fix
  demonstrably contains damage.
- **Fallback is too selective on daily bars** (0–3 entries/symbol in
  ~17 months active). The gate correctly fails on statistical significance.
  Percoco's setups are intraday; on dailies they barely fire.
- **The production entry signal is ML (`use_ml=True`), not this fallback.**
  C5 for the real config needs point-in-time `/predict` calls (token lives
  on the server) and full-history data (Alpaca crypto bars — our Polygon
  plan only serves trailing ~2y). Run C5 server-side via the live Backtest
  Service instead of locally.
- [ ] Server-side C5 with `use_ml=True` + Alpaca full-history crypto data.
      Harness ready (2026-09-20): on the cPanel box —
      ```bash
      cd /home/kiwiton/apps/KTI-Backtest-Service
      set -a; source .env; set +a   # ML_SERVICE_URL/TOKEN + ALPACA keys
      PY=$(ls -d /home/kiwiton/virtualenv/apps/KTI-Backtest-Service/*/bin/python | head -1)
      nohup "$PY" scripts/c5_crypto_validation.py \
          --source alpaca --ml --start 2023-09-21 --end 2026-09-19 \
          > logs/c5_ml_run.log 2>&1 &
      ```
      (venv lives under `/home/kiwiton/virtualenv/apps/…`, not `.venv` —
      first attempt exited 127 on this.)
      (~30–90 min/symbol, one point-in-time /predict per bar; results land
      in `scripts/c5_crypto_validation_results.json`.)
- [ ] Consider a 4h/1h crypto timeframe later so the fallback's structure
      setups have enough occurrences to matter (post-go-live).
- [ ] 1 week paper-mode forward run, then compare live-fill slippage vs
      backtest assumptions.

**Infra findings from the C5 local run (fix before scaling backtests):**
1. `YahooDataBacktesting` re-downloads from yfinance on EVERY iteration —
   instant 429 rate-limit, then silently empty bars. Do not use it;
   pre-fetch + `PandasDataBacktesting` (or Polygon/Alpaca backend — the
   deferred Phase 7 Workstream C item).
2. Lumibot's executor filters `initialize()` kwargs via
   `inspect.getfullargspec(...).args` — any wrapper around a strategy
   class must preserve the signature or **all parameters are silently
   dropped** (this produced flat no-trade runs locally).
3. Lumibot 3.8.16 writes trades to `logs/<name>_<salt>_trades.csv`, not
   the `trades_file` path — the engine normaliser's `logs/*_trades.csv`
   glob can pair a result with a STALE file from another run when several
   runs share a process. Safe today (one worker per process); fragile if
   that changes.

---

## Definition of Done — "Investing this week"

1. Track A complete: real (or paper) orders flow end-to-end with the full
   safety stack and alerting.
2. Sprint 7 accuracy on record; strategy mode chosen per A1.
3. First trades placed under the staged rollout with $100 cap.
4. C1 risk model implemented + backtested before any automated crypto capital
   is enabled — never run a live strategy without a stop-loss.
