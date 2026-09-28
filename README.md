# MemeScope / Memecoin Analyst

Foundation build generated automatically from PowerShell.

## Included

- Next.js + TypeScript + Tailwind
- Dark analytics dashboard
- Mock memecoin scanner
- Chain and risk filters
- Token detail page
- Watchlist page
- Alert-rule UI
- Settings/integration status page
- Live Dexscreener search through `/api/dex/search`
- `/api/health` endpoint

## Run

```powershell
npm run dev
```

Then open:

```text
http://localhost:3000
```

## Next build stages

1. Replace demo score with real scoring engine.
2. Add new-pair ingestion and caching.
3. Connect Solana RPC risk analysis.
4. Add holder concentration / mint / freeze / LP checks.
5. Add deployer-wallet intelligence.
6. Add watchlist persistence + authentication.
7. Add Telegram alerts.
8. Add AI-generated explanation layer.
9. Add billing and Free/Pro limits.

Scores in v0.1 are demo analytics only and are not investment advice.
