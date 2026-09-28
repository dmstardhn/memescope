# MemeScope â€” Production Checklist

## Required before public launch

1. Replace public Solana RPC with a private production RPC.
2. Configure both HTTP and WebSocket endpoints:
   - `SOLANA_RPC_URL`
   - `SOLANA_WSS_URL`
3. Keep all secret keys server-side only.
4. Run:
   ```powershell
   npm run check
   ```
5. Deploy only if lint, TypeScript, and production build all pass.

## Optional

AI Analyst:
```text
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna
```

Pump live stream:
```text
PUMPPORTAL_API_KEY=
```

## Vercel

Add the environment variables in the project settings, then deploy the repository.

Recommended production command is the default:

```text
npm run build
npm run start
```

## Product disclaimer

MemeScope should describe scores and AI output as research signals, not guaranteed safety, return forecasts, or investment recommendations.
