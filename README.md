# KiwiTon-Tech (`KTI`)

Internal repository hub for the **KiwiTon Investments** trading platform.

This `.github` repository hosts:

- The organization profile shown at <https://github.com/KiwiTon-Tech>
  (see `profile/README.md`).
- **Reusable GitHub Actions workflows** consumed by every other `KTI-*`
  repository — see `.github/workflows/`.
- Default issue / pull-request templates.

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

## Reusable Workflows

Other repos consume these via `uses:`:

```yaml
jobs:
  ci:
    uses: KiwiTon-Tech/.github/.github/workflows/python-cpanel.yml@main
    with:
      app_path: /home/<cpanel-user>/apps/broker-service
      python_version: "3.11"
    secrets: inherit
```

Available workflows:

- `python-cpanel.yml` — lint + test + rsync deploy + Passenger restart for Python services.
- `node-cpanel.yml` — lint + test + build + rsync deploy + Passenger restart for Next.js services.

## Org-Level Secrets (configure once)

Set at <https://github.com/organizations/KiwiTon-Tech/settings/secrets/actions>:

| Secret | Purpose |
|--------|---------|
| `CPANEL_HOST` | cPanel server hostname |
| `CPANEL_USER` | SSH username |
| `CPANEL_SSH_KEY` | Private SSH key (Ed25519) |
| `CPANEL_BASE_PATH` | e.g. `/home/<user>/apps` |

The matching public key must be authorized in cPanel → SSH Access.

## Architecture

See `MICROSERVICES_ARCHITECTURE.md` in the root planning workspace for the
full service breakdown, communication flows, and rollout plan.
