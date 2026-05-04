# cPanel Deployment Playbook

End-to-end setup for deploying any `KTI-*` service to a shared cPanel host
that **blocks inbound SSH** (e.g. `t-4.net`). The model is "cPanel pulls from
GitHub", authenticated via a single org-level GitHub App.

This playbook is split into:

- **[Part A](#part-a-one-time-org-setup)** — one-time GitHub-side setup (run once for the entire org).
- **[Part B](#part-b-one-time-cpanel-setup)** — one-time cPanel-side setup (run once per cPanel server).
- **[Part C](#part-c-per-service-setup)** — per-service setup (run for every new `KTI-*` repo).

Tested against:

- cPanel 110+ on CloudLinux with Phusion Passenger.
- Python 3.11 (`/opt/alt/python311`).
- GitHub Free plan with private repos.

---

## Part A: one-time org setup

### A1. Repo-visibility prerequisites

- `KTI-.github` repo → **Public** (so private repos can consume the reusable
  workflows without paying for GitHub Team).
- All service repos (`KTI-*`) → **Private**.

### A2. Org Actions permissions

`https://github.com/organizations/KiwiTon-Tech/settings/actions`:

- **Actions permissions** → ⦿ **Allow all actions and reusable workflows**.

### A3. Member privileges (deploy keys)

`https://github.com/organizations/KiwiTon-Tech/settings/member_privileges`:

- **Deploy keys** → enabled (GitHub disables them by default in some org
  templates; we use them for some integrations alongside the App).

### A4. Create the `KTI-Deploy-Bot` GitHub App

`https://github.com/organizations/KiwiTon-Tech/settings/apps` →
**New GitHub App**.

| Field | Value |
|-------|-------|
| Name | `KTI-Deploy-Bot` (must be globally unique) |
| Homepage URL | `https://kiwiton-investments.com` |
| Webhook → Active | ☐ unchecked |
| Repository permissions → **Contents** | Read-only |
| Repository permissions → **Metadata** | Read-only (auto) |
| Where can this be installed? | ⦿ Only on this account |

After creation:

1. Note the **App ID** (e.g. `3600921`).
2. **Generate a private key** → downloads `*.pem`. Save it securely.
3. **Install App** → install on the org → **All repositories** (so future
   `KTI-*` repos are auto-included).
4. Note the **Installation ID** from the post-install URL:
   `.../settings/installations/<INSTALLATION_ID>`.

### A5. Seed repo-level Actions secrets

Org-level secrets don't work with private repos on the free plan. Use this
loop with the `gh` CLI (from your laptop, requires `gh auth login`):

```bash
# One-time: store secret values locally
mkdir -p ~/.kiwiton-secrets && chmod 700 ~/.kiwiton-secrets
cat > ~/.kiwiton-secrets/ci-secrets.env <<'EOF'
CPANEL_HOST=server.t-4.net
CPANEL_USER=kiwiton
CPANEL_BASE_PATH=/home/kiwiton/apps
CPANEL_SSH_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
...not used in production-pull mode but kept for hosts that allow inbound SSH...
-----END OPENSSH PRIVATE KEY-----"
EOF
chmod 600 ~/.kiwiton-secrets/ci-secrets.env

# Seed all repos in one shot
set -a; source ~/.kiwiton-secrets/ci-secrets.env; set +a
for repo in KTI-NLP-Service KTI-Broker-Service KTI-Market-Data-Service \
            KTI-News-Sentiment-Service KTI-ML-Service KTI-Strategy-Engine \
            KTI-Backtest-Service KTI-Gateway KTI-DB-Migrations \
            KTI-Contracts KTI-Observability KTI-Orchestrator KTI-Platform; do
  echo "=== $repo ==="
  gh secret set CPANEL_HOST       --repo "KiwiTon-Tech/$repo" --body "$CPANEL_HOST" 2>/dev/null
  gh secret set CPANEL_USER       --repo "KiwiTon-Tech/$repo" --body "$CPANEL_USER" 2>/dev/null
  gh secret set CPANEL_SSH_KEY    --repo "KiwiTon-Tech/$repo" --body "$CPANEL_SSH_KEY" 2>/dev/null
  gh secret set CPANEL_BASE_PATH  --repo "KiwiTon-Tech/$repo" --body "$CPANEL_BASE_PATH" 2>/dev/null
done
```

Repos that don't exist yet print errors and are skipped — re-run after each
new repo is created.

---

## Part B: one-time cPanel setup

Run **once per cPanel server**. The example uses user `kiwiton`.

### B1. Upload the GitHub App private key

From your laptop, copy the PEM contents to clipboard:

```bash
cat ~/.kiwiton-secrets/kti-deploy-bot.pem | pbcopy
```

In the cPanel web terminal:

```bash
mkdir -p ~/secrets && chmod 700 ~/secrets
cat > ~/secrets/kti-deploy-bot.pem
# paste with Cmd+V, then Ctrl+D on a new line to save
chmod 600 ~/secrets/kti-deploy-bot.pem
head -1 ~/secrets/kti-deploy-bot.pem   # must show -----BEGIN RSA PRIVATE KEY-----
```

If `head -1` shows the BEGIN line but the file is missing a trailing newline,
fix with `echo "" >> ~/secrets/kti-deploy-bot.pem`.

### B2. Save app metadata

```bash
cat > ~/secrets/kti-deploy-bot.env <<'EOF'
KTI_APP_ID=3600921
KTI_INSTALLATION_ID=129507234
KTI_PEM_PATH=/home/kiwiton/secrets/kti-deploy-bot.pem
EOF
chmod 600 ~/secrets/kti-deploy-bot.env
```

### B3. Create a Python 3.11 helper venv

CloudLinux ships Python 3.11 at `/opt/alt/python311/bin/python3.11`. Create
a dedicated venv for deploy tooling (separate from each service's venv):

```bash
PY311=/opt/alt/python311/bin/python3.11
$PY311 -m venv ~/venvs/kti-tools
~/venvs/kti-tools/bin/python -m ensurepip --upgrade
~/venvs/kti-tools/bin/pip install --upgrade pip
~/venvs/kti-tools/bin/pip install "PyJWT[crypto]==2.10.1" requests
```

### B4. Install the token-fetcher script

```bash
mkdir -p ~/bin
cat > ~/bin/kti-github-token <<'PYEOF'
#!/home/kiwiton/venvs/kti-tools/bin/python
"""Print a fresh GitHub App installation token to stdout, cached for ~55 min."""
import json, time
from pathlib import Path
import jwt
import requests

ENV_FILE = Path.home() / "secrets" / "kti-deploy-bot.env"
CACHE_FILE = Path.home() / ".cache" / "kti-github-token.json"

def load_env():
    env = {}
    for line in ENV_FILE.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

def cached_token():
    try:
        data = json.loads(CACHE_FILE.read_text())
        if data["expires_at"] - time.time() > 300:
            return data["token"]
    except Exception:
        pass
    return None

def mint_token(env):
    pem = Path(env["KTI_PEM_PATH"]).read_text()
    now = int(time.time())
    app_jwt = jwt.encode(
        {"iat": now - 60, "exp": now + 540, "iss": env["KTI_APP_ID"]},
        pem, algorithm="RS256",
    )
    r = requests.post(
        f"https://api.github.com/app/installations/{env['KTI_INSTALLATION_ID']}/access_tokens",
        headers={"Authorization": f"Bearer {app_jwt}",
                 "Accept": "application/vnd.github+json"},
        timeout=10,
    )
    r.raise_for_status()
    body = r.json()
    expires = int(time.mktime(time.strptime(body["expires_at"], "%Y-%m-%dT%H:%M:%SZ")))
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.write_text(json.dumps({"token": body["token"], "expires_at": expires}))
    CACHE_FILE.chmod(0o600)
    return body["token"]

def main():
    tok = cached_token() or mint_token(load_env())
    print(tok)

if __name__ == "__main__":
    main()
PYEOF
chmod +x ~/bin/kti-github-token

# Make sure ~/bin is on PATH
grep -q 'export PATH="$HOME/bin:$PATH"' ~/.bashrc || \
  echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/bin:$PATH"

# Smoke test
~/bin/kti-github-token | head -c 30 && echo "..."
# Expected: ghs_xxxxxxxxxxxxxxx...
```

### B5. Wire git's global credential helper

```bash
git config --global credential.https://github.com.helper '!f() {
  echo username=x-access-token
  echo password=$(~/bin/kti-github-token)
}; f'
git config --global credential.https://github.com.useHttpPath false
```

After this, **any** `git pull` against `https://github.com/KiwiTon-Tech/...`
on this server transparently uses a fresh App token.

### B6. Install the `kti-deploy` alias

```bash
cat >> ~/.bashrc <<'EOF'

kti-deploy() {
  local svc="$1"
  if [ -z "$svc" ]; then echo "usage: kti-deploy <KTI-Service-Name>"; return 1; fi
  local app_root="/home/kiwiton/apps/$svc"
  local venv="/home/kiwiton/virtualenv/apps/$svc/3.11/bin/activate"
  cd "$app_root" || return 1
  git pull && \
    source "$venv" && \
    pip install -r requirements.txt && \
    mkdir -p tmp && touch tmp/restart.txt && \
    echo "Deployed $svc"
}
EOF
source ~/.bashrc
```

---

## Part C: per-service setup

Run for every new `KTI-*` Python service (~5 min). The example uses
`KTI-NLP-Service`.

### C1. Create the cPanel Python App

cPanel → **Setup Python App** → Create:

- Python version: **3.11**
- Application root: `apps/KTI-NLP-Service` _(must match repo name exactly)_
- Application URL: `<service>.kiwiton-investments.com`
- Startup file: `passenger_wsgi.py`
- Entry point: `application`

This creates `/home/kiwiton/apps/KTI-NLP-Service/` (empty) and a virtualenv at
`/home/kiwiton/virtualenv/apps/KTI-NLP-Service/3.11/`.

### C2. Add the Cloudflare DNS record

Cloudflare → DNS → **Add record**:

| Type | Name | Content | Proxy status |
|------|------|---------|--------------|
| A | `<service>` | `<server-IP>` | **DNS only** (grey cloud) |

Internal services (`nlp`, `broker`, `market`, `news`, `ml`) **must** be
DNS-only — Cloudflare's proxy interferes with Passenger's first-load and
adds latency to service-to-service calls. Public/browser-facing subdomains
(`api`, `www`, apex) should be Proxied with a Cloudflare Origin Certificate.

### C3. Clone, configure, install

In the cPanel terminal:

```bash
SVC=KTI-NLP-Service
rm -rf /home/kiwiton/apps/$SVC
cd /home/kiwiton/apps

# First clone uses an explicit token (helper isn't invoked for the URL form),
# then we rewrite the remote so future pulls use the credential helper.
TOKEN=$(~/bin/kti-github-token)
git clone https://x-access-token:${TOKEN}@github.com/KiwiTon-Tech/$SVC.git
cd $SVC
git remote set-url origin https://github.com/KiwiTon-Tech/$SVC.git

# Configure runtime env
cp .env.example .env
chmod 600 .env
# Edit .env to set absolute paths for any cache vars (e.g. TRANSFORMERS_CACHE).
# Relative paths break under Passenger because the working directory differs.

# Install dependencies in the cPanel-managed virtualenv
source /home/kiwiton/virtualenv/apps/$SVC/3.11/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Restart Passenger
mkdir -p tmp && touch tmp/restart.txt
```

### C4. Run AutoSSL

cPanel → **SSL/TLS Status** → tick `<service>.kiwiton-investments.com` →
**Run AutoSSL**. Wait ~60s; the row should turn green.

### C5. Smoke test

```bash
curl https://<service>.kiwiton-investments.com/health
# Expected: {"status":"ok"}
```

### C6. Subsequent deploys

After every push to `main`:

```bash
kti-deploy <KTI-Service-Name>
```

---

## Known gotchas

### `a2wsgi.ASGIMiddleware` does not propagate ASGI lifespan

If your service is a FastAPI app that loads anything heavy in its `lifespan`
hook, **that hook never fires under Passenger**. Symptom: `/ready` stays at
`"loading"` forever even though the model is cached.

Fix: make your loader idempotent (call it `load_model()`) and trigger it
explicitly in `passenger_wsgi.py`:

```python
import threading
from app.main import load_model
threading.Thread(target=load_model, daemon=True).start()
```

The `lifespan` hook can also call `load_model()` so direct `uvicorn` runs
still work in development.

### Empty `.env` silently uses defaults

cPanel's "Setup Python App" sets some env vars but **does not** create
`.env`. If your app uses `pydantic-settings` or `python-dotenv`, missing
files silently fall back to in-code defaults. Always `cp .env.example .env`
during per-service setup and verify with `cat .env`.

### Cloudflare proxy + AutoSSL conflict

If a subdomain is **Proxied** (orange cloud), AutoSSL's HTTP-01 challenge
hits Cloudflare's edge instead of cPanel and fails with a `404`. Either:

1. Switch to **DNS only** (grey cloud) for that subdomain (recommended for
   internal services), or
2. Use a Cloudflare **Origin Certificate** instead of AutoSSL for browser-
   facing public domains, with Cloudflare SSL/TLS mode set to **Full (strict)**.

### CloudLinux LVE memory limits

FinBERT alone uses ~500 MB resident. Some services may approach the LVE
default cap. Check with `free -m` and bump the **Physical Memory Limit (PMEM)**
in CloudLinux Manager → Resource Usage if needed.

### System Python 3.6 is the default `python3`

Don't run helper scripts with bare `python3` — it resolves to Python 3.6
which is too old for modern crypto deps. Always shebang to
`/home/kiwiton/venvs/kti-tools/bin/python` (helper scripts) or the app's
own venv (services).

---

## Rotating the GitHub App key

When you need to rotate (annually, or after suspected compromise):

1. GitHub App settings → **Generate a new private key**.
2. On cPanel: replace `~/secrets/kti-deploy-bot.pem` with the new contents.
3. Delete the old key from GitHub.
4. Clear the cache: `rm -f ~/.cache/kti-github-token.json`.
5. Verify: `~/bin/kti-github-token | head -c 30 && echo "..."`.

The App ID and Installation ID **do not change** during key rotation.
