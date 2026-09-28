# MemeScope Stage 17 — Telegram Bot + Signal Channel

Stage 17 connects the Stage 16 HQ Signal Engine to Telegram.

## Included

- Automatic HQ Signal posts to a Telegram channel
- Anti-duplicate server-side message tracking in Neon
- Live channel-message refresh when gain / max gain / drawdown materially changes
- Original channel post is updated when TP is hit
- One TARGET HIT reply is sent when TP is reached
- Telegram bot webhook
- `/signals`
- `/history`
- `/stats`
- `/token <CA>`
- `/risk <CA>`
- `/channel`
- `/help`
- Secure Telegram webhook secret
- Protected bootstrap/test/cron endpoints
- Cron-ready server route for 24/7 operation

Existing signal history is baselined during setup so the channel is not flooded with old signals.

## Required Vercel Environment Variables

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHANNEL_ID=@your_public_channel
TELEGRAM_CHANNEL_URL=https://t.me/your_public_channel
TELEGRAM_WEBHOOK_SECRET=...
CRON_SECRET=...
```

`TELEGRAM_CHANNEL_URL` is optional.

For a public channel, `TELEGRAM_CHANNEL_ID=@username` is simplest.
For a private channel, use the numeric Telegram chat/channel id.

Never commit the bot token or secrets to Git.

## Telegram setup

1. Create the bot using `@BotFather`.
2. Create your signal channel.
3. Add the bot as an administrator of the channel.
4. Give it permission to post and edit messages.
5. Add the environment variables to Vercel Production.
6. Redeploy MemeScope.

Then bootstrap the bot from PowerShell:

```powershell
$secret = Read-Host "CRON_SECRET"
curl.exe -X POST `
  -H "Authorization: Bearer $secret" `
  "https://memescopes.vercel.app/api/telegram/bootstrap"
```

Check status:

```powershell
curl.exe -s "https://memescopes.vercel.app/api/telegram/status"
```

Send a channel test:

```powershell
$secret = Read-Host "CRON_SECRET"
curl.exe -X POST `
  -H "Authorization: Bearer $secret" `
  "https://memescopes.vercel.app/api/telegram/test"
```

## 24/7 recorder

The installer adds:

`GET /api/telegram/cron`

It securely runs the Signal Recorder, which now also runs the Telegram publisher.

Do not add an aggressive Vercel cron schedule blindly.

As of September 2026, Vercel documents frequent cron execution (down to once per minute) for Pro/Enterprise, while Hobby cron execution is limited to daily scheduling. If you are on Pro, a `vercel.json` example is included for one-minute recording. If you are on Hobby, use an external scheduler or another background runtime if you need true 24/7 minute-level monitoring.

## Safety note

MemeScope Signal Score and Potential TP are heuristic analytics, not guaranteed returns. Telegram performance statistics are historical observations, not future probabilities.
