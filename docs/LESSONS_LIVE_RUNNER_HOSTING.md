# Lessons: Hosting a Resident Trading Loop on Shared cPanel (2026-09-21)

**Context:** First live(ish) run of `crypto_sol` on Alpaca paper. Took
most of a day to get one hourly iteration to survive. The failures were
never strategy bugs — they were four systems, each correct *by its own
rules*, disagreeing about process lifecycles. Documented here because the
"global fix" (proper live-trading hosting + orders via KTI-Broker-Service)
must respect all four lessons at once, or it will rediscover them.

---

## The four mismatches

### 1. Passenger recycles web processes on idle
**Symptom:** `logs/app.log` showed a fresh boot every ~5–35 minutes
("Strategy restored from persistence… Auto-starting crypto_sol…" on
repeat).

**Cause:** shared cPanel Passenger is engineered for request/response web
apps; its default `PassengerPoolIdleTime=300s` reaps idle app processes.
`.htaccess` pinning (`PassengerMinInstances 1`, `PassengerPoolIdleTime 0`)
had no effect on this host's stack (LiteSpeed-flavored Python Selector).

**Fix:** trading loop moved OUT of the web process into a supervised
daemon: `scripts/run_live_daemon.py` + `scripts/live_watchdog.sh`
(cron `*/2`, pidfile-guarded). Any future hosting decision (VPS,
Fly machine, Cloudflare Container) must treat the web tier as disposable
and put resident loops elsewhere.

### 2. Lumibot's Trader registers UNIX signal handlers
**Symptom:** first start crashed instantly:
`ValueError: signal only works in main thread of the main interpreter`.

**Cause:** `Trader.run_all()` calls `signal.signal(SIGINT, ...)`. Any
executor that runs strategies in daemon threads (our orchestrator) trips
this.

**Fix:** `_install_threadsafe_signal_guard()` in `app/live_runner.py`
makes `signal.signal` a no-op outside the main thread; graceful stop is
via `is_running = False` instead. Note for the global fix: if a custom
executor replaces lumibot live, keep a cooperatively-stoppable loop —
signals are unavailable anywhere but the main thread, by Python rule.

### 3. The state store deliberately dropped `last_heartbeat`
**Symptom:** a healthy bot reported `heartbeat: None` on the dashboard;
every restart made it look dead.

**Cause:** Sprint 9's `OrchestratorStateStore` intentionally persisted
control state but not runtime liveness ("runtime-only" was the intent).
Reasonable for same-process liveness; wrong with a separate daemon
process owning the loop.

**Fix:** record_heartbeat() persists; the store now carries
`last_heartbeat`. Rule of thumb for the global fix: **liveness is state
too** — anything an operator uses to decide "is the bot alive?" must be
readable from shared storage, not from process memory.

### 4. Two processes, two worldviews
**Symptom:** daemon runs, web `/orchestrator/status` shows
`registered` / heartbeat null for a running strategy.

**Cause:** each process holds its own StrategyOrchestrator instance in
memory. The web one loaded placeholders at boot and never re-read.

**Fix:** web get_status overlays the shared store on every call when
`live_runner_mode=daemon` (orchestrator gets
`overlay_store_on_status=True` from settings). Control-plane writes stay
in the daemon; the web is read-mostly.

---

## Smaller landmines logged the same day (Track A′ context)

- **pip + git@main pins are version-static**: `pip install -r` considers
  `kti-strategies 0.1.0` satisfied forever; main moving does nothing.
  Deploys now `--force-reinstall` it explicitly and assert the installed
  dist-info commit == `origin/main`. Any future git-pin need has to come
  with an equivalent guard, or better: tag/pin immutable versions.
- **`pip | tee` without `pipefail` hid install errors for days**; now
  `set -o pipefail` in every deploy.sh.
- **lumibot `initialize()` kwargs are filtered via
  `inspect.getfullargspec(...).args`** — any wrapper without the original
  signature silently drops parameters. Use `functools.wraps` +
  explicit `__signature__`.
- **lumibot reads `MARKET` at import** from the process env; under
  Passenger the cwd/env source varies, so `register_from_config` sets
  `MARKET=24/7` itself.
- **Passenger swallowing stdout** meant zero app log visibility for days;
  `logging_config` now also writes `<app>/logs/app.log` (rotating, 5MB).
- **DST fall-back hour**: `2023-11-05 01:00` exists twice in NY time; any
  tz_localize on hourly bars dies. Always deliver tz-aware indices.

### 5. Single-use runtimes + restart loops (found next morning)

**Symptom:** `RuntimeError: threads can only be started once` after an
automatic restart; kill switch armed.

**Cause:** two coupled design slips: (a) on boot, the restored stale
heartbeat looked instantly timed-out to the monitor, triggering a restart
of a strategy that had just started; (b) the restart re-ran the SAME
lumibot Trader, whose executor threads are single-use.

**Fix:** every start stamps a fresh heartbeat window; consumed runtimes
are rebuilt through an `instance_factory` (registration carries a factory
from day one), never re-run. Rule for option B/C: treat runtime instances
as disposable; factories are the unit of restart.

### 6. Web control endpoints can't reach daemon-owned instances (2026-09-27)

**Symptom:** `POST /orchestrator/start` returned
`RuntimeError: Strategy 'crypto_sol' has no instance — register it first`
even though the daemon was running it fine.

**Cause:** with `LIVE_RUNNER_MODE=daemon` there are *two* orchestrators:
the Passenger web process (placeholders, read-only) and the daemon (owns
the lumibot instances). The web `/start`, `/stop`, `/kill-switch`
endpoints were still calling `start_strategy()` on their placeholders.

**Fix:** desired-state reconciliation. Web endpoints now write
`tmp/live_control.json` (`{"crypto_sol": {"desired": "running"}, ...}`);
the daemon calls `reconcile_controls()` every ~5s and applies it —
kubernetes-style desired vs. actual. Kill switch travels the same channel
(`__kill_switch__` key). Two follow-on finds fixed in the same commit:
`get_strategy_entry()` didn't exist (the `/strategies/{name}` route had
always 500'd), and `last_error` survived restarts, showing a stale
traceback next to `state: running` — now cleared on (re)start.

**Rule:** any control-plane verb added later must go through the control
file, never direct calls — the web process can NEVER hold a live
instance. Also: Passenger pool recycling means a `restart.txt` touch can
leave a stale worker serving old code for a while; when API behavior
doesn't match freshly deployed code, check `ps` for a stale pool first.

### 7. Venv .so corruption (2026-09-27, cause unknown)

**Symptom:** daemon exited at boot; `import numpy` → "C-extensions
failed"; then scipy `_sparsetools`, PIL `_imaging`, etc.

**Cause:** unresolved, but the full census showed it was broader than the
first count: **5 of 7 venvs** had missing binaries, including bundled
shared libs (`psycopg_binary.libs/libcrypto-*.so.3` /
`libssl-*.so.3` in every venv carrying psycopg — Gateway and News weren't
clean either). Disk at 8%; `.py` files all intact — binaries were
stripped *after* install. Working theory: host-level scanner quarantining
executables under `~/virtualenv`. If it recurs, escalate to the provider
and ask specifically about `.so` quarantining in user home dirs.

**Fix/monitoring:** force-reinstall restored it
(`pip install --force-reinstall --no-cache-dir <pkgs>`). The watchdog now
runs a `.so`-vs-RECORD integrity check every tick and logs
`VENV INTEGRITY: N .so file(s) missing`. **If the count goes nonzero
again within ~24h of a reinstall, it's a host process — escalate to the
hosting provider** (ask specifically whether security tooling strips
`.so` from `~/virtualenv`).

**Detection recipe** (reusable on any venv):
```python
import importlib.metadata
from pathlib import Path
missing = sum(
    1 for d in importlib.metadata.distributions()
    for f in (d.files or [])
    if str(f).endswith(".so") and not Path(d.locate_file(f)).exists()
)
```

## For whoever builds the real order path (option B/C)

1. Don't host the loop in Passenger (see 1).
2. Keep stops/computations in the strategy loop; order submission via
   Broker-Service REST (idempotency keys already exist there).
3. Persist liveness and control state separately but both durably (3).
4. Single writer for runtime state; readers overlay from storage (4).

## 5. Leave `ALPACA_*` unset in the engine env (2026-09-27)

Lumibot's `credentials.py` auto-instantiates an Alpaca broker + trade
stream at import time whenever `ALPACA_API_KEY` is present, even when the
strategy's actual broker backend is `broker_service`. That unused
`TRADING_STREAM_PAPER` client held ~80 of the daemon's ~120 threads and
starved the cPanel user shell at the nproc limit (`fork: resource
temporarily unavailable`).

After renaming `ALPACA_*` -> `DISABLED_ALPACA_*` in the engine `.env` and
restarting, the daemon dropped to a stable 41 threads and the
`connected to: BaseURL.TRADING_STREAM_PAPER` log line disappeared.
Order/account/position traffic continues through Broker-Service, which
owns the real Alpaca credentials. Rule: broker credentials live in
Broker-Service's env only; never export them to the engine.
