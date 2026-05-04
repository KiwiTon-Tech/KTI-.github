# KiwiTon Investments

Algorithmic trading platform — stocks, crypto, and forex — combining
machine-learning signal classification with FinBERT news sentiment.

## Architecture

KiwiTon is built as a polyrepo of focused microservices. Each service is
independently deployable to cPanel/CloudLinux with its own CI/CD pipeline.

```
Frontend ─▶ KTI-Gateway ─┬─▶ KTI-Broker-Service       (Alpaca)
                         ├─▶ KTI-Market-Data-Service  (REST + WS)
                         ├─▶ KTI-News-Sentiment-Svc ─▶ KTI-NLP-Service
                         ├─▶ KTI-ML-Service
                         └─▶ KTI-Strategy-Engine ◀──┐
                                                    ├ KTI-Backtest-Service
                                                    └ KTI-Orchestrator
```

## Stack

- **Backend**: Python 3.11 (FastAPI), TypeScript (Next.js 14)
- **Data**: PostgreSQL, Redis (Upstash), S3-compatible storage
- **ML**: FinBERT, XGBoost, scikit-learn
- **Broker**: Alpaca (paper + live)
- **Deploy**: cPanel / CloudLinux + Phusion Passenger
- **CI/CD**: GitHub Actions → SSH/rsync
