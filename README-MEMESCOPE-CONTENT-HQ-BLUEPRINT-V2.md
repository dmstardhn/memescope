# MemeScope Content HQ Blueprint V2

This system follows a deterministic, zero-AI content workflow.

Flow:

Market Data
-> MemeScope Engine
-> Event Detector
-> Rule Engine
-> Content Eligibility
-> Content Type
-> Source Selector
-> Screenshot Engine
-> Annotation Engine
-> Caption Template Engine
-> Duplicate Check
-> Content Queue
-> Preview / Approval
-> Scheduler
-> X API
-> Content History

Visual policy:

- 1600x900 landscape.
- Raw trader-content look.
- DEX Screener is the default visual source.
- GMGN is available for holder / wallet content.
- MemeScope is used as a subtle first-party source.
- Text-only posts remain supported.
- No TradingView.
- No AI image generation.
- No AI caption generation.
- No AI source selection.
- No cyber-neon poster cards.
- No large marketing headlines.
- Annotation is simple and programmatic.

Default rules:

- Runner: +100%.
- Big Runner: +300%.
- Moonshot: +500%.
- Before The Move: +150%.
- Min liquidity: $20K.
- Max token age: 72h.
- Token cooldown: 4h, except a new milestone.
- Max posts/day: 5.
- Minimum gap: 40m.
- Manual approval: ON.

Content source target mix:

- DEX Screener: 60%.
- GMGN: 20%.
- MemeScope: 10%.
- Text only: 10%.

The source percentages are targets, not forced quotas.

Dashboard:

/content-hq

Dashboard mutation actions require CONTENT_HQ_ADMIN_KEY.
If CONTENT_HQ_ADMIN_KEY is absent, CRON_SECRET is accepted as the owner key.

X publishing is optional until these production variables exist:

X_API_KEY
X_API_SECRET
X_ACCESS_TOKEN
X_ACCESS_SECRET

Content HQ can run and generate Telegram previews without X credentials.