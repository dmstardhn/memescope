# MemeScope Content HQ Blueprint V3

This stage applies the final visual blueprint while preserving the existing queue, preview, scheduler, Telegram and X-publishing foundation.

Implemented:

- 1600x900 output.
- 6 DEX layouts.
- 6 GMGN layouts.
- 12 MemeScope layouts.
- Template rotation based on queue history.
- No consecutive visual reuse when alternatives exist.
- DEX real screenshot first, deterministic fallback when Cloudflare blocks it.
- GMGN real screenshot first.
- GMGN always has an image; if the server browser cannot access GMGN, MemeScope creates a clearly labeled fallback and does not fabricate wallet/holder values.
- MemeScope source now has multiple layouts, including Before The Move, Runner, Call Journey, Weekly and Hall of Calls.
- Added smart_money, call_journey and hall_of_calls content types.
- Existing text-only flow remains unchanged.
- Large multi-platform demo matrix expanded.
- Visual template registry at /content-hq/visuals.

Important limitation:

Production wallet/holder/smart-money events must still come from trustworthy numeric wallet/holder data. This visual stage does not invent those signals. Demo mode may exercise the visual types without publishing them to X.

No AI is used.