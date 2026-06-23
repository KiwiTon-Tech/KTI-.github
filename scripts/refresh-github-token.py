#!/usr/bin/env python3
"""Generate a GitHub App installation token and write it to ~/.git-credentials.

Run every 55 minutes via cPanel cron:
  */55 * * * * /home/kiwiton/virtualenv/apps/KTI-ML-Service/3.11/bin/python \
      /home/kiwiton/bin/refresh-github-token.py >> /home/kiwiton/logs/token-refresh.log 2>&1
"""

import base64
import json
import os
import time
import urllib.request
from datetime import datetime

APP_ID = os.environ.get("KTI_APP_ID", "3600921")
INSTALLATION_ID = os.environ.get("KTI_INSTALLATION_ID", "129507234")
PEM_PATH = os.environ.get("KTI_PEM_PATH", "/home/kiwiton/secrets/kti-deploy-bot.pem")
CREDS_PATH = os.path.expanduser("~/.git-credentials")


def _b64url(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _make_jwt() -> str:
    now = int(time.time())
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")))
    payload = _b64url(
        json.dumps(
            {"iat": now - 60, "exp": now + 600, "iss": APP_ID},
            separators=(",", ":"),
        )
    )
    unsigned = f"{header}.{payload}"

    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    with open(PEM_PATH, "rb") as f:
        private_key = serialization.load_pem_private_key(f.read(), password=None)

    signature = private_key.sign(unsigned.encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{unsigned}.{_b64url(signature)}"


def _get_installation_token(jwt: str) -> str:
    url = f"https://api.github.com/app/installations/{INSTALLATION_ID}/access_tokens"
    req = urllib.request.Request(
        url,
        method="POST",
        headers={
            "Authorization": f"Bearer {jwt}",
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "KTI-Deploy-Bot/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    return data["token"]


def _write_credentials(token: str) -> None:
    try:
        with open(CREDS_PATH) as f:
            lines = [line for line in f if "github.com" not in line]
    except FileNotFoundError:
        lines = []
    lines.append(f"https://x-access-token:{token}@github.com\n")
    with open(CREDS_PATH, "w") as f:
        f.writelines(lines)
    os.chmod(CREDS_PATH, 0o600)


def main() -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        jwt = _make_jwt()
        token = _get_installation_token(jwt)
        _write_credentials(token)
        print(f"[{ts}] ✅ GitHub token refreshed (expires ~1h)")
    except Exception as exc:  # noqa: BLE001
        print(f"[{ts}] ❌ Token refresh failed: {exc}")
        raise


if __name__ == "__main__":
    main()
