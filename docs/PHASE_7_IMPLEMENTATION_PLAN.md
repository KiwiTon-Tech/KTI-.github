# Phase 7 — Critical Backend & Trading Infrastructure

**Status**: Planning  
**Created**: 2026-05-28  
**Owner**: Zander Bolyanatz

This phase completes the deferred critical infrastructure from Phases 3b, 4b, and REFACTOR_PLAN.md. These are production-blocking for real trading and accurate backtesting.

---

## 1. Overview

Four parallel workstreams:

| # | Workstream | Repo(s) | Complexity | Risk | Priority |
|---|---|---|---|---|---|
| **A** | Live Order Execution | KTI-Gateway, KTI-Broker-Service | High | **Critical** | P0 |
| **B** | Real Strategy Backtesting | KTI-Backtest-Service, KTI-Strategy-Engine | Medium | Medium | P0 |
| **C** | WebSocket Price Streaming | KTI-Market-Data-Service, KTI-Gateway, Frontend | High | Medium | P1 |
| **D** | ML Artifact Storage | KTI-ML-Service, KTI-Observability | Low | Low | P2 |

**Dependencies:**
- A blocks real trading (paper → live transition)
- B blocks accurate strategy validation
- C blocks day-trading UX (1.5s polling is unusable for scalping)
- D is nice-to-have (local disk works for now)

---

## 2. Workstream A — Live Order Execution (`POST /api/trading/execute`)

### 2.1 Problem Statement

`POST /api/trading/execute` is the only unimplemented stub in the Gateway. It's flagged as requiring "safety controls" because a bug here loses real money.

**Current state:**
- Frontend `tradingApi.executeTrade` exists in `api.js` but is unused
- No UI surface calls it (execution happens via orchestrator or manual broker calls)
- No route handler in Gateway

**Target state:**
- Authenticated users can submit orders via Gateway
- Multi-layer safety: paper-mode guard, kill-switch check, risk preflight, idempotency
- Audit trail in `monitoring_events`

### 2.2 Safety Controls (Required Before Shipping)

#### Layer 1: Paper-Mode Firewall
```python
# KTI-Gateway/app/routes/api/trading.py
@trading_bp.route("/execute", methods=["POST"])
@require_auth
def execute_trade():
    # HARD STOP: reject all live orders until explicitly enabled
    if not os.getenv("LIVE_TRADING_ENABLED") == "true":
        return jsonify({"error": "Live trading disabled. Set LIVE_TRADING_ENABLED=true in .env"}), 403
    
    # Check account mode
    account = broker_client.get_account()
    if not account.get("account_blocked") == False:
        return jsonify({"error": "Account blocked or restricted"}), 403
```

#### Layer 2: Kill-Switch Check
```python
    # Query orchestrator kill-switch state
    orch_status = strategy_engine_client.get_status()
    if orch_status.get("kill_switch_active"):
        return jsonify({"error": "Kill switch active. Trading halted."}), 403
```

#### Layer 3: Risk Preflight
```python
    # Check daily loss limit, position concentration, margin usage
    from kti_db.dal import performance, trades
    
    today_pnl = performance.get_daily_pnl()  # new DAL function needed
    if today_pnl < -float(os.getenv("MAX_DAILY_LOSS", "1000")):
        return jsonify({"error": f"Daily loss limit exceeded: {today_pnl}"}), 403
    
    # Position concentration check
    symbol = body.get("symbol")
    current_positions = broker_client.get_positions()
    total_equity = float(account["equity"])
    
    # Calculate what % of portfolio this order would be
    notional = float(body.get("notional", 0)) or (float(body.get("qty", 0)) * get_current_price(symbol))
    new_concentration = notional / total_equity
    
    if new_concentration > float(os.getenv("MAX_POSITION_PCT", "0.15")):  # 15% default
        return jsonify({"error": f"Position would exceed {MAX_POSITION_PCT*100}% concentration limit"}), 403
```

#### Layer 4: Idempotency
```python
    # Require client-side idempotency key
    idempotency_key = request.headers.get("Idempotency-Key")
    if not idempotency_key:
        return jsonify({"error": "Idempotency-Key header required"}), 422
    
    # Check if already submitted (query orders by client_order_id)
    existing = broker_client.get_order_by_client_id(idempotency_key)
    if existing:
        return jsonify(existing), 200  # return existing order, don't resubmit
```

#### Layer 5: Audit Trail
```python
    # Log to monitoring_events before submission
    from kti_db.dal import monitoring
    monitoring.create_event(
        event_type="order_submitted",
        severity="info",
        message=f"User {user_id} submitting {body['side']} {body.get('qty')} {symbol}",
        metadata={"order": body, "idempotency_key": idempotency_key}
    )
```

#### Layer 6: Confirmation Requirement (Frontend)
```javascript
// Frontend must show a confirmation dialog with:
// - Order preview (symbol, side, qty, type, estimated fill, fees)
// - Paper vs Live indicator (RED BANNER if live)
// - "I understand this is a real order" checkbox
// - 3-second countdown before submit button enables
```

### 2.3 Implementation Steps

**Backend (KTI-Gateway)**

1. **New DAL functions** (`KTI-DB/python/dal/performance.py`):
   ```python
   def get_daily_pnl(date: str | None = None) -> float:
       """Return total P&L for a given date (default today)."""
       # SELECT SUM(pnl) FROM trades WHERE DATE(exit_date) = %s
   
   def get_position_concentration(symbol: str) -> float:
       """Return % of portfolio in this symbol."""
       # Join positions + account equity
   ```

2. **New route** (`KTI-Gateway/app/routes/api/trading.py`):
   ```python
   @trading_bp.route("/execute", methods=["POST"])
   @require_auth
   def execute_trade():
       # All 6 safety layers above
       # Then: broker_client.create_order(...)
       # Return: order object + audit event ID
   ```

3. **Environment variables** (`.env.example`):
   ```bash
   LIVE_TRADING_ENABLED=false  # MUST be explicitly set to "true"
   MAX_DAILY_LOSS=1000         # USD
   MAX_POSITION_PCT=0.15       # 15% of portfolio
   ```

4. **Tests** (`KTI-Gateway/tests/routes/test_trading_execute.py`):
   - Reject when `LIVE_TRADING_ENABLED=false`
   - Reject when kill-switch active
   - Reject when daily loss exceeded
   - Reject when concentration limit exceeded
   - Reject when missing idempotency key
   - Accept valid order and return 201
   - Return existing order on duplicate idempotency key (200)

**Frontend**

5. **Confirmation Dialog** (`src/components/trading/OrderConfirmDialog.js`):
   ```jsx
   <Dialog open={showConfirm}>
     <DialogHeader>
       <AlertTriangle className="text-red-500" />
       Confirm Live Order
     </DialogHeader>
     <DialogBody>
       {account.is_paper ? (
         <div className="bg-blue-100 p-3 rounded">Paper Trading Mode</div>
       ) : (
         <div className="bg-red-100 p-3 rounded font-bold">
           ⚠️ LIVE TRADING — REAL MONEY
         </div>
       )}
       <OrderPreview order={order} fees={estimatedFees} />
       <Checkbox required>
         I understand this will submit a real order
       </Checkbox>
       <CountdownButton seconds={3} onComplete={handleSubmit}>
         Submit Order
       </CountdownButton>
     </DialogBody>
   </Dialog>
   ```

6. **Wire to Trade Ticket** (`src/components/trading/TradeTicket.js`):
   ```javascript
   const handleSubmit = async () => {
     const idempotencyKey = `${user.id}-${Date.now()}-${Math.random()}`;
     
     try {
       const order = await tradingApi.executeTrade(orderParams, {
         headers: { "Idempotency-Key": idempotencyKey }
       });
       toast.success(`Order submitted: ${order.id}`);
       onSuccess(order);
     } catch (err) {
       if (err.response?.status === 403) {
         toast.error(err.response.data.error);  // Show kill-switch / limit message
       } else {
         toast.error("Order failed");
       }
     }
   };
   ```

### 2.4 Rollout Plan

1. **Dev testing** — `LIVE_TRADING_ENABLED=false`, paper account only
2. **Staging** — `LIVE_TRADING_ENABLED=true`, paper account, full safety stack
3. **Prod (limited)** — Enable for admin user only, $100 max order size override
4. **Prod (general)** — After 1 week of admin-only usage with zero incidents

### 2.5 Monitoring

- Grafana alert: any 403 from `/api/trading/execute` → Slack
- Daily digest: count of orders submitted, rejected (by reason), avg latency
- Weekly review: false-positive rate on safety checks

---

## 3. Workstream B — Real Strategy Backtesting

### 3.1 Problem Statement

`KTI-Backtest-Service` currently only has `sma_crossover` (toy strategy). The real production strategies (`MLTrader`, `CryptoTrader`, `ForexTrader`) live in `KTI-Strategy-Engine` and aren't wired into the backtest registry.

**Gap from REFACTOR_PLAN.md:**
- Phase 1 (Python engine) — ✅ Done (Backtest Service exists)
- Phase 1 (wire real strategies) — ❌ Not done
- Phase 1 (Forex support) — ❌ Not done
- Phase 1 (Polygon backend) — ❌ Not done (Yahoo only)
- Phase 3 (frontend dynamic strategy list) — ❌ Not done

### 3.2 Architecture Decision: Import vs HTTP

**Option A**: Import `KTI-Strategy-Engine` strategies directly into Backtest Service
- ✅ No network hop, faster
- ✅ Strategies already Lumibot-compatible
- ❌ Tight coupling (Backtest Service depends on Strategy Engine repo)
- ❌ Duplicate deps in `requirements.txt`

**Option B**: Backtest Service calls Strategy Engine `/strategies/run-backtest` over HTTP
- ✅ Loose coupling
- ✅ Strategy Engine owns all strategy logic
- ❌ Network overhead
- ❌ Requires Strategy Engine to expose backtest endpoint (doesn't exist yet)

**Decision**: **Option A** for Phase 7. Rationale:
- Both services already share `kti_db` as a dependency
- Lumibot strategies are pure Python classes, easy to import
- We're on the same cPanel box, no network latency
- Option B deferred until we have a real need for independent scaling

### 3.3 Implementation Steps

#### Step 1: Add Strategy Engine as a Dependency

**File**: `KTI-Backtest-Service/requirements.txt`
```txt
# Add after existing deps
git+https://github.com/KiwiTon-Tech/KTI-Strategy-Engine.git@main#subdirectory=Strategies
```

This makes `Strategies.Prod.MLTrader`, `Strategies.Prod.CryptoTrader`, etc. importable.

#### Step 2: Extend Strategy Registry

**File**: `KTI-Backtest-Service/app/strategies/registry.py`

```python
from app.strategies.base import StrategySpec

# Lazy imports to avoid Lumibot tax in tests
def _import_mltrader():
    from Strategies.Prod.Stock_Trade_Strategy import MLTrader
    return MLTrader

def _import_cryptotrader():
    from Strategies.Prod.Crypto_Trade_Strategy import CryptoTrader
    return CryptoTrader

def _import_forextrader():
    from Strategies.Prod.Forex_Trade_Strategy import ForexTrader  # new
    return ForexTrader

STRATEGIES = {
    "sma_crossover": StrategySpec(
        id="sma_crossover",
        display_name="SMA Crossover",
        description="Simple moving average crossover (reference implementation)",
        asset_classes=["stock", "crypto"],
        default_params={"fast_period": 10, "slow_period": 30},
        class_loader=lambda: __import__("app.strategies.sma_crossover").strategies.sma_crossover.SMACrossover,
    ),
    "mltrader": StrategySpec(
        id="mltrader",
        display_name="ML Trader (Stock)",
        description="Production ML + sentiment strategy for US equities",
        asset_classes=["stock"],
        default_params={"initial_capital": 100000, "use_sentiment": True},
        class_loader=_import_mltrader,
        requires_ml_service=True,
        requires_sentiment_service=True,
    ),
    "cryptotrader": StrategySpec(
        id="cryptotrader",
        display_name="Crypto Trader",
        description="Production ML + sentiment strategy for crypto",
        asset_classes=["crypto"],
        default_params={"initial_capital": 100000, "use_sentiment": True},
        class_loader=_import_cryptotrader,
        requires_ml_service=True,
        requires_sentiment_service=True,
    ),
    "forextrader": StrategySpec(
        id="forextrader",
        display_name="Forex Trader",
        description="Production scalping strategy for forex pairs",
        asset_classes=["forex"],
        default_params={"initial_capital": 100000, "scalp_mode": True},
        class_loader=_import_forextrader,
        requires_ml_service=False,  # uses technical indicators only
    ),
}
```

#### Step 3: Create Forex Strategy (if doesn't exist)

**Check**: Does `KTI-Strategy-Engine/Strategies/Prod/Forex_Trade_Strategy.py` exist?

If **no**, create it:

**File**: `KTI-Strategy-Engine/Strategies/Prod/Forex_Trade_Strategy.py`
```python
from lumibot.strategies import Strategy
from Strategies.Prod.Scalping import ScalpingStrategy  # reuse logic

class ForexTrader(Strategy):
    """
    Forex scalping strategy using orderbook analysis + technical indicators.
    Inherits core logic from ScalpingStrategy but configured for forex pairs.
    """
    
    def initialize(self, parameters=None):
        self.sleeptime = "1S"  # 1-second loop for scalping
        self.asset_class = "forex"
        # Reuse ScalpingStrategy's MarketAnalyzer, RiskManagement
        # ...
    
    def on_trading_iteration(self):
        # Same as Scalping.py but for EURUSD, GBPUSD, etc.
        # ...
```

Register in `KTI-Strategy-Engine/Strategies/Prod/__init__.py`:
```python
from .Forex_Trade_Strategy import ForexTrader
```

#### Step 4: Add Polygon Data Backend

**File**: `KTI-Backtest-Service/app/engine/lumibot_engine.py`

```python
from lumibot.backtesting import PolygonDataBacktesting

def _pick_backend(strategy_type: str, symbol: str, start: date, end: date):
    """Select data backend based on strategy type and availability."""
    
    polygon_key = os.getenv("POLYGON_API_KEY")
    
    # Prefer Polygon for stocks (15 years of history, accurate)
    if strategy_type == "stock" and polygon_key:
        return PolygonDataBacktesting(
            api_key=polygon_key,
            start_date=start,
            end_date=end,
        )
    
    # Polygon for crypto if available
    if strategy_type == "crypto" and polygon_key:
        return PolygonDataBacktesting(
            api_key=polygon_key,
            start_date=start,
            end_date=end,
            asset_type="crypto",
        )
    
    # Polygon for forex
    if strategy_type == "forex" and polygon_key:
        return PolygonDataBacktesting(
            api_key=polygon_key,
            start_date=start,
            end_date=end,
            asset_type="forex",
        )
    
    # Fallback to Yahoo (free, but limited history + gaps)
    return YahooDataBacktesting(
        datetime_start=start,
        datetime_end=end,
    )
```

**Environment variable**: Add to `KTI-Backtest-Service/.env.example`:
```bash
POLYGON_API_KEY=your_polygon_key_here  # Optional; falls back to Yahoo if unset
```

#### Step 5: Update Frontend to Fetch Strategies Dynamically

**File**: `KiwiTon Investment Frontend/src/app/backtests/page.js`

Currently hardcodes:
```javascript
const STRATEGIES = ["sma_crossover", "rsi_mean_reversion", ...];  // ❌ Static
```

Replace with:
```javascript
const [strategies, setStrategies] = useState([]);

useEffect(() => {
  const fetchStrategies = async () => {
    try {
      const res = await backtestApi.getStrategies();  // GET /backtest/strategies/
      const data = res.data?.data || res.data;
      setStrategies(Array.isArray(data) ? data : []);
    } catch (err) {
      console.error("Failed to fetch strategies:", err);
      setStrategies([]);
    }
  };
  fetchStrategies();
}, []);

// Render dropdown
<Select>
  {strategies.map(s => (
    <option key={s.id} value={s.id}>
      {s.display_name} {s.requires_ml_service && "🤖"}
    </option>
  ))}
</Select>
```

**File**: `KiwiTon Investment Frontend/src/lib/api.js`

Add if missing:
```javascript
export const backtestApi = {
  getStrategies: () => apiClient.get("/backtest/strategies/"),
  // ... existing methods
};
```

### 3.4 Testing Plan

**Unit tests** (`KTI-Backtest-Service/tests/strategies/test_registry.py`):
- Verify `mltrader`, `cryptotrader`, `forextrader` are registered
- Lazy load each strategy class (no import errors)
- Verify `requires_ml_service` flags are correct

**Integration test** (manual, skipped in CI):
```bash
# Submit a backtest for MLTrader on SPY, last 30 days
curl -X POST https://backtest.kiwiton-investments.com/backtests \
  -H "X-KTI-Token: $TOKEN" \
  -d '{
    "strategy_id": "mltrader",
    "symbol": "SPY",
    "start_date": "2026-04-28",
    "end_date": "2026-05-28",
    "initial_capital": 100000
  }'

# Poll until complete
# Verify result.metrics.sharpe_ratio is populated
```

**Frontend test**:
- Navigate to `/backtests`
- Verify strategy dropdown shows "ML Trader (Stock) 🤖", "Crypto Trader 🤖", "Forex Trader", "SMA Crossover"
- Submit backtest for each → verify job enqueued

### 3.5 Rollout

1. **Merge Strategy Engine changes** (if Forex strategy is new)
2. **Deploy Backtest Service** with updated registry + Polygon backend
3. **Deploy Frontend** with dynamic strategy fetch
4. **Smoke test** — run one backtest per strategy
5. **Document** — update ARCHITECTURE.md Phase 4b status to ✅

---

## 4. Workstream C — WebSocket Price Streaming

### 4.1 Problem Statement

Phase 3b was deferred. Current state:
- Frontend polls `/market/bars/latest` every 1.5s
- Market Data Service has in-process TTL cache (1.5s equity, 5s crypto)
- No WebSocket fan-out

**For day trading, this is unusable:**
- Scalping needs <100ms price updates
- 1.5s lag = missed entries
- Polling wastes bandwidth (same price returned repeatedly)

### 4.2 Architecture

```
Alpaca WebSocket
   ↓
KTI-Market-Data-Service (FastAPI + WebSocket server)
   ↓ (Redis Pub/Sub)
KTI-Gateway (WebSocket proxy)
   ↓
Frontend (socket.io-client)
```

**Why Redis Pub/Sub?**
- Market Data Service publishes price ticks to `prices.{symbol}` channel
- Gateway subscribes and fans out to N connected browsers
- Decouples producer (1 Alpaca WS) from consumers (N users)

**Why not direct WS from Market Data Service?**
- Gateway already handles auth, CORS, rate-limiting
- Keeps Market Data Service stateless (no session management)

### 4.3 Implementation Steps

#### Step 1: Add Redis to Infrastructure

**Install Upstash Redis** (cloud-hosted, free tier, no server install):
1. Sign up at upstash.com
2. Create database → copy `REDIS_URL` (rediss://...)
3. Add to all services' `.env`:
   ```bash
   REDIS_URL=rediss://default:***@us1-***-***.upstash.io:6379
   ```

**Add to requirements.txt** (Market Data Service + Gateway):
```txt
redis[hiredis]==5.0.1
```

#### Step 2: Market Data Service — WebSocket Server

**File**: `KTI-Market-Data-Service/app/websocket.py`
```python
import asyncio
import json
from fastapi import WebSocket, WebSocketDisconnect
from alpaca.data.live import StockDataStream, CryptoDataStream
import redis.asyncio as redis

redis_client = redis.from_url(os.getenv("REDIS_URL"))

# Alpaca WebSocket clients
stock_stream = StockDataStream(api_key=..., secret_key=...)
crypto_stream = CryptoDataStream(api_key=..., secret_key=...)

async def handle_stock_trade(trade):
    """Publish stock trade to Redis."""
    await redis_client.publish(
        f"prices.{trade.symbol}",
        json.dumps({
            "symbol": trade.symbol,
            "price": float(trade.price),
            "size": int(trade.size),
            "timestamp": trade.timestamp.isoformat(),
            "asset_class": "stock",
        })
    )

async def handle_crypto_trade(trade):
    """Publish crypto trade to Redis."""
    await redis_client.publish(
        f"prices.{trade.symbol}",
        json.dumps({
            "symbol": trade.symbol,
            "price": float(trade.price),
            "size": float(trade.size),
            "timestamp": trade.timestamp.isoformat(),
            "asset_class": "crypto",
        })
    )

# Subscribe to symbols (managed via /subscribe endpoint)
subscribed_symbols = set()

async def start_streams():
    """Start Alpaca WebSocket streams."""
    stock_stream.subscribe_trades(handle_stock_trade, *subscribed_symbols)
    crypto_stream.subscribe_trades(handle_crypto_trade, *subscribed_symbols)
    
    await asyncio.gather(
        stock_stream._run_forever(),
        crypto_stream._run_forever(),
    )
```

**File**: `KTI-Market-Data-Service/app/routes/websocket.py`
```python
from fastapi import APIRouter, WebSocket

router = APIRouter()

@router.post("/subscribe")
async def subscribe_symbols(symbols: list[str]):
    """Add symbols to Alpaca WebSocket subscription."""
    # Update subscribed_symbols set
    # Restart streams if needed
    return {"subscribed": symbols}

@router.websocket("/stream")
async def websocket_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for internal subscribers (Gateway).
    Streams all price ticks from Redis Pub/Sub.
    """
    await websocket.accept()
    
    pubsub = redis_client.pubsub()
    await pubsub.psubscribe("prices.*")
    
    try:
        async for message in pubsub.listen():
            if message["type"] == "pmessage":
                await websocket.send_text(message["data"])
    except WebSocketDisconnect:
        await pubsub.unsubscribe()
```

#### Step 3: Gateway — WebSocket Proxy

**File**: `KTI-Gateway/app/websocket.py`
```python
from flask_sock import Sock
import redis
import json

sock = Sock(app)
redis_client = redis.from_url(os.getenv("REDIS_URL"))

@sock.route("/ws/prices")
def prices_websocket(ws):
    """
    WebSocket endpoint for frontend clients.
    Subscribes to Redis and forwards price ticks.
    """
    pubsub = redis_client.pubsub()
    pubsub.psubscribe("prices.*")
    
    try:
        for message in pubsub.listen():
            if message["type"] == "pmessage":
                ws.send(message["data"])
    except Exception as e:
        logging.error(f"WebSocket error: {e}")
    finally:
        pubsub.unsubscribe()
```

**Add to requirements.txt**:
```txt
flask-sock==0.7.0
redis[hiredis]==5.0.1
```

#### Step 4: Frontend — WebSocket Client

**File**: `KiwiTon Investment Frontend/src/lib/realtime.js`
```javascript
import io from "socket.io-client";

class RealtimeClient {
  constructor() {
    this.socket = null;
    this.listeners = new Map();
  }

  connect() {
    if (this.socket?.connected) return;
    
    this.socket = io("wss://api.kiwiton-investments.com/ws/prices", {
      transports: ["websocket"],
      auth: {
        token: localStorage.getItem("accessToken"),
      },
    });

    this.socket.on("connect", () => {
      console.log("WebSocket connected");
    });

    this.socket.on("message", (data) => {
      const tick = JSON.parse(data);
      const handlers = this.listeners.get(tick.symbol) || [];
      handlers.forEach(fn => fn(tick));
    });

    this.socket.on("disconnect", () => {
      console.log("WebSocket disconnected");
    });
  }

  subscribe(symbol, callback) {
    if (!this.listeners.has(symbol)) {
      this.listeners.set(symbol, []);
    }
    this.listeners.get(symbol).push(callback);
    
    // Tell backend to subscribe to this symbol
    this.socket?.emit("subscribe", { symbols: [symbol] });
  }

  unsubscribe(symbol, callback) {
    const handlers = this.listeners.get(symbol) || [];
    this.listeners.set(symbol, handlers.filter(fn => fn !== callback));
  }

  disconnect() {
    this.socket?.disconnect();
  }
}

export const realtimeClient = new RealtimeClient();
```

**File**: `KiwiTon Investment Frontend/src/hooks/useRealtimePrice.js`
```javascript
import { useState, useEffect } from "react";
import { realtimeClient } from "@/lib/realtime";

export function useRealtimePrice(symbol) {
  const [price, setPrice] = useState(null);
  const [lastUpdate, setLastUpdate] = useState(null);

  useEffect(() => {
    if (!symbol) return;

    realtimeClient.connect();

    const handleTick = (tick) => {
      setPrice(tick.price);
      setLastUpdate(new Date(tick.timestamp));
    };

    realtimeClient.subscribe(symbol, handleTick);

    return () => {
      realtimeClient.unsubscribe(symbol, handleTick);
    };
  }, [symbol]);

  return { price, lastUpdate };
}
```

**Usage in components**:
```javascript
// In TickerCard.js or any price display
const { price: livePrice } = useRealtimePrice(ticker.symbol);
const displayPrice = livePrice ?? ticker.price;  // fallback to snapshot
```

#### Step 5: Connection Status Indicator

**File**: `KiwiTon Investment Frontend/src/components/layout/ConnectionStatus.js`
```javascript
export function ConnectionStatus() {
  const [status, setStatus] = useState("connecting");

  useEffect(() => {
    realtimeClient.socket?.on("connect", () => setStatus("connected"));
    realtimeClient.socket?.on("disconnect", () => setStatus("disconnected"));
  }, []);

  const colors = {
    connected: "bg-green-500",
    connecting: "bg-amber-500 animate-pulse",
    disconnected: "bg-red-500",
  };

  return (
    <div className="flex items-center gap-2">
      <div className={`h-2 w-2 rounded-full ${colors[status]}`} />
      <span className="text-xs text-gray-500">
        {status === "connected" ? "Live" : status}
      </span>
    </div>
  );
}
```

Add to Navbar.

### 4.4 Testing

**Manual test**:
1. Open `/market-search` in browser
2. Open DevTools → Network → WS tab
3. Verify WebSocket connection to `wss://api.kiwiton-investments.com/ws/prices`
4. Watch ticker prices update in <100ms

**Load test**:
- 100 concurrent browser connections
- Each subscribed to 10 symbols
- Verify no dropped messages, <200ms latency p99

### 4.5 Rollout

1. **Deploy Redis** (Upstash)
2. **Deploy Market Data Service** with Alpaca WS → Redis publisher
3. **Deploy Gateway** with Redis → WebSocket proxy
4. **Deploy Frontend** with `useRealtimePrice` hook
5. **Monitor** — Grafana dashboard for WS connection count, message rate, latency

---

## 5. Workstream D — ML Artifact Storage (S3/GCS)

### 5.1 Problem Statement

`KTI-ML-Service` currently saves trained models to local disk (`/app/models/`). Issues:
- Lost on Passenger restart
- Not shared across workers (if we scale to >1)
- No versioning, no rollback

### 5.2 Solution: S3-Compatible Storage

Use **Cloudflare R2** (S3-compatible, free egress, $0.015/GB/month):
- No egress fees (unlike AWS S3)
- S3 API compatible (use `boto3`)
- Integrated with existing Cloudflare account

### 5.3 Implementation

**File**: `KTI-ML-Service/app/storage.py`
```python
import boto3
import os
from pathlib import Path

s3 = boto3.client(
    "s3",
    endpoint_url=os.getenv("S3_ENDPOINT"),  # e.g. https://<account>.r2.cloudflarestorage.com
    aws_access_key_id=os.getenv("S3_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("S3_SECRET_KEY"),
)

BUCKET = os.getenv("S3_BUCKET", "kti-ml-models")

def save_model(model, model_id: str, version: str):
    """Save model to S3."""
    local_path = f"/tmp/{model_id}_{version}.pkl"
    joblib.dump(model, local_path)
    
    s3_key = f"models/{model_id}/{version}.pkl"
    s3.upload_file(local_path, BUCKET, s3_key)
    
    Path(local_path).unlink()  # cleanup
    return s3_key

def load_model(model_id: str, version: str):
    """Load model from S3."""
    s3_key = f"models/{model_id}/{version}.pkl"
    local_path = f"/tmp/{model_id}_{version}.pkl"
    
    s3.download_file(BUCKET, s3_key, local_path)
    model = joblib.load(local_path)
    
    Path(local_path).unlink()
    return model
```

**Environment variables** (`.env.example`):
```bash
S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
S3_ACCESS_KEY=your_r2_access_key
S3_SECRET_KEY=your_r2_secret_key
S3_BUCKET=kti-ml-models
```

**Update training pipeline** (`app/routes/train.py`):
```python
# After training
model_key = storage.save_model(model, symbol, version_id)

# Save metadata to DB
from kti_db.dal import ml_models
ml_models.create_model_version(
    model_id=symbol,
    version=version_id,
    s3_key=model_key,
    metrics=metrics,
)
```

**Update prediction** (`app/routes/predict.py`):
```python
# Load latest version
latest = ml_models.get_latest_version(symbol)
model = storage.load_model(symbol, latest.version)
```

### 5.4 Rollout

1. Create R2 bucket
2. Deploy ML Service with S3 integration
3. Retrain one model → verify saved to R2
4. Restart service → verify model loads from R2

---

## 6. Timeline & Milestones

| Week | Milestone | Deliverable |
|---|---|---|
| **1** | Workstream A — Order Execution | `POST /api/trading/execute` live in paper mode |
| **2** | Workstream B — Real Strategies | MLTrader/CryptoTrader/ForexTrader in backtest registry |
| **3** | Workstream B — Polygon + Frontend | Polygon backend + dynamic strategy dropdown |
| **4** | Workstream C — WebSocket (Backend) | Redis + Market Data WS + Gateway proxy |
| **5** | Workstream C — WebSocket (Frontend) | `useRealtimePrice` hook + connection indicator |
| **6** | Workstream D — S3 Storage | ML models saved to R2 |
| **7** | Testing & Documentation | Integration tests, ARCHITECTURE.md updates |

---

## 7. Success Criteria

- [ ] **A1**: User can submit live order via `/api/trading/execute` with all 6 safety layers active
- [ ] **A2**: Zero incidents in 1 week of admin-only live trading
- [ ] **B1**: Backtest MLTrader on SPY (30d) completes in <60s with Polygon data
- [ ] **B2**: Frontend `/backtests` shows 4 strategies (SMA, MLTrader, CryptoTrader, ForexTrader)
- [ ] **C1**: WebSocket price updates arrive in <100ms p99
- [ ] **C2**: 100 concurrent users, 10 symbols each, zero dropped messages
- [ ] **D1**: ML model survives Passenger restart (loaded from R2)

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Live order bug loses money | **Critical** | 6-layer safety stack, paper-mode first, admin-only rollout |
| Alpaca WS rate limits | High | Redis dedup, subscribe only to active watchlist symbols |
| R2 egress costs | Low | Cloudflare R2 has free egress |
| Strategy Engine import breaks Backtest Service | Medium | Pin Strategy Engine version in `requirements.txt` |
| Polygon API key cost | Medium | Free tier: 5 calls/min; cache aggressively |

---

## 9. Next Steps

**Immediate (this session)**:
1. Create feature branches:
   - `feat/live-order-execution`
   - `feat/real-strategy-backtesting`
   - `feat/websocket-streaming`
   - `feat/s3-ml-storage`

2. Start with **Workstream B** (lowest risk, highest validation value):
   - Add Strategy Engine to Backtest Service deps
   - Extend registry with MLTrader/CryptoTrader/ForexTrader
   - Test locally

**Follow-up sessions**:
- Workstream A (requires careful safety review)
- Workstream C (requires Redis setup)
- Workstream D (requires R2 setup)

---

**Ready to proceed?** I recommend starting with Workstream B (real strategy backtesting) since it's the most straightforward and unblocks strategy validation immediately.
