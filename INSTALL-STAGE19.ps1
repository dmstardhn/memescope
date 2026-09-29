$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 19 - Owner Telegram Signal Control" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path (Join-Path $root "package.json"))) {
    throw "package.json tidak ditemukan. Jalankan installer dari root memecoin-analyst."
}

$required = @(
    "src/lib/signal-engine.ts",
    "src/lib/signal-recorder-db.ts",
    "src/lib/telegram.ts",
    "src/app/api/telegram/webhook/route.ts",
    "src/app/api/telegram/cron/route.ts",
    "src/app/signals/page.tsx",
    "src/components/signal-performance-panel.tsx"
)

foreach ($relative in $required) {
    if (!(Test-Path (Join-Path $root $relative))) {
        throw "Required file not found: $relative"
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-Stage19-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

foreach ($relative in $required) {
    $src = Join-Path $root $relative
    $name = ($relative -replace '[\\/]', '__') + ".bak"
    Copy-Item -LiteralPath $src -Destination (Join-Path $backup $name) -Force
}

Write-Host "Backup created: $backup" -ForegroundColor DarkGray

# ============================================================
# 1. PATCH SIGNAL ENGINE: SERVER-MANAGED 3 HIGH-LEVEL FILTERS
# ============================================================

$enginePath = Join-Path $root "src/lib/signal-engine.ts"
$engine = [System.IO.File]::ReadAllText($enginePath)
$engineOriginal = $engine

if ($engine -notmatch '\bSignalSettings\b') {
    $oldImport = @'
  SignalKind,
} from "@/lib/signal-types";
'@
    $newImport = @'
  SignalKind,
  SignalSettings,
} from "@/lib/signal-types";
'@
    if (!$engine.Contains($oldImport)) {
        throw "Signal engine import marker tidak ditemukan."
    }
    $engine = $engine.Replace($oldImport, $newImport)
}

if ($engine.Contains('const HIGH_QUALITY_MIN_SCORE = 80;')) {
$settingsBlock = @'
export const DEFAULT_SIGNAL_SETTINGS: SignalSettings = {
  minSignalScore: 80,
  minLiquidityUsd: 50_000,
  maxPairAgeHours: 24,
};

export function normalizeSignalSettings(
  input?: Partial<SignalSettings>,
): SignalSettings {
  const minSignalScore = Math.max(
    60,
    Math.min(
      95,
      Math.round(
        Number(input?.minSignalScore) ||
          DEFAULT_SIGNAL_SETTINGS.minSignalScore,
      ),
    ),
  );

  const minLiquidityUsd = Math.max(
    10_000,
    Math.min(
      1_000_000,
      Math.round(
        Number(input?.minLiquidityUsd) ||
          DEFAULT_SIGNAL_SETTINGS.minLiquidityUsd,
      ),
    ),
  );

  const maxPairAgeHours = Math.max(
    1,
    Math.min(
      168,
      Math.round(
        Number(input?.maxPairAgeHours) ||
          DEFAULT_SIGNAL_SETTINGS.maxPairAgeHours,
      ),
    ),
  );

  return {
    minSignalScore,
    minLiquidityUsd,
    maxPairAgeHours,
  };
}
'@
    $engine = $engine.Replace(
        'const HIGH_QUALITY_MIN_SCORE = 80;',
        $settingsBlock
    )
}
elseif (!$engine.Contains("DEFAULT_SIGNAL_SETTINGS")) {
    throw "Signal engine score marker tidak ditemukan."
}

$oldPotentialSig = @'
function potentialTarget(
  token: TerminalToken,
  score: number,
  buyShare: number,
  spike: number,
  change5m: number,
  change1h: number,
) {
'@
$newPotentialSig = @'
function potentialTarget(
  token: TerminalToken,
  score: number,
  buyShare: number,
  spike: number,
  change5m: number,
  change1h: number,
  minSignalScore: number,
) {
'@
if ($engine.Contains($oldPotentialSig)) {
    $engine = $engine.Replace($oldPotentialSig, $newPotentialSig)
}

$engine = $engine.Replace(
    '(score - HIGH_QUALITY_MIN_SCORE) * 0.7',
    '(score - minSignalScore) * 0.7'
)

$oldBuildSig = @'
  change5m: number,
  change1h: number,
  reasons: string[],
): SignalCall {
'@
$newBuildSig = @'
  change5m: number,
  change1h: number,
  settings: SignalSettings,
  reasons: string[],
): SignalCall {
'@
if ($engine.Contains($oldBuildSig)) {
    $engine = $engine.Replace($oldBuildSig, $newBuildSig)
}

$oldPotentialCall = @'
      change5m,
      change1h,
    );
'@
$newPotentialCall = @'
      change5m,
      change1h,
      settings.minSignalScore,
    );
'@
if ($engine.Contains($oldPotentialCall)) {
    $engine = $engine.Replace($oldPotentialCall, $newPotentialCall)
}

$oldGenerate = @'
export function generateSignals(
  tokens: TerminalToken[],
): SignalCall[] {
  const calls: SignalCall[] = [];
'@
$newGenerate = @'
export function generateSignals(
  tokens: TerminalToken[],
  rawSettings?: Partial<SignalSettings>,
): SignalCall[] {
  const settings =
    normalizeSignalSettings(
      rawSettings,
    );

  const calls: SignalCall[] = [];
'@
if ($engine.Contains($oldGenerate)) {
    $engine = $engine.Replace($oldGenerate, $newGenerate)
}
elseif (!$engine.Contains("rawSettings?: Partial<SignalSettings>")) {
    throw "generateSignals marker tidak ditemukan."
}

$engine = $engine.Replace(
    'ageMinutes > 1_440 ||',
    'ageMinutes > settings.maxPairAgeHours * 60 ||'
)
$engine = $engine.Replace(
    'token.liquidityUsd < 50_000 ||',
    'token.liquidityUsd < settings.minLiquidityUsd ||'
)

$oldScoreGate = @'
    if (
      score <
      HIGH_QUALITY_MIN_SCORE
    ) {
'@
$newScoreGate = @'
    if (
      score <
      settings.minSignalScore
    ) {
'@
if ($engine.Contains($oldScoreGate)) {
    $engine = $engine.Replace($oldScoreGate, $newScoreGate)
}

$oldBuildCallTail = @'
        change5m,
        change1h,
        [
'@
$newBuildCallTail = @'
        change5m,
        change1h,
        settings,
        [
'@
if ($engine.Contains($oldBuildCallTail)) {
    $engine = $engine.Replace($oldBuildCallTail, $newBuildCallTail)
}

$engineChecks = @(
    "DEFAULT_SIGNAL_SETTINGS",
    "normalizeSignalSettings",
    "rawSettings?: Partial<SignalSettings>",
    "settings.minSignalScore",
    "settings.minLiquidityUsd",
    "settings.maxPairAgeHours"
)
foreach ($check in $engineChecks) {
    if (!$engine.Contains($check)) {
        throw "Signal engine validation failed: $check"
    }
}

if ($engine -ne $engineOriginal) {
    [System.IO.File]::WriteAllText($enginePath, $engine, $utf8)
    Write-Host "Updated: src/lib/signal-engine.ts" -ForegroundColor Green
} else {
    Write-Host "Signal engine Stage 19 patch already present." -ForegroundColor Yellow
}

# ============================================================
# 2. SERVER SETTINGS STORE IN NEON
# ============================================================

$settingsLibPath = Join-Path $root "src/lib/signal-engine-settings.ts"

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
  | "strict"
  | "balanced"
  | "broad";

const PRESETS: Record<
  SignalPresetName,
  SignalSettings
> = {
  strict: {
    minSignalScore: 90,
    minLiquidityUsd: 100_000,
    maxPairAgeHours: 12,
  },
  balanced: {
    minSignalScore: 80,
    minLiquidityUsd: 50_000,
    maxPairAgeHours: 24,
  },
  broad: {
    minSignalScore: 75,
    minLiquidityUsd: 25_000,
    maxPairAgeHours: 48,
  },
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
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

export async function ensureSignalEngineSettingsSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_engine_settings (
        id INTEGER PRIMARY KEY,
        min_signal_score INTEGER NOT NULL DEFAULT 80,
        min_liquidity_usd DOUBLE PRECISION NOT NULL DEFAULT 50000,
        max_pair_age_hours INTEGER NOT NULL DEFAULT 24,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_signal_engine_settings (
        id,
        min_signal_score,
        min_liquidity_usd,
        max_pair_age_hours
      )
      VALUES (
        1,
        ${DEFAULT_SIGNAL_SETTINGS.minSignalScore},
        ${DEFAULT_SIGNAL_SETTINGS.minLiquidityUsd},
        ${DEFAULT_SIGNAL_SETTINGS.maxPairAgeHours}
      )
      ON CONFLICT (id) DO NOTHING
    `;
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

export async function getSignalEngineSettings(): Promise<SignalSettings> {
  await ensureSignalEngineSettingsSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      min_signal_score,
      min_liquidity_usd,
      max_pair_age_hours
    FROM memescope_signal_engine_settings
    WHERE id = 1
    LIMIT 1
  `;

  const row =
    rows[0] as
      | Record<string, unknown>
      | undefined;

  if (!row) {
    return DEFAULT_SIGNAL_SETTINGS;
  }

  return normalizeSignalSettings({
    minSignalScore: num(
      row.min_signal_score,
      DEFAULT_SIGNAL_SETTINGS.minSignalScore,
    ),
    minLiquidityUsd: num(
      row.min_liquidity_usd,
      DEFAULT_SIGNAL_SETTINGS.minLiquidityUsd,
    ),
    maxPairAgeHours: num(
      row.max_pair_age_hours,
      DEFAULT_SIGNAL_SETTINGS.maxPairAgeHours,
    ),
  });
}

export async function saveSignalEngineSettings(
  patch: Partial<SignalSettings>,
) {
  await ensureSignalEngineSettingsSchema();

  const current =
    await getSignalEngineSettings();

  const next =
    normalizeSignalSettings({
      ...current,
      ...patch,
    });

  const sql = sqlClient();

  await sql`
    UPDATE memescope_signal_engine_settings
    SET
      min_signal_score = ${next.minSignalScore},
      min_liquidity_usd = ${next.minLiquidityUsd},
      max_pair_age_hours = ${next.maxPairAgeHours},
      updated_at = NOW()
    WHERE id = 1
  `;

  return next;
}

export async function applySignalPreset(
  name: SignalPresetName,
) {
  const preset = PRESETS[name];

  return saveSignalEngineSettings(
    preset,
  );
}

export async function resetSignalEngineSettings() {
  return saveSignalEngineSettings(
    DEFAULT_SIGNAL_SETTINGS,
  );
}

export function signalPresetName(
  settings: SignalSettings,
): SignalPresetName | "custom" {
  for (
    const name of Object.keys(
      PRESETS,
    ) as SignalPresetName[]
  ) {
    const preset =
      PRESETS[name];

    if (
      preset.minSignalScore ===
        settings.minSignalScore &&
      preset.minLiquidityUsd ===
        settings.minLiquidityUsd &&
      preset.maxPairAgeHours ===
        settings.maxPairAgeHours
    ) {
      return name;
    }
  }

  return "custom";
}
'@

[System.IO.File]::WriteAllText(
    $settingsLibPath,
    $settingsLib,
    $utf8
)
Write-Host "Created: src/lib/signal-engine-settings.ts" -ForegroundColor Green

# ============================================================
# 3. READ-ONLY SETTINGS API FOR CLIENT WEBSITE
# ============================================================

$settingsApiDir = Join-Path $root "src/app/api/signals/engine-settings"
New-Item -ItemType Directory -Force -Path $settingsApiDir | Out-Null

$settingsApi = @'
import {
  NextResponse,
} from "next/server";

import {
  getSignalEngineSettings,
} from "@/lib/signal-engine-settings";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const settings =
      await getSignalEngineSettings();

    return NextResponse.json({
      ok: true,
      settings,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Unable to load signal settings.",
      },
      {
        status: 500,
      },
    );
  }
}
'@

[System.IO.File]::WriteAllText(
    (Join-Path $settingsApiDir "route.ts"),
    $settingsApi,
    $utf8
)
Write-Host "Created: /api/signals/engine-settings GET" -ForegroundColor Green

# ============================================================
# 4. PROTECTED SERVER RECORDER
# ============================================================

$recordDir = Join-Path $root "src/app/api/signals/record"
New-Item -ItemType Directory -Force -Path $recordDir | Out-Null

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

[System.IO.File]::WriteAllText(
    (Join-Path $recordDir "route.ts"),
    $recordRoute,
    $utf8
)
Write-Host "Updated: protected /api/signals/record" -ForegroundColor Green

# ============================================================
# 5. TELEGRAM CRON PASSES SECRET TO RECORDER
# ============================================================

$cronPath = Join-Path $root "src/app/api/telegram/cron/route.ts"

$cronRoute = @'
import {
  NextResponse,
} from "next/server";

function secretValue() {
  return (
    process.env.CRON_SECRET?.trim() ??
    ""
  );
}

function authorized(
  request: Request,
) {
  const secret =
    secretValue();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) ===
        `Bearer ${secret}`,
  );
}

export async function GET(
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

  const secret =
    secretValue();

  const origin =
    new URL(
      request.url,
    ).origin;

  const response =
    await fetch(
      `${origin}/api/signals/record`,
      {
        method: "POST",
        headers: {
          authorization:
            `Bearer ${secret}`,
        },
        cache: "no-store",
      },
    );

  const body =
    (await response.json()) as
      Record<string, unknown>;

  return NextResponse.json(
    {
      ok: response.ok,
      recorder: body,
    },
    {
      status:
        response.ok
          ? 200
          : response.status,
    },
  );
}
'@

[System.IO.File]::WriteAllText(
    $cronPath,
    $cronRoute,
    $utf8
)
Write-Host "Updated: Telegram cron -> protected recorder" -ForegroundColor Green

# ============================================================
# 6. WEBSITE SIGNALS PAGE: REMOVE CLIENT SETTINGS CONTROLS
# ============================================================

$signalsPagePath = Join-Path $root "src/app/signals/page.tsx"
$page = [System.IO.File]::ReadAllText($signalsPagePath)
$pageOriginal = $page

$page = [regex]::Replace(
    $page,
    '(?s)import\s*\{\s*SignalPresetManager,\s*\}\s*from\s*"@/components/signal-preset-manager";\s*',
    '',
    1
)

$oldEngineImport = @'
import {
  generateSignals,
} from "@/lib/signal-engine";
'@
$newEngineImport = @'
import {
  DEFAULT_SIGNAL_SETTINGS,
  generateSignals,
} from "@/lib/signal-engine";
'@
if ($page.Contains($oldEngineImport)) {
    $page = $page.Replace(
        $oldEngineImport,
        $newEngineImport
    )
}
elseif (!$page.Contains("DEFAULT_SIGNAL_SETTINGS")) {
    throw "Signals page engine import marker tidak ditemukan."
}

$page = [regex]::Replace(
    $page,
    '(?s)const SETTINGS_KEY\s*=\s*"memescope-signal-settings";\s*',
    '',
    1
)

$page = [regex]::Replace(
    $page,
    '(?s)const DEFAULT_SETTINGS:\s*SignalSettings\s*=\s*\{.*?\};\s*',
    '',
    1
)

$page = $page.Replace(
    '      DEFAULT_SETTINGS,',
    '      DEFAULT_SIGNAL_SETTINGS,'
)

$page = [regex]::Replace(
    $page,
    '(?s)\n  useEffect\(\(\) => \{\s*const raw\s*=\s*localStorage\.getItem\(\s*SETTINGS_KEY,\s*\);.*?\n  \}, \[\]\);\s*',
    "`n",
    1
)

$loadMarker = @'
  async function load(
'@

if (!$page.Contains("loadSignalSettings")) {
    $loadIndex =
      $page.IndexOf(
        $loadMarker
      )

    if ($loadIndex -lt 0) {
        throw "Signals page load marker tidak ditemukan."
    }

$settingsEffect = @'
  useEffect(() => {
    let cancelled = false;

    async function loadSignalSettings() {
      try {
        const response =
          await fetch(
            "/api/signals/engine-settings",
            {
              cache: "no-store",
            },
          );

        const body =
          (await response.json()) as {
            settings?: SignalSettings;
          };

        if (
          response.ok &&
          body.settings &&
          !cancelled
        ) {
          setSettings(
            body.settings,
          );
        }
      } catch {
        // Keep server defaults if the read-only settings endpoint is temporarily unavailable.
      }
    }

    void loadSignalSettings();

    const timer =
      window.setInterval(
        () => {
          void loadSignalSettings();
        },
        30_000,
      );

    return () => {
      cancelled = true;
      window.clearInterval(
        timer,
      );
    };
  }, []);

'@

    $page =
      $page.Substring(
        0,
        $loadIndex
      ) +
      $settingsEffect +
      $page.Substring(
        $loadIndex
      )
}

$oldGenerateCall = @'
    return generateSignals(
      data?.tokens ?? [],
    );
  }, [data]);
'@
$newGenerateCall = @'
    return generateSignals(
      data?.tokens ?? [],
      settings,
    );
  }, [data, settings]);
'@
if ($page.Contains($oldGenerateCall)) {
    $page =
      $page.Replace(
        $oldGenerateCall,
        $newGenerateCall
      )
}
elseif (!$page.Contains("data, settings")) {
    throw "Signals page generateSignals marker tidak ditemukan."
}

$page = [regex]::Replace(
    $page,
    '(?s)\n  useEffect\(\(\) => \{\s*localStorage\.setItem\(\s*SETTINGS_KEY,.*?\n  \}, \[settings\]\);\s*',
    "`n",
    1
)

$placeholderIndex =
  $page.IndexOf(
    'placeholder="Search token, symbol or mint"'
  )

if ($placeholderIndex -lt 0) {
    throw "Search box marker tidak ditemukan."
}

$sectionStart =
  $page.LastIndexOf(
    '      <section',
    $placeholderIndex
  )

$presetStart =
  $page.IndexOf(
    '      <SignalPresetManager',
    $placeholderIndex
  )

if (
  $sectionStart -lt 0 -or
  $presetStart -lt 0
) {
    throw "Signal filter UI markers tidak ditemukan."
}

$presetEnd =
  $page.IndexOf(
    '      />',
    $presetStart
  )

if ($presetEnd -lt 0) {
    throw "Signal preset component end marker tidak ditemukan."
}

$presetEnd +=
  '      />'.Length

$searchOnly = @'
      <section className="mb-5 rounded-2xl border border-white/10 bg-white/[0.02] p-4">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />

          <input
            value={query}
            onChange={(event) =>
              setQuery(event.target.value)
            }
            placeholder="Search token, symbol or mint"
            className="w-full rounded-xl border border-white/10 bg-black/25 py-3 pl-10 pr-3 text-sm text-white outline-none placeholder:text-zinc-700 focus:border-emerald-400/30"
          />
        </div>

        <div className="mt-3 text-[10px] leading-4 text-zinc-700">
          Signal-engine thresholds are managed server-side by the MemeScope owner.
        </div>
      </section>
'@

$page =
  $page.Substring(
    0,
    $sectionStart
  ) +
  $searchOnly +
  $page.Substring(
    $presetEnd
  )

$page = [regex]::Replace(
    $page,
    '(?m)^\s*SlidersHorizontal,\s*\r?\n',
    '',
    1
)

if (
  $page.Contains(
    "SignalPresetManager"
  ) -or
  $page.Contains(
    "SETTINGS_KEY"
  )
) {
    throw "Website settings removal validation failed."
}

if (
  !$page.Contains(
    "/api/signals/engine-settings"
  )
) {
    throw "Website server settings sync validation failed."
}

if ($page -ne $pageOriginal) {
    [System.IO.File]::WriteAllText(
        $signalsPagePath,
        $page,
        $utf8
    )
    Write-Host "Updated: /signals is now client read-only." -ForegroundColor Green
}

$presetComponent =
  Join-Path $root "src/components/signal-preset-manager.tsx"

if (Test-Path $presetComponent) {
    Remove-Item -LiteralPath $presetComponent -Force
    Write-Host "Removed: signal-preset-manager.tsx" -ForegroundColor Green
}

# ============================================================
# 7. PERFORMANCE PANEL: REMOVE CLIENT RECORDER CONTROLS/HEARTBEAT
# ============================================================

$panelPath =
  Join-Path $root "src/components/signal-performance-panel.tsx"

$panel =
  [System.IO.File]::ReadAllText(
    $panelPath
  )

$panelOriginal =
  $panel

$panel = [regex]::Replace(
    $panel,
    '(?s)\n  const \[\s*recording,\s*setRecording,\s*\]\s*=\s*useState\(false\);\s*',
    "`n",
    1
)

$runStart =
  $panel.IndexOf(
    "  const runRecorder ="
  )

$loadEffectMarker = @'
  useEffect(() => {
    void loadData();
  }, [loadData]);
'@

if ($runStart -ge 0) {
    $loadEffectIndex =
      $panel.IndexOf(
        $loadEffectMarker,
        $runStart
      )

    if ($loadEffectIndex -lt 0) {
        throw "Performance panel loadData effect marker tidak ditemukan."
    }

    $panel =
      $panel.Substring(
        0,
        $runStart
      ) +
      $panel.Substring(
        $loadEffectIndex
      )
}

$loadEffectIndex =
  $panel.IndexOf(
    $loadEffectMarker
  )

$nowEffectMarker = @'
  useEffect(() => {
    const timer =
      window.setInterval(
        () =>
          setNow(Date.now()),
'@

$nowEffectIndex =
  $panel.IndexOf(
    $nowEffectMarker
  )

if (
  $loadEffectIndex -ge 0 -and
  $nowEffectIndex -gt $loadEffectIndex
) {
    $loadEffectEnd =
      $loadEffectIndex +
      $loadEffectMarker.Length

    $between =
      $panel.Substring(
        $loadEffectEnd,
        $nowEffectIndex -
        $loadEffectEnd
      )

    if (
      $between.Contains(
        "runRecorder"
      )
    ) {
      $panel =
        $panel.Substring(
          0,
          $loadEffectEnd
        ) +
        "`r`n`r`n" +
        $panel.Substring(
          $nowEffectIndex
        )
    }
}

$recordNow =
  $panel.IndexOf(
    "Record now"
  )

if ($recordNow -ge 0) {
    $buttonStart =
      $panel.LastIndexOf(
        "          <button",
        $recordNow
      )

    $buttonEnd =
      $panel.IndexOf(
        "          </button>",
        $recordNow
      )

    if (
      $buttonStart -lt 0 -or
      $buttonEnd -lt 0
    ) {
      throw "Record now button markers tidak ditemukan."
    }

    $buttonEnd +=
      "          </button>".Length

    $replacement = @'
          <div className="rounded-xl border border-white/10 px-3 py-2 text-[10px] text-zinc-600">
            Server recorder runs automatically.
          </div>
'@

    $panel =
      $panel.Substring(
        0,
        $buttonStart
      ) +
      $replacement +
      $panel.Substring(
        $buttonEnd
      )
}

if (
  $panel.Contains(
    "runRecorder"
  ) -or
  $panel.Contains(
    "Record now"
  )
) {
    throw "Performance panel recorder-control removal validation failed."
}

if ($panel -ne $panelOriginal) {
    [System.IO.File]::WriteAllText(
        $panelPath,
        $panel,
        $utf8
    )
    Write-Host "Updated: performance panel is read-only." -ForegroundColor Green
}

# ============================================================
# 8. TELEGRAM BOT OWNER-ONLY WEBHOOK + SIGNAL SETTINGS COMMANDS
# ============================================================

$webhookPath =
  Join-Path $root "src/app/api/telegram/webhook/route.ts"

$webhook = @'
import {
  NextResponse,
} from "next/server";

import {
  applySignalPreset,
  getSignalEngineSettings,
  resetSignalEngineSettings,
  saveSignalEngineSettings,
  signalPresetName,
  type SignalPresetName,
} from "@/lib/signal-engine-settings";
import type {
  SignalSettings,
} from "@/lib/signal-types";
import {
  escapeTelegramHtml,
  telegramConfig,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

type TelegramUpdate = {
  message?: {
    message_id?: number;
    text?: string;
    chat?: {
      id?: number;
    };
    from?: {
      id?: number;
      username?: string;
      first_name?: string;
    };
  };
};

function validSolanaAddress(
  value: string,
) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
    value,
  );
}

function compactUsd(
  value: number,
) {
  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(0)}K`;
  }

  return `$${value.toFixed(0)}`;
}

function settingsText(
  settings: SignalSettings,
) {
  const preset =
    signalPresetName(
      settings,
    );

  return [
    "<b>MEMESCOPE OWNER CONTROL</b>",
    "",
    `Preset: <b>${escapeTelegramHtml(
      preset.toUpperCase(),
    )}</b>`,
    "",
    "<b>Owner-adjustable filters</b>",
    `Minimum score: <b>${settings.minSignalScore}</b>`,
    `Minimum liquidity: <b>${compactUsd(
      settings.minLiquidityUsd,
    )}</b>`,
    `Maximum pair age: <b>${settings.maxPairAgeHours}h</b>`,
    "",
    "<b>Fixed Stage 16 HQ gates</b>",
    "5m volume >= $10K",
    "5m transactions >= 40",
    "Buy pressure 60% - 88%",
    "Volume spike 1.30x - 3.50x",
    "5m momentum +2% - +15%",
    "1h momentum -5% - +120%",
    "Liquidity / valuation >= 8%",
    "Confirmation: 2 consecutive scans",
    "Potential TP: dynamic analysis-based",
    "",
    "<b>Commands</b>",
    "/preset strict",
    "/preset balanced",
    "/preset broad",
    "/setscore 85",
    "/setliq 75000",
    "/setage 18",
    "/resetsettings",
    "",
    "<i>Changes apply to new signal detection. Existing recorded entries keep their original entry snapshot and target.</i>",
  ].join("\n");
}

function helpText() {
  return [
    "<b>MemeScope Owner Bot</b>",
    "",
    "<b>Engine control</b>",
    "/settings - current live engine settings",
    "/preset &lt;strict|balanced|broad&gt;",
    "/setscore &lt;60-95&gt;",
    "/setliq &lt;10000-1000000&gt;",
    "/setage &lt;1-168 hours&gt;",
    "/resetsettings - restore Stage 16 defaults",
    "",
    "<b>Monitoring</b>",
    "/signals - active HQ signals",
    "/history - recent signal history",
    "/stats - 30-day signal statistics",
    "/token &lt;CA&gt; - open token",
    "/risk &lt;CA&gt; - open risk analysis",
    "/channel - signal channel",
    "/whoami - show your Telegram user ID",
    "/help - commands",
    "",
    "<i>Signal scores and Potential TP are analytical heuristics, not guaranteed returns.</i>",
  ].join("\n");
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
    number > 0 ? "+" : ""
  }${number.toFixed(2)}%`;
}

async function reply(
  chatId: number,
  messageId: number | undefined,
  text: string,
) {
  return telegramSendMessage(
    chatId,
    text,
    {
      replyToMessageId:
        messageId,
    },
  );
}

function oneNumber(
  value: string,
) {
  const number =
    Number(
      value.trim(),
    );

  return Number.isFinite(
    number,
  )
    ? number
    : null;
}

export async function POST(
  request: Request,
) {
  const {
    webhookSecret,
    channelUrl,
  } = telegramConfig();

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
  ] = rawText.split(/\s+/);

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
        "",
        "Use this value as TELEGRAM_OWNER_ID in Vercel Production.",
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  const ownerId =
    process.env
      .TELEGRAM_OWNER_ID
      ?.trim() ??
    "";

  if (!ownerId) {
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
        "",
        "Set this as TELEGRAM_OWNER_ID in Vercel Production, redeploy, then run the Telegram bootstrap endpoint.",
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  if (
    !userId ||
    String(userId) !==
      ownerId
  ) {
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
        settingsText(
          settings,
        ),
      );
    } else if (
      command === "/preset"
    ) {
      const preset =
        argument.toLowerCase();

      if (
        preset !== "strict" &&
        preset !== "balanced" &&
        preset !== "broad"
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: <code>/preset strict</code>, <code>/preset balanced</code>, or <code>/preset broad</code>.",
        );
      } else {
        const settings =
          await applySignalPreset(
            preset as SignalPresetName,
          );

        await reply(
          chatId,
          message.message_id,
          [
            `Preset updated to <b>${escapeTelegramHtml(
              preset.toUpperCase(),
            )}</b>.`,
            "",
            settingsText(
              settings,
            ),
          ].join("\n"),
        );
      }
    } else if (
      command === "/setscore"
    ) {
      const value =
        oneNumber(
          argument,
        );

      if (
        value === null ||
        value < 60 ||
        value > 95
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: <code>/setscore 85</code> (allowed 60-95).",
        );
      } else {
        const settings =
          await saveSignalEngineSettings({
            minSignalScore:
              Math.round(
                value,
              ),
          });

        await reply(
          chatId,
          message.message_id,
          [
            "<b>Minimum signal score updated.</b>",
            "",
            settingsText(
              settings,
            ),
          ].join("\n"),
        );
      }
    } else if (
      command === "/setliq"
    ) {
      const value =
        oneNumber(
          argument,
        );

      if (
        value === null ||
        value < 10_000 ||
        value > 1_000_000
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: <code>/setliq 75000</code> (allowed 10000-1000000 USD).",
        );
      } else {
        const settings =
          await saveSignalEngineSettings({
            minLiquidityUsd:
              Math.round(
                value,
              ),
          });

        await reply(
          chatId,
          message.message_id,
          [
            "<b>Minimum liquidity updated.</b>",
            "",
            settingsText(
              settings,
            ),
          ].join("\n"),
        );
      }
    } else if (
      command === "/setage"
    ) {
      const value =
        oneNumber(
          argument,
        );

      if (
        value === null ||
        value < 1 ||
        value > 168
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: <code>/setage 24</code> (allowed 1-168 hours).",
        );
      } else {
        const settings =
          await saveSignalEngineSettings({
            maxPairAgeHours:
              Math.round(
                value,
              ),
          });

        await reply(
          chatId,
          message.message_id,
          [
            "<b>Maximum pair age updated.</b>",
            "",
            settingsText(
              settings,
            ),
          ].join("\n"),
        );
      }
    } else if (
      command ===
      "/resetsettings"
    ) {
      const settings =
        await resetSignalEngineSettings();

      await reply(
        chatId,
        message.message_id,
        [
          "<b>Stage 16 default settings restored.</b>",
          "",
          settingsText(
            settings,
          ),
        ].join("\n"),
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
          `Usage: <code>${command} &lt;Solana CA&gt;</code>`,
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

[System.IO.File]::WriteAllText(
    $webhookPath,
    $webhook,
    $utf8
)
Write-Host "Updated: owner-only Telegram webhook." -ForegroundColor Green

# ============================================================
# 9. TELEGRAM COMMAND MENU
# ============================================================

$telegramPath =
  Join-Path $root "src/lib/telegram.ts"

$telegram =
  [System.IO.File]::ReadAllText(
    $telegramPath
  )

$commandsStart =
  $telegram.IndexOf(
    "export async function telegramSetCommands()"
  )

$webhookStart =
  $telegram.IndexOf(
    "export async function telegramSetWebhook("
  )

if (
  $commandsStart -lt 0 -or
  $webhookStart -le $commandsStart
) {
    throw "telegramSetCommands block markers tidak ditemukan."
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
            "Owner signal settings",
        },
        {
          command: "preset",
          description:
            "Apply strict/balanced/broad preset",
        },
        {
          command: "setscore",
          description:
            "Set minimum signal score",
        },
        {
          command: "setliq",
          description:
            "Set minimum liquidity",
        },
        {
          command: "setage",
          description:
            "Set maximum pair age",
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
            "Open a token by contract address",
        },
        {
          command: "risk",
          description:
            "Open MemeScope risk analysis",
        },
        {
          command: "channel",
          description:
            "Open the signal channel",
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

$telegram =
  $telegram.Substring(
    0,
    $commandsStart
  ) +
  $commandsBlock +
  $telegram.Substring(
    $webhookStart
  )

[System.IO.File]::WriteAllText(
    $telegramPath,
    $telegram,
    $utf8
)
Write-Host "Updated: Telegram command menu." -ForegroundColor Green

# ============================================================
# 10. ENV EXAMPLE
# ============================================================

$envExample =
  Join-Path $root ".env.example"

if (Test-Path $envExample) {
    $envText =
      [System.IO.File]::ReadAllText(
        $envExample
      )

    if (
      !$envText.Contains(
        "TELEGRAM_OWNER_ID="
      )
    ) {
      $envText +=
        "`r`nTELEGRAM_OWNER_ID=`r`n"

      [System.IO.File]::WriteAllText(
        $envExample,
        $envText,
        $utf8
      )
    }
}

# ============================================================
# 11. CLEAN CACHE + SUMMARY
# ============================================================

Remove-Item `
  (Join-Path $root ".next") `
  -Recurse -Force `
  -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 19 installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Result:" -ForegroundColor Cyan
Write-Host " - website signal settings removed"
Write-Host " - website signal page reads server settings silently"
Write-Host " - browser recorder controls removed"
Write-Host " - recorder endpoint protected by CRON_SECRET"
Write-Host " - Cloudflare/Telegram cron remains the server recorder trigger"
Write-Host " - signal settings stored in Neon"
Write-Host " - Telegram bot is owner-only after TELEGRAM_OWNER_ID is set"
Write-Host " - /settings /preset /setscore /setliq /setage /resetsettings"
Write-Host " - fixed Stage 16 quality gates remain unchanged"
Write-Host ""
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
Write-Host ""
