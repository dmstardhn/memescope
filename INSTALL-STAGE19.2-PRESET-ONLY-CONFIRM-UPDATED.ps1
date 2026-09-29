$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 19.2 - Preset Only Telegram Control" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$settingsPath = Join-Path $root "src/lib/signal-engine-settings.ts"
$recorderPath = Join-Path $root "src/lib/signal-recorder-db.ts"
$recordRoutePath = Join-Path $root "src/app/api/signals/record/route.ts"
$telegramPath = Join-Path $root "src/lib/telegram.ts"
$webhookPath = Join-Path $root "src/app/api/telegram/webhook/route.ts"
$bootstrapPath = Join-Path $root "src/app/api/telegram/bootstrap/route.ts"

$required = @(
  $settingsPath,
  $recorderPath,
  $recordRoutePath,
  $telegramPath,
  $webhookPath,
  $bootstrapPath
)

foreach ($path in $required) {
  if (!(Test-Path -LiteralPath $path)) {
    throw "Required file not found: $path"
  }
}

# Read everything before writing anything.
$recorder = [System.IO.File]::ReadAllText($recorderPath)
$telegram = [System.IO.File]::ReadAllText($telegramPath)
$bootstrap = [System.IO.File]::ReadAllText($bootstrapPath)

if (!$recorder.Contains("Stage 16: two-scan confirmation.")) {
  throw "Stage 16 confirmation block not found. No files were changed."
}

if (
  !$bootstrap.Contains("telegramSetWebhook") -or
  !$bootstrap.Contains("telegramSetCommands")
) {
  throw "Telegram bootstrap route is not compatible. No files were changed."
}

# ============================================================
# 1. PREPARE DYNAMIC CONFIRMATION PATCH
# ============================================================

$patchedRecorder = $recorder

$signaturePattern = '(?s)export async function recordSignalSnapshot\(\s*tokens:\s*TerminalToken\[\],\s*signals:\s*SignalCall\[\],\s*\)\s*\{'
$signatureReplacement = @'
export async function recordSignalSnapshot(
  tokens: TerminalToken[],
  signals: SignalCall[],
  confirmationScans = 1,
) {
'@

if (![regex]::IsMatch($patchedRecorder, $signaturePattern)) {
  throw "recordSignalSnapshot signature not found. No files were changed."
}

$patchedRecorder = [regex]::Replace(
  $patchedRecorder,
  $signaturePattern,
  $signatureReplacement,
  1
)

$stateSchemaPattern = '(?s)await sql`\s*CREATE TABLE IF NOT EXISTS memescope_signal_state \(\s*signal_id TEXT PRIMARY KEY,\s*visible BOOLEAN NOT NULL DEFAULT FALSE,\s*armed BOOLEAN NOT NULL DEFAULT TRUE,\s*updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW\(\)\s*\)\s*`;'

$stateSchemaReplacement = @'
await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_state (
        signal_id TEXT PRIMARY KEY,
        visible BOOLEAN NOT NULL DEFAULT FALSE,
        armed BOOLEAN NOT NULL DEFAULT TRUE,
        confirmation_count INTEGER NOT NULL DEFAULT 0,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      ALTER TABLE memescope_signal_state
      ADD COLUMN IF NOT EXISTS confirmation_count INTEGER NOT NULL DEFAULT 0
    `;
'@

if (![regex]::IsMatch($patchedRecorder, $stateSchemaPattern)) {
  throw "memescope_signal_state schema block not found. No files were changed."
}

$patchedRecorder = [regex]::Replace(
  $patchedRecorder,
  $stateSchemaPattern,
  $stateSchemaReplacement,
  1
)

$stateSelectPattern = '(?s)const stateRows = await sql`\s*SELECT signal_id, visible, armed\s*FROM memescope_signal_state\s*`;'
$stateSelectReplacement = @'
const stateRows = await sql`
    SELECT signal_id, visible, armed, confirmation_count
    FROM memescope_signal_state
  `;
'@

if (![regex]::IsMatch($patchedRecorder, $stateSelectPattern)) {
  throw "Signal state SELECT block not found. No files were changed."
}

$patchedRecorder = [regex]::Replace(
  $patchedRecorder,
  $stateSelectPattern,
  $stateSelectReplacement,
  1
)

$confirmationMapMarker = "  // Disappearance re-arms the same signal for a future fresh occurrence."

if (!$patchedRecorder.Contains($confirmationMapMarker)) {
  throw "Signal state disappearance marker not found. No files were changed."
}

$confirmationMap = @'
  const confirmationCounts = new Map(
    stateRows.map((raw) => {
      const row = raw as DbRow;
      return [
        String(row.signal_id),
        Math.max(
          0,
          Math.round(
            Number(
              row.confirmation_count ??
                0,
            ),
          ),
        ),
      ] as [string, number];
    }),
  );

'@

$patchedRecorder = $patchedRecorder.Replace(
  $confirmationMapMarker,
  $confirmationMap + $confirmationMapMarker
)

$disappearPattern = '(?s)if \(state\.visible && !visibleIds\.has\(signalId\)\) \{\s*await sql`\s*UPDATE memescope_signal_state\s*SET visible = FALSE, armed = TRUE, updated_at = NOW\(\)\s*WHERE signal_id = \$\{signalId\}\s*`;\s*state\.visible = false;\s*state\.armed = true;\s*\}'

$disappearReplacement = @'
if (state.visible && !visibleIds.has(signalId)) {
      await sql`
        UPDATE memescope_signal_state
        SET
          visible = FALSE,
          armed = TRUE,
          confirmation_count = 0,
          updated_at = NOW()
        WHERE signal_id = ${signalId}
      `;
      state.visible = false;
      state.armed = true;
      confirmationCounts.set(
        signalId,
        0,
      );
    }
'@

if (![regex]::IsMatch($patchedRecorder, $disappearPattern)) {
  throw "Signal disappearance reset block not found. No files were changed."
}

$patchedRecorder = [regex]::Replace(
  $patchedRecorder,
  $disappearPattern,
  $disappearReplacement,
  1
)

$confirmationPattern = '(?s)  // Stage 16: two-scan confirmation\..*?    if \(activeIds\.has\(signal\.id\) \|\| !mayOpen\) continue;'

$confirmationReplacement = @'
  // Stage 19.2: preset-driven consecutive confirmation.
  // A more aggressive preset can open on the first qualifying scan,
  // while stricter presets require the setup to remain valid across
  // multiple consecutive recorder scans.
  const requiredConfirmations =
    Math.max(
      1,
      Math.min(
        4,
        Math.round(
          confirmationScans,
        ),
      ),
    );

  for (const signal of watchSignals) {
    let state = states.get(signal.id);
    let mayOpen = false;
    let count =
      confirmationCounts.get(
        signal.id,
      ) ?? 0;

    if (!state) {
      count = 1;
      mayOpen =
        count >=
        requiredConfirmations;

      state = {
        visible: true,
        armed: !mayOpen,
      };
      states.set(
        signal.id,
        state,
      );
      confirmationCounts.set(
        signal.id,
        count,
      );

      await sql`
        INSERT INTO memescope_signal_state (
          signal_id,
          visible,
          armed,
          confirmation_count,
          updated_at
        )
        VALUES (
          ${signal.id},
          TRUE,
          ${!mayOpen},
          ${count},
          NOW()
        )
        ON CONFLICT (signal_id)
        DO UPDATE SET
          visible = TRUE,
          armed = ${!mayOpen},
          confirmation_count = ${count},
          updated_at = NOW()
      `;
    } else if (!state.visible) {
      count = 1;
      mayOpen =
        count >=
        requiredConfirmations;

      state.visible = true;
      state.armed = !mayOpen;
      confirmationCounts.set(
        signal.id,
        count,
      );

      await sql`
        UPDATE memescope_signal_state
        SET
          visible = TRUE,
          armed = ${!mayOpen},
          confirmation_count = ${count},
          updated_at = NOW()
        WHERE signal_id = ${signal.id}
      `;
    } else if (state.armed) {
      count += 1;
      mayOpen =
        count >=
        requiredConfirmations;

      state.armed = !mayOpen;
      confirmationCounts.set(
        signal.id,
        count,
      );

      await sql`
        UPDATE memescope_signal_state
        SET
          visible = TRUE,
          armed = ${!mayOpen},
          confirmation_count = ${count},
          updated_at = NOW()
        WHERE signal_id = ${signal.id}
      `;
    }

    if (activeIds.has(signal.id) || !mayOpen) continue;
'@

if (![regex]::IsMatch($patchedRecorder, $confirmationPattern)) {
  throw "Stage 16 confirmation loop not found. No files were changed."
}

$patchedRecorder = [regex]::Replace(
  $patchedRecorder,
  $confirmationPattern,
  $confirmationReplacement,
  1
)

$recorderChecks = @(
  "confirmationScans = 2",
  "confirmation_count INTEGER",
  "ADD COLUMN IF NOT EXISTS confirmation_count",
  "confirmationCounts",
  "requiredConfirmations",
  "Stage 19.2: preset-driven consecutive confirmation."
)

foreach ($check in $recorderChecks) {
  if (!$patchedRecorder.Contains($check)) {
    throw "Recorder validation failed: $check. No files were changed."
  }
}

# ============================================================
# 2. PRESET-ONLY SERVER SETTINGS
# ============================================================

$settingsLib = @'
import "server-only";

import {
  neon,
} from "@neondatabase/serverless";

import {
  DEFAULT_SIGNAL_SETTINGS,
  normalizeSignalSettings,
} from "@/lib/signal-engine";
import type {
  SignalSettings,
} from "@/lib/signal-types";

export type SignalPresetName =
  | "aggressive"
  | "balanced"
  | "strict"
  | "ultra";

export type SignalEngineSettings =
  SignalSettings & {
    confirmationScans: number;
  };

export const SIGNAL_PRESETS: Record<
  SignalPresetName,
  SignalEngineSettings
> = {
  aggressive: {
    minSignalScore: 65,
    minLiquidityUsd: 25_000,
    maxPairAgeHours: 48,
    confirmationScans: 1,
  },
  balanced: {
    minSignalScore: 80,
    minLiquidityUsd: 50_000,
    maxPairAgeHours: 24,
    confirmationScans: 1,
  },
  strict: {
    minSignalScore: 88,
    minLiquidityUsd: 100_000,
    maxPairAgeHours: 12,
    confirmationScans: 1,
  },
  ultra: {
    minSignalScore: 92,
    minLiquidityUsd: 150_000,
    maxPairAgeHours: 6,
    confirmationScans: 2,
  },
};

export const DEFAULT_SIGNAL_ENGINE_SETTINGS:
  SignalEngineSettings = {
    ...DEFAULT_SIGNAL_SETTINGS,
    confirmationScans: 1,
  };

let schemaPromise:
  | Promise<void>
  | null = null;

function sqlClient() {
  const databaseUrl =
    process.env.DATABASE_URL?.trim();

  if (!databaseUrl) {
    throw new Error(
      "DATABASE_URL is not configured.",
    );
  }

  return neon(databaseUrl);
}

function num(
  value: unknown,
  fallback: number,
) {
  const parsed =
    Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

function normalizeEngineSettings(
  input?: Partial<
    SignalEngineSettings
  >,
): SignalEngineSettings {
  const base =
    normalizeSignalSettings(
      input,
    );

  const confirmationScans =
    Math.max(
      1,
      Math.min(
        4,
        Math.round(
          Number(
            input?.confirmationScans,
          ) ||
            DEFAULT_SIGNAL_ENGINE_SETTINGS
              .confirmationScans,
        ),
      ),
    );

  return {
    ...base,
    confirmationScans,
  };
}

export async function ensureSignalEngineSettingsSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise = (async () => {
    const sql =
      sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_engine_settings (
        id INTEGER PRIMARY KEY,
        min_signal_score INTEGER NOT NULL DEFAULT 80,
        min_liquidity_usd DOUBLE PRECISION NOT NULL DEFAULT 50000,
        max_pair_age_hours INTEGER NOT NULL DEFAULT 24,
        confirmation_scans INTEGER NOT NULL DEFAULT 1,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS confirmation_scans INTEGER NOT NULL DEFAULT 1
    `;

    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ALTER COLUMN confirmation_scans SET DEFAULT 1
    `;

    await sql`
      INSERT INTO memescope_signal_engine_settings (
        id,
        min_signal_score,
        min_liquidity_usd,
        max_pair_age_hours,
        confirmation_scans
      )
      VALUES (
        1,
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minSignalScore},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minLiquidityUsd},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxPairAgeHours},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.confirmationScans}
      )
      ON CONFLICT (id) DO NOTHING
    `;
  })().catch(
    (error) => {
      schemaPromise = null;
      throw error;
    },
  );

  return schemaPromise;
}

export async function getSignalEngineSettings():
Promise<SignalEngineSettings> {
  await ensureSignalEngineSettingsSchema();

  const sql =
    sqlClient();

  const rows = await sql`
    SELECT
      min_signal_score,
      min_liquidity_usd,
      max_pair_age_hours,
      confirmation_scans
    FROM memescope_signal_engine_settings
    WHERE id = 1
    LIMIT 1
  `;

  const row =
    rows[0] as
      | Record<string, unknown>
      | undefined;

  if (!row) {
    return DEFAULT_SIGNAL_ENGINE_SETTINGS;
  }

  return normalizeEngineSettings({
    minSignalScore:
      num(
        row.min_signal_score,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minSignalScore,
      ),
    minLiquidityUsd:
      num(
        row.min_liquidity_usd,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minLiquidityUsd,
      ),
    maxPairAgeHours:
      num(
        row.max_pair_age_hours,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxPairAgeHours,
      ),
    confirmationScans:
      num(
        row.confirmation_scans,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .confirmationScans,
      ),
  });
}

export async function saveSignalEngineSettings(
  patch: Partial<
    SignalEngineSettings
  >,
) {
  await ensureSignalEngineSettingsSchema();

  const current =
    await getSignalEngineSettings();

  const next =
    normalizeEngineSettings({
      ...current,
      ...patch,
    });

  const sql =
    sqlClient();

  await sql`
    UPDATE memescope_signal_engine_settings
    SET
      min_signal_score = ${next.minSignalScore},
      min_liquidity_usd = ${next.minLiquidityUsd},
      max_pair_age_hours = ${next.maxPairAgeHours},
      confirmation_scans = ${next.confirmationScans},
      updated_at = NOW()
    WHERE id = 1
  `;

  return next;
}

export async function applySignalPreset(
  name: SignalPresetName,
) {
  return saveSignalEngineSettings(
    SIGNAL_PRESETS[name],
  );
}

export async function resetSignalEngineSettings() {
  return applySignalPreset(
    "balanced",
  );
}

export function signalPresetName(
  settings: SignalEngineSettings,
): SignalPresetName | "custom" {
  for (
    const name of Object.keys(
      SIGNAL_PRESETS,
    ) as SignalPresetName[]
  ) {
    const preset =
      SIGNAL_PRESETS[name];

    if (
      preset.minSignalScore ===
        settings.minSignalScore &&
      preset.minLiquidityUsd ===
        settings.minLiquidityUsd &&
      preset.maxPairAgeHours ===
        settings.maxPairAgeHours &&
      preset.confirmationScans ===
        settings.confirmationScans
    ) {
      return name;
    }
  }

  return "custom";
}
'@

# ============================================================
# 3. RECORD ROUTE PASSES PRESET CONFIRMATION
# ============================================================

$recordRoute = @'
import {
  NextResponse,
} from "next/server";

import {
  generateSignals,
} from "@/lib/signal-engine";
import {
  getSignalEngineSettings,
} from "@/lib/signal-engine-settings";
import {
  recordSignalSnapshot,
} from "@/lib/signal-recorder-db";
import type {
  TerminalResponse,
} from "@/lib/terminal-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(
  request: Request,
) {
  const secret =
    process.env.CRON_SECRET?.trim();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) ===
        `Bearer ${secret}`,
  );
}

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        error: "Unauthorized.",
      },
      {
        status: 401,
      },
    );
  }

  try {
    const origin =
      new URL(
        request.url,
      ).origin;

    const response =
      await fetch(
        `${origin}/api/terminal/solana`,
        {
          cache: "no-store",
        },
      );

    const body =
      (await response.json()) as
        | TerminalResponse
        | {
            error?: string;
          };

    if (!response.ok) {
      throw new Error(
        "error" in body
          ? body.error ??
              "Terminal feed failed."
          : "Terminal feed failed.",
      );
    }

    const terminal =
      body as TerminalResponse;

    const settings =
      await getSignalEngineSettings();

    const signals =
      generateSignals(
        terminal.tokens,
        settings,
      );

    const result =
      await recordSignalSnapshot(
        terminal.tokens,
        signals,
        settings.confirmationScans,
      );

    return NextResponse.json({
      ok: true,
      configured: true,
      ...result,
      engineSettings:
        settings,
    });
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Signal recorder failed.";

    return NextResponse.json(
      {
        ok: false,
        configured:
          !message.includes(
            "DATABASE_URL",
          ),
        error: message,
      },
      {
        status: 500,
      },
    );
  }
}
'@

# ============================================================
# 4. SIMPLE, DIRECT PRESET TELEGRAM UI
# ============================================================

$webhook = @'
import {
  NextResponse,
} from "next/server";

import {
  applySignalPreset,
  getSignalEngineSettings,
  signalPresetName,
  type SignalEngineSettings,
  type SignalPresetName,
} from "@/lib/signal-engine-settings";
import {
  escapeTelegramHtml,
  telegramAnswerCallbackQuery,
  telegramConfig,
  telegramEditMessage,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

type TelegramMessage = {
  message_id?: number;
  text?: string;
  chat?: {
    id?: number;
  };
  from?: {
    id?: number;
  };
};

type TelegramCallbackQuery = {
  id?: string;
  data?: string;
  from?: {
    id?: number;
  };
  message?: TelegramMessage;
};

type TelegramUpdate = {
  message?: TelegramMessage;
  callback_query?: TelegramCallbackQuery;
};

type InlineKeyboard = {
  inline_keyboard: Array<
    Array<{
      text: string;
      callback_data?: string;
      url?: string;
    }>
  >;
};

function ownerId() {
  return (
    process.env
      .TELEGRAM_OWNER_ID
      ?.trim() ??
    ""
  );
}

function isOwner(
  userId: number | undefined,
) {
  const expected =
    ownerId();

  return Boolean(
    expected &&
      userId &&
      String(userId) ===
        expected,
  );
}

function validSolanaAddress(
  value: string,
) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
    value,
  );
}

function money(
  value: number,
) {
  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(1)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(0)}K`;
  }

  return `$${value.toFixed(0)}`;
}

function presetTitle(
  preset:
    | SignalPresetName
    | "custom",
) {
  if (
    preset === "aggressive"
  ) {
    return "AGGRESSIVE";
  }

  if (
    preset === "balanced"
  ) {
    return "BALANCED";
  }

  if (
    preset === "strict"
  ) {
    return "STRICT";
  }

  if (
    preset === "ultra"
  ) {
    return "ULTRA STRICT";
  }

  return "CUSTOM (LEGACY)";
}

function presetText(
  settings:
    SignalEngineSettings,
) {
  const current =
    signalPresetName(
      settings,
    );

  return [
    "<b>MEMESCOPE PRESET CONTROL</b>",
    "",
    `Active preset: <b>${presetTitle(
      current,
    )}</b>`,
    "",
    "<b>Choose how selective the engine should be:</b>",
    "",
    "\uD83D\uDD25 <b>AGGRESSIVE</b> - more signals",
    "Score >= 65 | Liquidity >= $25K | Age <= 48h | Confirm 1 scan",
    "",
    "\u2696\uFE0F <b>BALANCED</b> - standard HQ mode",
    "Score >= 80 | Liquidity >= $50K | Age <= 24h | Confirm 1 scan",
    "",
    "\uD83D\uDEE1\uFE0F <b>STRICT</b> - fewer, tighter signals",
    "Score >= 88 | Liquidity >= $100K | Age <= 12h | Confirm 1 scan",
    "",
    "\uD83D\uDD12 <b>ULTRA STRICT</b> - rarest signals",
    "Score >= 92 | Liquidity >= $150K | Age <= 6h | Confirm 2 scans",
    "",
    "<b>Current values</b>",
    `Score >= ${settings.minSignalScore}`,
    `Liquidity >= ${money(
      settings.minLiquidityUsd,
    )}`,
    `Max age <= ${settings.maxPairAgeHours}h`,
    `Confirmation = ${settings.confirmationScans} consecutive scan${
      settings.confirmationScans === 1
        ? ""
        : "s"
    }`,
    "",
    "<i>Stage 16 HQ volume, transaction, buy-pressure, spike, momentum and liquidity/valuation gates remain active in every preset.</i>",
    "<i>Preset strictness changes detection frequency; it does not guarantee future performance.</i>",
  ].join("\n");
}

function presetKeyboard(
  settings:
    SignalEngineSettings,
): InlineKeyboard {
  const current =
    signalPresetName(
      settings,
    );

  const label = (
    name: SignalPresetName,
    text: string,
  ) =>
    current === name
      ? `\u2705 ${text}`
      : text;

  return {
    inline_keyboard: [
      [
        {
          text:
            label(
              "aggressive",
              "\uD83D\uDD25 Aggressive",
            ),
          callback_data:
            "preset:aggressive",
        },
        {
          text:
            label(
              "balanced",
              "\u2696\uFE0F Balanced",
            ),
          callback_data:
            "preset:balanced",
        },
      ],
      [
        {
          text:
            label(
              "strict",
              "\uD83D\uDEE1\uFE0F Strict",
            ),
          callback_data:
            "preset:strict",
        },
        {
          text:
            label(
              "ultra",
              "\uD83D\uDD12 Ultra Strict",
            ),
          callback_data:
            "preset:ultra",
        },
      ],
      [
        {
          text:
            "\uD83D\uDD04 Refresh",
          callback_data:
            "preset:refresh",
        },
      ],
    ],
  };
}

async function reply(
  chatId: number,
  messageId:
    number | undefined,
  text: string,
  keyboard?: InlineKeyboard,
) {
  return telegramSendMessage(
    chatId,
    text,
    {
      replyToMessageId:
        messageId,
      ...(keyboard
        ? {
            replyMarkup:
              keyboard as unknown as Record<
                string,
                unknown
              >,
          }
        : {}),
    },
  );
}

async function showSettings(
  chatId: number,
  messageId?:
    number,
) {
  const settings =
    await getSignalEngineSettings();

  if (messageId) {
    await telegramEditMessage(
      chatId,
      messageId,
      presetText(
        settings,
      ),
      presetKeyboard(
        settings,
      ) as unknown as Record<
        string,
        unknown
      >,
    );
    return;
  }

  await telegramSendMessage(
    chatId,
    presetText(
      settings,
    ),
    {
      replyMarkup:
        presetKeyboard(
          settings,
        ) as unknown as Record<
          string,
          unknown
        >,
    },
  );
}

async function handleCallback(
  callback:
    TelegramCallbackQuery,
) {
  const callbackId =
    callback.id;

  const userId =
    callback.from?.id;

  const chatId =
    callback.message?.chat?.id;

  const messageId =
    callback.message?.message_id;

  const data =
    callback.data ??
    "";

  if (!callbackId) {
    return;
  }

  if (!isOwner(userId)) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Owner only.",
        showAlert: true,
      },
    );
    return;
  }

  if (
    !chatId ||
    !messageId
  ) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Control message unavailable.",
        showAlert: true,
      },
    );
    return;
  }

  if (
    data ===
    "preset:refresh"
  ) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Refreshing settings...",
      },
    );

    await showSettings(
      chatId,
      messageId,
    );

    return;
  }

  const rawPreset =
    data.startsWith(
      "preset:",
    )
      ? data.slice(
          "preset:".length,
        )
      : "";

  const valid =
    rawPreset ===
      "aggressive" ||
    rawPreset ===
      "balanced" ||
    rawPreset ===
      "strict" ||
    rawPreset ===
      "ultra";

  if (!valid) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Unknown preset.",
        showAlert: true,
      },
    );
    return;
  }

  const preset =
    rawPreset as
      SignalPresetName;

  await telegramAnswerCallbackQuery(
    callbackId,
    {
      text:
        `Applying ${presetTitle(
          preset,
        )}...`,
    },
  );

  try {
    const settings =
      await applySignalPreset(
        preset,
      );

    await telegramEditMessage(
      chatId,
      messageId,
      presetText(
        settings,
      ),
      presetKeyboard(
        settings,
      ) as unknown as Record<
        string,
        unknown
      >,
    );
  } catch (error) {
    await telegramSendMessage(
      chatId,
      `<b>Preset update failed</b>\n${escapeTelegramHtml(
        error instanceof Error
          ? error.message
          : "Unknown error.",
      )}`,
    );
  }
}

async function fetchJson(
  origin: string,
  path: string,
) {
  const response =
    await fetch(
      `${origin}${path}`,
      {
        cache: "no-store",
      },
    );

  const body =
    (await response.json()) as
      Record<string, unknown>;

  if (!response.ok) {
    throw new Error(
      String(
        body.error ??
          "MemeScope API request failed.",
      ),
    );
  }

  return body;
}

function pct(
  value: unknown,
) {
  const number =
    Number(value);

  if (!Number.isFinite(number)) {
    return "N/A";
  }

  return `${
    number > 0
      ? "+"
      : ""
  }${number.toFixed(2)}%`;
}

function helpText() {
  return [
    "<b>MemeScope Owner Bot</b>",
    "",
    "/settings - preset control panel",
    "/signals - active HQ signals",
    "/history - recent signal history",
    "/stats - 30-day signal statistics",
    "/token &lt;CA&gt; - open token",
    "/risk &lt;CA&gt; - open risk analysis",
    "/channel - signal channel",
    "/whoami - show Telegram user ID",
    "/help - commands",
    "",
    "<i>Signal configuration is preset-only. Open /settings and tap one button.</i>",
  ].join("\n");
}

export async function POST(
  request: Request,
) {
  const {
    webhookSecret,
    channelUrl,
  } =
    telegramConfig();

  if (!webhookSecret) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Telegram webhook is not configured.",
      },
      {
        status: 503,
      },
    );
  }

  const supplied =
    request.headers.get(
      "x-telegram-bot-api-secret-token",
    );

  if (
    supplied !==
    webhookSecret
  ) {
    return NextResponse.json(
      {
        ok: false,
      },
      {
        status: 401,
      },
    );
  }

  const update =
    (await request.json()) as
      TelegramUpdate;

  if (
    update.callback_query
  ) {
    await handleCallback(
      update.callback_query,
    ).catch(
      async (error) => {
        const chatId =
          update.callback_query
            ?.message
            ?.chat
            ?.id;

        if (chatId) {
          await telegramSendMessage(
            chatId,
            `<b>Button action failed</b>\n${escapeTelegramHtml(
              error instanceof Error
                ? error.message
                : "Unknown callback error.",
            )}`,
          ).catch(
            () => undefined,
          );
        }
      },
    );

    return NextResponse.json({
      ok: true,
    });
  }

  const message =
    update.message;

  const chatId =
    message?.chat?.id;

  const userId =
    message?.from?.id;

  const rawText =
    message?.text?.trim() ??
    "";

  if (
    !chatId ||
    !rawText
  ) {
    return NextResponse.json({
      ok: true,
    });
  }

  const [
    rawCommand,
    ...args
  ] =
    rawText.split(/\s+/);

  const command =
    rawCommand
      .toLowerCase()
      .split("@")[0];

  const argument =
    args.join(" ").trim();

  if (
    command === "/whoami"
  ) {
    await reply(
      chatId,
      message.message_id,
      [
        "<b>Telegram User ID</b>",
        "",
        `<code>${escapeTelegramHtml(
          userId ??
            "unknown",
        )}</code>`,
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  if (!ownerId()) {
    await reply(
      chatId,
      message.message_id,
      [
        "<b>Owner access is not configured.</b>",
        "",
        `Your Telegram User ID: <code>${escapeTelegramHtml(
          userId ??
            "unknown",
        )}</code>`,
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  if (!isOwner(userId)) {
    await reply(
      chatId,
      message.message_id,
      "Unauthorized. This MemeScope bot is owner-only.",
    );

    return NextResponse.json({
      ok: true,
    });
  }

  const origin =
    new URL(
      request.url,
    ).origin;

  const site =
    telegramSiteUrl();

  try {
    if (
      command === "/start" ||
      command === "/help"
    ) {
      await reply(
        chatId,
        message.message_id,
        helpText(),
      );
    } else if (
      command === "/settings"
    ) {
      const settings =
        await getSignalEngineSettings();

      await reply(
        chatId,
        message.message_id,
        presetText(
          settings,
        ),
        presetKeyboard(
          settings,
        ),
      );
    } else if (
      command === "/signals"
    ) {
      const body =
        await fetchJson(
          origin,
          "/api/signals/history?limit=50",
        );

      const records =
        Array.isArray(
          body.records,
        )
          ? body.records
          : [];

      const active =
        records
          .filter(
            (item) =>
              typeof item ===
                "object" &&
              item !== null &&
              (
                item as Record<
                  string,
                  unknown
                >
              ).status ===
                "active",
          )
          .slice(0, 8) as Array<
          Record<
            string,
            unknown
          >
        >;

      const text =
        active.length === 0
          ? [
              "<b>Active HQ Signals</b>",
              "",
              "No active confirmed HQ signal right now.",
            ].join("\n")
          : [
              "<b>Active HQ Signals</b>",
              "",
              ...active.map(
                (
                  record,
                  index,
                ) =>
                  `${index + 1}. <b>$${escapeTelegramHtml(
                    record.symbol,
                  )}</b> - score ${Math.round(
                    Number(
                      record.scoreAtEntry ??
                        0,
                    ),
                  )}\nGain ${pct(
                    record.currentGainPercent,
                  )} | TP +${Number(
                    record.targetPercent ??
                      0,
                  ).toFixed(
                    1,
                  )}%\n<code>${escapeTelegramHtml(
                    record.tokenAddress,
                  )}</code>`,
              ),
            ].join(
              "\n\n",
            );

      await reply(
        chatId,
        message.message_id,
        text,
      );
    } else if (
      command === "/history"
    ) {
      const body =
        await fetchJson(
          origin,
          "/api/signals/history?limit=8",
        );

      const records =
        Array.isArray(
          body.records,
        )
          ? (
              body.records as Array<
                Record<
                  string,
                  unknown
                >
              >
            )
          : [];

      const text = [
        "<b>Recent Signal History</b>",
        "",
        ...(records.length
          ? records.map(
              (
                record,
                index,
              ) =>
                `${index + 1}. <b>$${escapeTelegramHtml(
                  record.symbol,
                )}</b> - ${escapeTelegramHtml(
                  String(
                    record.status ??
                      "active",
                  ).toUpperCase(),
                )}\nCurrent ${pct(
                  record.currentGainPercent,
                )} | Max ${pct(
                  record.peakGainPercent,
                )} | DD ${pct(
                  record.maxDrawdownPercent,
                )}`,
            )
          : [
              "No signal history yet.",
            ]),
      ].join(
        "\n\n",
      );

      await reply(
        chatId,
        message.message_id,
        text,
      );
    } else if (
      command === "/stats"
    ) {
      const body =
        await fetchJson(
          origin,
          "/api/signals/analytics?days=30",
        );

      const analytics =
        (body.analytics ??
          {}) as Record<
          string,
          unknown
        >;

      const text = [
        "<b>MemeScope - 30D Stats</b>",
        "",
        `Signals: <b>${Number(
          analytics.total ?? 0,
        )}</b>`,
        `Active: <b>${Number(
          analytics.active ?? 0,
        )}</b>`,
        `TP Hit: <b>${Number(
          analytics.targetHits ??
            0,
        )}</b>`,
        `Avg Current Gain: <b>${pct(
          analytics.averageCurrentGain,
        )}</b>`,
        `Avg Max Gain: <b>${pct(
          analytics.averagePeakGain,
        )}</b>`,
        `Avg Max Drawdown: <b>${pct(
          analytics.averageDrawdown,
        )}</b>`,
        "",
        "<i>Historical descriptive statistics are not future probabilities.</i>",
      ].join("\n");

      await reply(
        chatId,
        message.message_id,
        text,
      );
    } else if (
      command === "/token" ||
      command === "/risk"
    ) {
      if (
        !validSolanaAddress(
          argument,
        )
      ) {
        await reply(
          chatId,
          message.message_id,
          `Usage: ${command} &lt;Solana CA&gt;`,
        );
      } else {
        const encoded =
          encodeURIComponent(
            argument,
          );

        await telegramSendMessage(
          chatId,
          [
            command ===
            "/risk"
              ? "<b>MemeScope Risk Analyzer</b>"
              : "<b>MemeScope Token</b>",
            "",
            `<code>${escapeTelegramHtml(
              argument,
            )}</code>`,
          ].join("\n"),
          {
            replyToMessageId:
              message.message_id,
            replyMarkup: {
              inline_keyboard: [
                [
                  {
                    text:
                      "Open MemeScope",
                    url:
                      `${site}/token/${encoded}`,
                  },
                  {
                    text:
                      "Solscan",
                    url:
                      `https://solscan.io/token/${encoded}`,
                  },
                ],
              ],
            },
          },
        );
      }
    } else if (
      command === "/channel"
    ) {
      await reply(
        chatId,
        message.message_id,
        channelUrl
          ? `<a href="${escapeTelegramHtml(
              channelUrl,
            )}">Open MemeScope Signal Channel</a>`
          : "Signal channel URL is not configured yet.",
      );
    } else {
      await reply(
        chatId,
        message.message_id,
        helpText(),
      );
    }
  } catch (error) {
    await reply(
      chatId,
      message.message_id,
      `MemeScope bot error: ${escapeTelegramHtml(
        error instanceof Error
          ? error.message
          : "Unknown error.",
      )}`,
    ).catch(
      () => undefined,
    );
  }

  return NextResponse.json({
    ok: true,
  });
}
'@

# ============================================================
# 5. TELEGRAM HELPER: FORCE CALLBACK SUPPORT + SIMPLE COMMANDS
# ============================================================

$patchedTelegram = $telegram

# Ensure callback answer helper exists.
if (!$patchedTelegram.Contains("export async function telegramAnswerCallbackQuery(")) {
  $marker = "export async function telegramSetCommands()"
  $index = $patchedTelegram.IndexOf($marker)

  if ($index -lt 0) {
    throw "telegramSetCommands marker not found. No files were changed."
  }

$answerHelper = @'
export async function telegramAnswerCallbackQuery(
  callbackQueryId: string,
  options?: {
    text?: string;
    showAlert?: boolean;
  },
) {
  return telegramRequest<boolean>(
    "answerCallbackQuery",
    {
      callback_query_id:
        callbackQueryId,
      ...(options?.text
        ? {
            text:
              options.text,
          }
        : {}),
      show_alert:
        options?.showAlert ??
        false,
    },
  );
}

'@

  $patchedTelegram =
    $patchedTelegram.Substring(0, $index) +
    $answerHelper +
    $patchedTelegram.Substring($index)
}

$commandsStart =
  $patchedTelegram.IndexOf(
    "export async function telegramSetCommands()"
  )

$webhookStart =
  $patchedTelegram.IndexOf(
    "export async function telegramSetWebhook("
  )

if (
  $commandsStart -lt 0 -or
  $webhookStart -le $commandsStart
) {
  throw "Telegram command/webhook markers not found. No files were changed."
}

$commandsBlock = @'
export async function telegramSetCommands() {
  return telegramRequest<boolean>(
    "setMyCommands",
    {
      commands: [
        {
          command: "settings",
          description:
            "Choose signal engine preset",
        },
        {
          command: "signals",
          description:
            "Active HQ signals",
        },
        {
          command: "history",
          description:
            "Recent signal history",
        },
        {
          command: "stats",
          description:
            "30-day signal statistics",
        },
        {
          command: "token",
          description:
            "Open token by contract",
        },
        {
          command: "risk",
          description:
            "Open risk analysis",
        },
        {
          command: "channel",
          description:
            "Open signal channel",
        },
        {
          command: "whoami",
          description:
            "Show Telegram user ID",
        },
        {
          command: "help",
          description:
            "Show bot commands",
        },
      ],
    },
  );
}

'@

$patchedTelegram =
  $patchedTelegram.Substring(
    0,
    $commandsStart
  ) +
  $commandsBlock +
  $patchedTelegram.Substring(
    $webhookStart
  )

$setWebhookPattern = '(?s)export async function telegramSetWebhook\(\s*origin:\s*string,\s*\)\s*\{.*?\n\}'
$setWebhookBlock = @'
export async function telegramSetWebhook(
  origin: string,
) {
  const { webhookSecret } =
    telegramConfig();

  if (!webhookSecret) {
    throw new Error(
      "TELEGRAM_WEBHOOK_SECRET is not configured.",
    );
  }

  return telegramRequest<boolean>(
    "setWebhook",
    {
      url: `${origin.replace(
        /\/+$/,
        "",
      )}/api/telegram/webhook`,
      secret_token:
        webhookSecret,
      allowed_updates: [
        "message",
        "callback_query",
      ],
      drop_pending_updates: false,
    },
  );
}
'@

if (![regex]::IsMatch($patchedTelegram, $setWebhookPattern)) {
  throw "telegramSetWebhook function not found. No files were changed."
}

$patchedTelegram = [regex]::Replace(
  $patchedTelegram,
  $setWebhookPattern,
  $setWebhookBlock,
  1
)

$telegramChecks = @(
  "telegramAnswerCallbackQuery",
  '"callback_query"',
  "Choose signal engine preset",
  "drop_pending_updates: false"
)

foreach ($check in $telegramChecks) {
  if (!$patchedTelegram.Contains($check)) {
    throw "Telegram validation failed: $check. No files were changed."
  }
}

# ============================================================
# 6. BACKUP THEN WRITE
# ============================================================

$stamp =
  Get-Date -Format "yyyyMMdd-HHmmss"

$backup =
  Join-Path $env:TEMP "MemeScope-Stage19.2-$stamp"

New-Item -ItemType Directory -Force -Path $backup | Out-Null

foreach ($path in @(
  $settingsPath,
  $recorderPath,
  $recordRoutePath,
  $telegramPath,
  $webhookPath
)) {
  $name =
    Split-Path $path -Leaf

  $parent =
    Split-Path (
      Split-Path $path -Parent
    ) -Leaf

  Copy-Item -LiteralPath $path `
    -Destination (
      Join-Path $backup "$parent-$name.bak"
    ) `
    -Force
}

[System.IO.File]::WriteAllText(
  $settingsPath,
  $settingsLib,
  $utf8
)

[System.IO.File]::WriteAllText(
  $recorderPath,
  $patchedRecorder,
  $utf8
)

[System.IO.File]::WriteAllText(
  $recordRoutePath,
  $recordRoute,
  $utf8
)

[System.IO.File]::WriteAllText(
  $telegramPath,
  $patchedTelegram,
  $utf8
)

[System.IO.File]::WriteAllText(
  $webhookPath,
  $webhook,
  $utf8
)

Remove-Item `
  (Join-Path $root ".next") `
  -Recurse -Force `
  -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Stage 19.2 installed." -ForegroundColor Green
Write-Host ""
Write-Host "Preset behavior:" -ForegroundColor Cyan
Write-Host " AGGRESSIVE   -> score 65, liq 25K, age 48h, confirm 1 scan"
Write-Host " BALANCED     -> score 80, liq 50K, age 24h, confirm 1 scan"
Write-Host " STRICT       -> score 88, liq 100K, age 12h, confirm 1 scan"
Write-Host " ULTRA STRICT -> score 92, liq 150K, age 6h, confirm 2 scans"
Write-Host ""
Write-Host "Telegram buttons are now direct preset buttons." -ForegroundColor Green
Write-Host "Callback updates are explicitly enabled in setWebhook." -ForegroundColor Green
Write-Host ""
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
Write-Host ""
