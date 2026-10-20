from __future__ import annotations

import base64
import hashlib
import hmac
import json
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import requests
from dotenv import dotenv_values

APPS = Path("/home/kiwiton/apps")
TIMEOUT = 20


def _config(service: str) -> dict[str, str]:
    return {
        key: value
        for key, value in dotenv_values(APPS / service / ".env").items()
        if value is not None
    }


def _expect(response: requests.Response, status: int, label: str) -> dict:
    if response.status_code != status:
        raise RuntimeError(
            f"{label}: expected HTTP {status}, got {response.status_code}: "
            f"{response.text[:300]}"
        )
    if response.headers.get("content-type", "").startswith("application/json"):
        return response.json()
    return {}


def _jwt(payload: dict, secret: str) -> str:
    def encode(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).rstrip(b"=").decode()

    header = encode(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = encode(json.dumps(payload, separators=(",", ":")).encode())
    signature = encode(
        hmac.new(secret.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    )
    return f"{header}.{body}.{signature}"


def main() -> int:
    health_urls = (
        "https://api.kiwiton-investments.com/health/",
        "https://broker.kiwiton-investments.com/health",
        "https://market.kiwiton-investments.com/health",
        "https://ml.kiwiton-investments.com/health",
        "https://news.kiwiton-investments.com/health",
        "https://nlp.kiwiton-investments.com/health",
        "https://backtest.kiwiton-investments.com/health",
        "https://engine.kiwiton-investments.com/health",
    )
    for url in health_urls:
        response = requests.get(url, timeout=TIMEOUT)
        _expect(response, 200, url)
        print(f"PASS health {url}")

    broker = _config("KTI-Broker-Service")
    halt = requests.get(
        "https://broker.kiwiton-investments.com/safety/halt",
        headers={"X-KTI-Token": broker["SHARED_AUTH_TOKEN"]},
        timeout=TIMEOUT,
    )
    halt_payload = _expect(halt, 200, "broker halt state")
    if "active" not in halt_payload or "version" not in halt_payload:
        raise RuntimeError("broker halt response is missing required fields")
    print("PASS broker halt state")

    oauth = requests.get(
        "https://api.kiwiton-investments.com/auth/google/",
        params={"callbackUrl": "https://invalid.example"},
        timeout=TIMEOUT,
    )
    _expect(oauth, 400, "OAuth callback allowlist")
    print("PASS OAuth callback allowlist")

    gateway = _config("KTI-Gateway")
    now = datetime.now(UTC)
    token = _jwt(
        {
            "userId": "deployment-smoke",
            "role": "admin",
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(minutes=5)).timestamp()),
        },
        gateway["JWT_SECRET"],
    )
    contract = requests.post(
        "https://api.kiwiton-investments.com/api/trading/execute",
        headers={
            "Authorization": f"Bearer {token}",
            "Idempotency-Key": "deployment-contract-smoke",
        },
        json={
            "symbol": "AAPL",
            "side": "buy",
            "type": "limit",
            "notional": 25,
            "limit_price": 150,
        },
        timeout=TIMEOUT,
    )
    _expect(contract, 400, "Gateway order contract")
    print("PASS Gateway order contract")

    ml = _config("KTI-ML-Service")
    unknown = requests.get(
        "https://ml.kiwiton-investments.com/train/status/deployment-smoke-missing",
        headers={"X-KTI-Token": ml["SHARED_AUTH_TOKEN"]},
        timeout=TIMEOUT,
    )
    _expect(unknown, 404, "persistent ML queue status")
    print("PASS persistent ML queue status")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"SMOKE FAILURE: {exc}", file=sys.stderr)
        raise SystemExit(1)
