# Alpaca OpenAPI 3.0 Audit Report

**Date:** 2026-06-15  
**Auditor:** Cascade AI  
**Specs Reviewed:**
- Market Data API: https://docs.alpaca.markets/us/openapi/market-data-api.json
- Trading API: https://docs.alpaca.markets/us/openapi/trading-api.json

---

## Executive Summary

| Category | Status | Action Required |
|----------|--------|-----------------|
| Market Data API | ✅ Compliant | None - using alpaca-py SDK which tracks spec |
| Trading API - Core Endpoints | ✅ Compliant | None - SDK methods match spec |
| Trading API - Deprecated Fields | ⚠️ Review Needed | 4 fields with deprecation warnings |
| New Endpoints (Options, Perpetuals, Tokenization) | 🔍 Not Implemented | Evaluate for roadmap |

---

## 1. Market Data API Audit

### 1.1 Endpoints We Use (via alpaca-py SDK)

| Endpoint | Spec Path | SDK Method | Status |
|----------|-----------|------------|--------|
| Historical Bars (Multi) | `GET /v2/stocks/bars` | `StockHistoricalDataClient.get_stock_bars()` | ✅ |
| Historical Bars (Single) | `GET /v2/stocks/{symbol}/bars` | Same, single symbol | ✅ |
| Latest Bars | `GET /v2/stocks/bars/latest` | `get_stock_latest_bar()` | ✅ |
| Latest Quotes | `GET /v2/stocks/quotes/latest` | `get_stock_latest_quote()` | ✅ |
| Latest Trades | `GET /v2/stocks/trades/latest` | `get_stock_latest_trade()` | ✅ |
| Historical Quotes | `GET /v2/stocks/quotes` | `get_stock_quotes()` | ✅ |
| Historical Trades | `GET /v2/stocks/trades` | `get_stock_trades()` | ✅ |
| Snapshots | `GET /v2/stocks/snapshots` | `get_stock_snapshot()` | ✅ |
| Auctions | `GET /v2/stocks/auctions` | `get_stock_auctions()` | ✅ |
| Crypto Bars | `GET /v1beta3/crypto/{loc}/bars` | `CryptoHistoricalDataClient.get_crypto_bars()` | ✅ |
| Crypto Quotes | `GET /v1beta3/crypto/{loc}/quotes` | `get_crypto_quotes()` | ✅ |
| Crypto Trades | `GET /v1beta3/crypto/{loc}/trades` | `get_crypto_trades()` | ✅ |
| Crypto Latest | `GET /v1beta3/crypto/{loc}/latest/*` | `get_crypto_latest_*()` | ✅ |

### 1.2 Parameters Validation

| Parameter | Our Usage | Spec Compliance | Notes |
|-----------|-----------|-----------------|-------|
| `feed` (stocks) | `iex` default, `sip` option | ✅ Valid: `sip`, `iex`, `boats`, `otc` (hist), `delayed_sip`, `overnight` (latest) | Compliant |
| `timeframe` | `1Min`, `5Min`, `15Min`, `1Hour`, `1Day`, etc. | ✅ Valid: `[1-59]Min/T`, `[1-23]Hour/H`, `1Day/D`, `1Week/W`, `[1,2,3,4,6,12]Month/M` | Compliant |
| `adjustment` | Not currently used | Valid: `raw`, `split`, `dividend`, `spin-off`, `all` | **Gap:** Consider adding to `get_bars()` |
| `start`/`end` | ISO datetime strings | ✅ RFC-3339 or YYYY-MM-DD | Compliant |
| `limit` | Up to 10,000 | ✅ Default 1000, max 10000 | Compliant |
| `asof` | Not used | Date for symbol mapping (corporate actions) | **Gap:** For backtesting accuracy |

### 1.3 Findings: Market Data

**No issues found.** The `alpaca-py` SDK abstracts the REST endpoints correctly. Our `KTI-Market-Data-Service` passes parameters through to SDK methods that construct compliant requests.

**Minor Observation:**
- The spec shows `overnight` as a valid `feed` value for latest data - we should add this to our `alpaca_stock_feed` config options if we want to support 24x5 trading.

---

## 2. Trading API Audit

### 2.1 Endpoints We Use (via alpaca-py SDK)

| Feature | Spec Path | SDK Method | Status |
|---------|-----------|------------|--------|
| Account | `GET /v2/account` | `TradingClient.get_account()` | ✅ |
| Positions List | `GET /v2/positions` | `get_all_positions()` | ✅ |
| Position Detail | `GET /v2/positions/{symbol_or_asset_id}` | `get_open_position()` | ✅ |
| Close Position | `DELETE /v2/positions/{symbol_or_asset_id}` | `close_position()` | ✅ |
| Close All | `DELETE /v2/positions` | `close_all_positions()` | ✅ |
| List Orders | `GET /v2/orders` | `get_orders()` | ✅ |
| Get Order | `GET /v2/orders/{order_id}` | `get_order_by_id()` | ✅ |
| Get by Client ID | `GET /v2/orders:by_client_order_id` | `get_order_by_client_id()` | ✅ |
| Create Order | `POST /v2/orders` | `submit_order()` | ✅ |
| Cancel Order | `DELETE /v2/orders/{order_id}` | `cancel_order_by_id()` | ✅ |
| Cancel All | `DELETE /v2/orders` | `cancel_orders()` | ✅ |
| Clock | `GET /v2/clock` | `get_clock()` | ✅ |
| Calendar | `GET /v2/calendar` | `get_calendar()` | ✅ |
| Portfolio History | `GET /v2/account/portfolio/history` | `get_portfolio_history()` | ✅ |
| Account Activities | `GET /v2/account/activities` | Custom REST call | ✅ |

### 2.2 ⚠️ Deprecated Fields (ACTION REQUIRED)

The following fields in the `Account` schema are deprecated and will be sunset:

| Field | Deprecation Date | Sunset Date | Replacement | Our Usage |
|-------|------------------|-------------|-------------|-----------|
| `daytrade_count` | 2026-04-27 | 2026-07-06 | None (FINRA rule change) | Likely in dashboard |
| `daytrading_buying_power` | 2026-04-27 | 2026-07-06 | None (FINRA rule change) | Likely in dashboard |
| `pattern_day_trader` | 2026-04-27 | 2026-07-06 | None (FINRA rule change) | Likely in dashboard |
| `easy_to_borrow` | 2026-06-22 | 2026-09-22 | `borrow_status` | `serialize_position()` |
| `maintenance_margin_requirement` | 2026-06-22 | 2026-09-22 | `margin_requirement_long/short` | Unknown |

**Impact Assessment:**
- **High:** `easy_to_borrow` → `borrow_status` change affects position serialization
- **Medium:** PDT-related fields will disappear; dashboard UI needs updating
- **Low:** Margin requirement field rename

### 2.3 New/Unimplemented Endpoints

These endpoints exist in the spec but are not currently implemented in our services:

| Endpoint | Description | Use Case for KTI |
|----------|-------------|------------------|
| `GET /v2/orders/{id}/replace` | Patch/replace order | Modify existing orders (nice-to-have) |
| `POST /v2/watchlists` | Create watchlist | User watchlist management |
| `GET /v2/watchlists` | List watchlists | Dashboard watchlist display |
| `GET /v2/assets` | List assets | Symbol search/validation |
| `GET /v2/corporate-actions` | Corporate actions | Dividend/split handling in backtests |
| Options endpoints | Full options chain support | Options trading (future) |
| Crypto Perpetuals | `/v2/perpetuals/*` | Crypto futures (future) |
| Tokenization | `/v2/tokenization/*` | RWA tokenization (future) |

### 2.4 Assets Schema Changes

The `Assets` object has new fields we should expose:

```yaml
New Fields:
  - borrow_status: enum ["easy_to_borrow", "hard_to_borrow"]  # Replaces easy_to_borrow
  - margin_requirement_long: string  # Replaces maintenance_margin_requirement
  - margin_requirement_short: string
  - attributes: array of enums  # New: ptp_no_exception, ipo, has_options, etc.
  - overnight_tradable: boolean  # New: 24x5 support
  - overnight_halted: boolean
```

---

## 3. Configuration Validation

### 3.1 Current Config (Market Data)

```python
# app/config.py
alpaca_stock_feed: Literal["iex", "sip"] = "iex"  # Current
```

**Recommendation:** Add new feed options:
```python
alpaca_stock_feed: Literal["iex", "sip", "delayed_sip", "boats", "overnight", "otc"] = "iex"
```

### 3.2 Current Config (Broker)

```python
# app/config.py
alpaca_paper: bool = True  # ✅ Still valid
```

---

## 4. Action Items

### 4.1 High Priority (Before 2026-07-06)

1. **Update `KTI-Broker-Service` serializers**
   - File: `app/serializers.py`
   - Add `borrow_status` field to position serialization
   - Remove/migrate PDT fields from account serialization
   - Update tests

2. **Dashboard UI Audit**
   - Check if `daytrade_count`, `daytrading_buying_power`, or `pattern_day_trader` displayed
   - Prepare to remove or replace with educational content about FINRA rule changes

### 4.2 Medium Priority (Before 2026-09-22)

3. **Migrate `easy_to_borrow` → `borrow_status`**
   - Update `serialize_position()` in `KTI-Broker-Service`
   - Update any frontend position display components
   - Note: `borrow_status` is a string enum, not boolean

4. **Add `adjustment` parameter to Market Data bars endpoint**
   - Allow backtests to request split-adjusted data
   - Update `KTI-Market-Data-Service` `get_bars()` and routes

### 4.3 Low Priority (Roadmap Evaluation)

5. **Evaluate Corporate Actions API**
   - `/v1/corporate-actions` endpoint
   - Would improve backtest accuracy for splits/dividends
   - Implementation: Add endpoint to Market Data Service

6. **Evaluate Watchlist API**
   - Would allow per-user watchlists in dashboard
   - Requires database persistence layer

7. **Evaluate 24x5/Overnight Trading**
   - Add `overnight` to `alpaca_stock_feed` options
   - Check strategy engine support for extended hours

---

## 5. Test Recommendations

Add integration tests that:
1. Verify SDK version matches latest alpaca-py
2. Assert deprecated fields are handled gracefully
3. Test new feed options when added

```python
# Example test to add to KTI-Broker-Service
def test_account_response_handles_missing_pdt_fields():
    """Ensure we handle Account without deprecated PDT fields."""
    # Mock response without daytrade_count, etc.
    # Should not raise AttributeError
```

---

## 6. SDK Version Check

Current approach (SDK-based) is correct. The `alpaca-py` SDK will:
- Handle endpoint URL changes
- Add new response fields as attributes
- Provide deprecation warnings for removed fields

**Recommendation:** Pin minimum SDK version in requirements:
```txt
alpaca-py>=0.40.0  # Check latest version with OpenAPI 3.0 support
```

---

## Appendix: Deprecated Field Details

### Account Schema Deprecations (FINRA PDT Rule Change)
- **Reason:** FINRA adopted new Intraday Margin Standards, eliminating Pattern Day Trader classification
- **Impact:** All accounts will have 2x or 4x buying power based on equity, not trade count
- **Documentation:** https://docs.alpaca.markets/us/docs/understanding-finras-new-intraday-margin-rule-and-the-end-of-pdt

### Assets Schema Deprecations
- **easy_to_borrow → borrow_status:** Boolean to enum migration for more granular borrow availability
- **maintenance_margin_requirement → margin_requirement_long/short:** Separate requirements per position side

---

*Audit Complete. Recommended action: Update serializers for deprecations by July 2026.*
