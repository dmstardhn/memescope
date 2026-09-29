# MemeScope Live Call Intelligence

This update turns MemeScope calls into a tracked public history and content workflow.

## Public Telegram behavior

- NEW CALL is posted once and is never edited.
- Silent tracking continues in the background.
- Public milestone posts are limited to 2X, 5X and 10X+.
- If a call jumps across several milestones between checks, only the highest newly reached milestone is posted.
- 20X, 50X and 100X are not added to the public milestone ladder; they become private Content HQ opportunities.
- Daily Tape is posted once per day after 23:00 in the report timezone.
- Weekly Intelligence is posted on Sunday after 23:00.
- Default report timezone is `Asia/Jakarta`; optional override: `MEMESCOPE_REPORT_TIMEZONE`.

## Website

- `/calls` — Hall of Calls + 30-day public statistics + recent call history.
- `/calls/[publicId]` — complete Call Journey.
- `/api/calls/[publicId]/card?mode=journey` — shareable Journey Card (SVG).
- `/api/calls/[publicId]/card?mode=before` — shareable Before The Move card (SVG).

## Private Content HQ

1. Create a private Telegram group named e.g. `MemeScope — Content HQ`.
2. Add the existing MemeScope bot to the group.
3. From the owner Telegram account, send `/bindcontenthq` inside that group.
4. Check with `/contenthq`.

The group receives high-value content opportunities, suggested X hooks and links to generated cards. It does **not** automatically post to X.

## Content opportunities

- Fast 2X (within 60 minutes): medium priority.
- 5X: high priority.
- 10X: featured.
- 20X / 50X / 100X: special-story candidates, private to Content HQ.

## Not included by request

- No X auto-publishing.
- No trade page / trading-bot execution integration.

## After install

```powershell
npm run typecheck
npm run build
git add src
git commit -m "Add MemeScope Live Call Intelligence"
git push
npx vercel@latest deploy --prod --force
powershell -ExecutionPolicy Bypass -File ".\bootstrap-telegram.ps1"
```

Then create/bind Content HQ and open `/calls` on production.
