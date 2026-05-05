# KiwiTon-Tech (`KTI`)

Internal repository hub for the **KiwiTon Investments** trading platform.

This repository hosts:

- **Reusable GitHub Actions workflows** consumed by every other `KTI-*`
  repository — see `.github/workflows/`.
- Default issue / pull-request templates (TBD).

> Note: this repo is named `KTI-.github` (with prefix) for naming consistency
> with the rest of the suite. Because of that, GitHub does **not** render
> any `profile/README.md` here as the org landing page. If an org profile is
> ever wanted, create a separate repo named exactly `.github`.

## Service Catalog

| Repo | Purpose |
|------|---------|
| [`KTI-Gateway`](https://github.com/KiwiTon-Tech/KTI-Gateway) | Public BFF (Next.js) |
| [`KTI-Broker-Service`](https://github.com/KiwiTon-Tech/KTI-Broker-Service) | Alpaca adapter |
| [`KTI-Market-Data-Service`](https://github.com/KiwiTon-Tech/KTI-Market-Data-Service) | Bars, quotes, WS streams |
| [`KTI-NLP-Service`](https://github.com/KiwiTon-Tech/KTI-NLP-Service) | finBERT sentiment inference |
| [`KTI-News-Sentiment-Service`](https://github.com/KiwiTon-Tech/KTI-News-Sentiment-Service) | News scraper + sentiment pipeline |
| [`KTI-ML-Service`](https://github.com/KiwiTon-Tech/KTI-ML-Service) | Signal models, training, prediction |
| [`KTI-Strategy-Engine`](https://github.com/KiwiTon-Tech/KTI-Strategy-Engine) | Live trading bots |
| [`KTI-Backtest-Service`](https://github.com/KiwiTon-Tech/KTI-Backtest-Service) | Backtest job queue + workers |
| [`KTI-Orchestrator`](https://github.com/KiwiTon-Tech/KTI-Orchestrator) | Strategy control plane (optional) |
| [`KTI-Observability`](https://github.com/KiwiTon-Tech/KTI-Observability) | Prometheus + Grafana + ELK config |
| [`KTI-DB-Migrations`](https://github.com/KiwiTon-Tech/KTI-DB-Migrations) | Postgres schema |
| [`KTI-Contracts`](https://github.com/KiwiTon-Tech/KTI-Contracts) | OpenAPI specs + generated clients |
| [`KTI-Platform`](https://github.com/KiwiTon-Tech/KTI-Platform) | Local dev orchestration (Procfile / honcho) |

## Deployment Model

**Deployments are pulled by cPanel, not pushed by GitHub Actions.** Most
shared cPanel hosts (including the production `t-4.net` host) block inbound
SSH, so the rsync-from-CI pattern doesn't work. We use the inverse: the
cPanel server uses a **GitHub App** (`KTI-Deploy-Bot`) to mint a short-lived
installation token and `git pull` directly from GitHub.

Full setup playbook (one-time per cPanel server, ~15 min):
[`docs/CPANEL_DEPLOYMENT.md`](./docs/CPANEL_DEPLOYMENT.md).

Per-service setup (~5 min per repo): see each service's own README.

## Reusable CI Workflows

GitHub Actions still runs **lint + tests** on every push and pull request
(deploys are handled by the cPanel pull described above).

Other repos consume these via `uses:` — note the `KTI-.github` repo path,
not `.github`:

```yaml
jobs:
  ci:
    uses: KiwiTon-Tech/KTI-.github/.github/workflows/python-cpanel.yml@main
    with:
      app_path: /home/kiwiton/apps/KTI-NLP-Service
      python_version: "3.11"
      passenger_app: true
      run_tests: true
    secrets: inherit
```

Available workflows:

- `python-cpanel.yml` — lint + test for Python services.
- `node-cpanel.yml` — lint + test + build for Next.js services.

The `deploy`/`rsync` steps inside these workflows still exist for hosts that
do allow inbound SSH, but are not used by the production `t-4.net` cPanel.

## Free-plan Secret Strategy

GitHub Free **disallows org-level secrets on private repos**. Workaround:

- Each repo's CI secrets are stored at the **repo level**, not the org level.
- A small bash loop (using the `gh` CLI) seeds all 13 repos in one shot —
  see `docs/CPANEL_DEPLOYMENT.md`.
- Runtime secrets (`SHARED_AUTH_TOKEN`, `ALPACA_KEY`, etc.) live in **cPanel
  environment variables** per app, never in GitHub.

## Required Org Settings

- **Org → Settings → Member privileges** → Deploy keys: **Allowed** (GitHub
  Apps + deploy keys are both used).
- **Org → Settings → Actions → General** → "Allow all actions and reusable
  workflows".
- **`KTI-.github` repo** → visibility: **public** (so private repos can
  consume the reusable workflows without GitHub Team).

## Architecture

See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the full service
breakdown, communication flows, data model, and rollout plan.

## Documents in this repo

- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — service catalog, topology,
  communication patterns, rollout plan.
- [`docs/CPANEL_DEPLOYMENT.md`](./docs/CPANEL_DEPLOYMENT.md) — end-to-end
  cPanel setup playbook (GitHub App, token helper, per-service deploy).
