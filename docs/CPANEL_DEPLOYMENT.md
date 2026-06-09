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

### C1. Add the Cloudflare DNS record

Cloudflare → DNS → **Add record**:

| Type | Name | Content | Proxy status |
|------|------|---------|--------------|
| A | `<service>` | `<server-IP>` | **DNS only** (grey cloud) |

Internal services (`nlp`, `broker`, `market`, `news`, `ml`) **must** be
DNS-only. Cloudflare's proxy silently times out long-running POSTs (e.g.
a FinBERT batch), which breaks service-to-service pipelines. Only public /
browser-facing subdomains (`api`, `www`, apex) should be Proxied with a
Cloudflare Origin Certificate.

### C2. Create the cPanel Python App

cPanel → **Setup Python App** → Create:

- Python version: **3.11**
- Application root: `apps/KTI-NLP-Service` _(must match repo name exactly)_
- Application URL: `<service>.kiwiton-investments.com`
- Startup file: `passenger_wsgi.py`
- Entry point: `application`

This creates `/home/kiwiton/apps/KTI-NLP-Service/` (with cPanel's placeholder
files) and a virtualenv at `/home/kiwiton/virtualenv/apps/KTI-NLP-Service/3.11/`.

> ⚠ **cPanel overwrites `passenger_wsgi.py`** with a generic
> `imp.load_source(...)` template that recursively imports itself and causes
> an infinite-recursion crash on boot. C3 below restores the real file from
> git immediately after clone.

### C3. Clone, configure, install

In the cPanel terminal:

```bash
SVC=KTI-NLP-Service

# 1. Remove cPanel's placeholder app directory (keep the venv)
rm -rf /home/kiwiton/apps/$SVC

# 2. Clone the repo (uses the GitHub App token helper)
cd /home/kiwiton/apps
TOKEN=$(~/bin/kti-github-token)
git clone https://x-access-token:${TOKEN}@github.com/KiwiTon-Tech/$SVC.git
cd $SVC
git remote set-url origin https://github.com/KiwiTon-Tech/$SVC.git

# 3. Force-restore OUR passenger_wsgi.py in case cPanel re-plants its template
#    between now and the Passenger restart. Safe no-op if already correct.
git checkout -- passenger_wsgi.py
head -5 passenger_wsgi.py   # must show OUR docstring, not "imp.load_source"

# 4. Configure runtime env
cp .env.example .env
chmod 600 .env
# Edit .env for THIS service's values. Use ABSOLUTE paths for any cache vars
# (e.g. TRANSFORMERS_CACHE) — relative paths break under Passenger because
# the working directory shifts. Use ``NODE_ENV=production`` and
# ``PROD_DATABASE_URI=postgresql://...@localhost:5432/...?sslmode=disable``
# if the service uses KTI-DB.

# 5. Install dependencies in the cPanel-managed virtualenv
source /home/kiwiton/virtualenv/apps/$SVC/3.11/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# 6. Smoke-test the import path BEFORE hitting Passenger (shows real errors)
python passenger_wsgi.py    # should exit silently; any traceback is a real bug

# 7. Restart Passenger
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

### cPanel overwrites `passenger_wsgi.py`

Creating a Python App in cPanel **replaces** your `passenger_wsgi.py` with
a generic template that does
`imp.load_source('wsgi', 'passenger_wsgi.py')` — which recursively imports
itself on boot and crashes with `RecursionError`. Symptom: browser shows
"We're sorry, but something went wrong: Web application could not be started."

Fix: `git checkout -- passenger_wsgi.py` right after the clone (step C3
already does this). Re-run after any future cPanel UI edit to the app.

### `.env` doesn't reach `os.getenv()` readers

Pydantic-settings reads `.env` into its model but does **not** populate
`os.environ`. Dependencies like `kti_db.connection` use `os.getenv()`
directly, so without an explicit `load_dotenv()` they see empty values and
fail with "Database not configured".

Fix: load `.env` at the top of `passenger_wsgi.py` before any app imports:

```python
from dotenv import load_dotenv
load_dotenv(os.path.join(APP_ROOT, ".env"))
```

### Pydantic-settings `list[T]` / `dict[T]` JSON decode

Pydantic-settings tries JSON-decoding env values for non-scalar fields
**before** `@field_validator` runs. A CSV env var raises `SettingsError`
at boot. Annotate with `NoDecode` to keep the raw string:

```python
from typing import Annotated
from pydantic_settings import NoDecode
rss_feeds: Annotated[list[FeedSpec], NoDecode] = Field(default_factory=list)
```

### Passenger swallows stderr

Don't hunt for log files. The fastest way to get a real traceback:

```bash
source /home/kiwiton/virtualenv/apps/$SVC/3.11/bin/activate
cd /home/kiwiton/apps/$SVC
python passenger_wsgi.py   # crashes print inline
```

### `CREATE EXTENSION` fails on shared Postgres

cPanel Postgres doesn't grant superuser, so extensions like `uuid-ossp` and
`pgcrypto` can't be created with `CREATE EXTENSION`. Use built-ins:

- `gen_random_uuid()` (PG 13+) instead of `uuid_generate_v4()` (uuid-ossp).
- `md5()` / `encode(digest(...))` are available without pgcrypto in most
  managed installs.

### Migration-runner atomicity

If a migration runner puts all files in one transaction, a late failure
rolls back successful earlier migrations. Use **per-file commits** so
partial progress is preserved. `kti_db.connection.run_migrations()`
already does this.

---

## Rotating the GitHub App key

When you need to rotate (annually, or after suspected compromise):

1. GitHub App settings → **Generate a new private key**.
2. On cPanel: replace `~/secrets/kti-deploy-bot.pem` with the new contents.
3. Delete the old key from GitHub.
4. Clear the cache: `rm -f ~/.cache/kti-github-token.json`.
5. Verify: `~/bin/kti-github-token | head -c 30 && echo "..."`.

The App ID and Installation ID **do not change** during key rotation.

---

## Part D: service-specific notes

### KTI-Strategy-Engine

| Field | Value |
|-------|-------|
| Repo | `KiwiTon-Tech/KTI-Strategy-Engine` |
| Application root | `apps/KTI-Strategy-Engine` |
| Application URL | `engine.kiwiton-investments.com` |
| Startup file | `passenger_wsgi.py` |
| Entry point | `application` |
| Python version | 3.11 |
| DNS type | A — **DNS only** (grey cloud) |

**Full per-service setup (Part C) for this service:**

```bash
SVC=KTI-Strategy-Engine

# C1: Cloudflare DNS — add A record: engine → <server-IP>, DNS only
# C2: cPanel → Setup Python App → create with values above

# C3: Clone, configure, install
rm -rf /home/kiwiton/apps/$SVC
cd /home/kiwiton/apps
TOKEN=$(~/bin/kti-github-token)
git clone https://x-access-token:${TOKEN}@github.com/KiwiTon-Tech/$SVC.git
cd $SVC
git remote set-url origin https://github.com/KiwiTon-Tech/$SVC.git
git checkout -- passenger_wsgi.py
head -5 passenger_wsgi.py   # must show OUR docstring, not "imp.load_source"

cp .env.example .env
chmod 600 .env
# Set SHARED_AUTH_TOKEN, TOTAL_CAPITAL, LOG_LEVEL in .env

source /home/kiwiton/virtualenv/apps/$SVC/3.11/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

python passenger_wsgi.py    # should exit silently
mkdir -p tmp && touch tmp/restart.txt
```

**C4:** cPanel → SSL/TLS Status → Run AutoSSL for `engine.kiwiton-investments.com`

**C5 Smoke test:**

```bash
curl https://engine.kiwiton-investments.com/health
# Expected: {"status":"ok"}

curl https://engine.kiwiton-investments.com/ready
# Expected: {"status":"ready","orchestrator_initialised":true}

# Authenticated (requires X-KTI-Token header):
curl -H "X-KTI-Token: <SHARED_AUTH_TOKEN>" https://engine.kiwiton-investments.com/orchestrator/status
# Expected: {"running":false,"kill_switch_active":false,"strategy_count":0,...}
```

**C6 Subsequent deploys:**

```bash
kti-deploy KTI-Strategy-Engine
```

**`.env` keys required on cPanel:**

```
SHARED_AUTH_TOKEN=<copy to KTI-Gateway as STRATEGY_ENGINE_SERVICE_TOKEN>
TOTAL_CAPITAL=100000.0
ORCHESTRATOR_CONFIG_PATH=   # leave blank to use config/orchestrator.yaml default
LOG_LEVEL=INFO
```

> ⚠️ Copy `SHARED_AUTH_TOKEN` from this service's `.env` into the **KTI-Gateway** `.env`
> as `STRATEGY_ENGINE_SERVICE_TOKEN` so the gateway can authenticate its proxy calls.

### KTI-Backtest-Service

| Field | Value |
|-------|-------|
| Repo | `KiwiTon-Tech/KTI-Backtest-Service` |
| Application root | `apps/KTI-Backtest-Service` |
| Application URL | `backtest.kiwiton-investments.com` |
| Startup file | `passenger_wsgi.py` |
| Entry point | `application` |
| Python version | 3.11 |
| DNS type | A — **DNS only** (grey cloud) |

> **Consumes a private package.** `requirements.txt` pulls the shared
> strategy classes via
> `git+https://github.com/KiwiTon-Tech/KTI-Strategies.git@main#egg=kti-strategies`.
> Because `KTI-Strategies` is **private**, `pip install` must be able to
> authenticate to GitHub:
>
> - **On cPanel** — the global git credential helper from **B5** injects a
>   fresh App token, so `pip install -r requirements.txt` clones it
>   transparently. No extra step.
> - **In CI** — the reusable workflow's "Configure git auth for private
>   GitHub deps" step needs the `GH_DEPS_TOKEN` repo secret set (see
>   ARCHITECTURE.md §8). Without it the `git+https` clone 404s.

> **`thetadata` pin.** `lumibot==3.8.16` hard-depends on `thetadata`, whose
> only py3.11-compatible releases are yanked on PyPI (the non-yanked 1.x
> line requires py3.12). `requirements.txt` therefore pins
> `thetadata==0.9.11` **before** `lumibot` — pip installs a yanked version
> when pinned with `==`. Keep this in lockstep with
> `KTI-Strategies/requirements.txt`. Removing the pin breaks every fresh
> install on Python 3.11.

**Full per-service setup (Part C) for this service:**

```bash
SVC=KTI-Backtest-Service

# C1: Cloudflare DNS — add A record: backtest → <server-IP>, DNS only
# C2: cPanel → Setup Python App → create with values above

# C3: Clone, configure, install
rm -rf /home/kiwiton/apps/$SVC
cd /home/kiwiton/apps
TOKEN=$(~/bin/kti-github-token)
git clone https://x-access-token:${TOKEN}@github.com/KiwiTon-Tech/$SVC.git
cd $SVC
git remote set-url origin https://github.com/KiwiTon-Tech/$SVC.git
git checkout -- passenger_wsgi.py
head -5 passenger_wsgi.py   # must show OUR docstring, not "imp.load_source"

cp .env.example .env
chmod 600 .env
# Set SHARED_AUTH_TOKEN, PROD_DATABASE_URI, LOG_LEVEL (+ optional POLYGON_API_KEY) in .env

source /home/kiwiton/virtualenv/apps/$SVC/3.11/bin/activate
pip install --upgrade pip
pip install -r requirements.txt   # private KTI-Strategies clone uses the B5 helper

python passenger_wsgi.py    # should exit silently
mkdir -p tmp && touch tmp/restart.txt
```

**C4:** cPanel → SSL/TLS Status → Run AutoSSL for `backtest.kiwiton-investments.com`

**C5 Smoke test:**

```bash
curl https://backtest.kiwiton-investments.com/health
# Expected: {"status":"ok"}

curl https://backtest.kiwiton-investments.com/ready
# Expected: {"status":"ready","detail":null,"db_configured":true,"db_reachable":true}
# (status "degraded" with a detail string if PROD_DATABASE_URI is unset or Postgres is unreachable)

# Authenticated (requires X-KTI-Token header):
curl -H "X-KTI-Token: <SHARED_AUTH_TOKEN>" https://backtest.kiwiton-investments.com/strategies
# Expected: JSON catalogue including sma_crossover, mltrader, cryptotrader, forextrader
```

**Worker cron (required — the API only enqueues jobs):**

Backtests run out-of-process. Add a cron entry (cPanel → Cron Jobs) that
spawns one ephemeral worker per tick. One entry per concurrency slot
(cap is `MAX_CONCURRENT_BACKTESTS`, default 2):

```cron
* * * * * cd /home/kiwiton/apps/KTI-Backtest-Service && /home/kiwiton/virtualenv/apps/KTI-Backtest-Service/3.11/bin/python -m app.worker --max-jobs 1 >> ~/logs/backtest-worker.log 2>&1
```

Each tick claims at most one queued job (`SELECT ... FOR UPDATE SKIP
LOCKED`), runs it, persists the result, and exits — no long-running
daemon. Verify with `python -m app.worker --check` (loads config, exits 0).

**C6 Subsequent deploys:**

```bash
kti-deploy KTI-Backtest-Service
```

**`.env` keys required on cPanel:**

```
SHARED_AUTH_TOKEN=<copy to KTI-Gateway as BACKTEST_SERVICE_TOKEN>
PROD_DATABASE_URI=postgresql://...@localhost:5432/...?sslmode=disable
LOG_LEVEL=INFO
# Optional — improves stock-data accuracy; crypto/forex fall back to Yahoo:
POLYGON_API_KEY=
# Optional worker/concurrency tunables (defaults shown):
# WORKER_MAX_JOBS=1
# WORKER_MAX_RUNTIME_SECONDS=290
# MAX_CONCURRENT_BACKTESTS=2
```

> ⚠️ Copy `SHARED_AUTH_TOKEN` into the **KTI-Gateway** `.env` as
> `BACKTEST_SERVICE_TOKEN` so the gateway can authenticate its proxy calls.

---

## Part E: shared packages (not deployed)

Some `KTI-*` repos are **pip packages, not services** — they ship Python
code that other services `import` in-process, so they are consumed via
`git+https` rather than rsynced to cPanel and run under Passenger.

### KTI-Strategies

| Field | Value |
|-------|-------|
| Repo | `KiwiTon-Tech/KTI-Strategies` (private) |
| Type | pip package (`kti-strategies`) |
| Consumed by | `KTI-Backtest-Service`, `KTI-Strategy-Engine` |
| cPanel app? | **No** — never deployed, no Passenger, no venv of its own |
| DNS / AutoSSL? | None |

Holds the production Lumibot `Strategy` subclasses (`MLTrader`,
`CryptoTrader`, `ForexTrader`). Lumibot needs the actual class object to
run, so the code is shared as a package — you cannot put a `Strategy`
behind HTTP. Consumers pin it in `requirements.txt`:

```txt
git+https://github.com/KiwiTon-Tech/KTI-Strategies.git@main#egg=kti-strategies
```

**CI:** uses the same reusable `python-cpanel.yml` but with
`deploy_enabled: false`, so only the lint + test job runs — the deploy /
rsync / Passenger-restart job is skipped entirely. `app_path` and
`passenger_app` are intentionally omitted.

> ⚠️ **Never** give a package repo a real `app_path`. The `deploy` job runs
> `rsync -avz --delete ./ …:<app_path>/`, so a stray `app_path` pointing at
> another service's directory would **wipe that live service** on the next
> push to `main`. Package repos must set `deploy_enabled: false`.

**Releasing a change** (no deploy step — consumers pull on their next
install):

1. Merge to `main` in `KTI-Strategies`.
2. Bump the version pin (or re-pin `@main`) in each consumer's
   `requirements.txt`.
3. Redeploy the **consumers** (`kti-deploy KTI-Backtest-Service`, etc.) —
   their `pip install -r requirements.txt` re-clones the updated package
   using the B5 credential helper.

> **`deploy_enabled` toggle.** Added to `python-cpanel.yml` for exactly this
> case: `true` (default) keeps the full lint→test→deploy pipeline for
> services; `false` runs lint+test only for package repos. The cPanel
> secrets (`CPANEL_HOST`/`USER`/`SSH_KEY`) are optional at the workflow
> contract level so a package repo without them can still call the workflow.
