$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 15.2 v2 - Live Gain Tracking Fix" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$dbPath = Join-Path $root "src/lib/signal-recorder-db.ts"
$panelPath = Join-Path $root "src/components/signal-performance-panel.tsx"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath $dbPath)) {
    throw "src/lib/signal-recorder-db.ts tidak ditemukan."
}

if (!(Test-Path -LiteralPath $panelPath)) {
    throw "src/components/signal-performance-panel.tsx tidak ditemukan."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $root ".backup-stage15-live-gain-v2-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

Copy-Item -LiteralPath $dbPath -Destination (Join-Path $backup "signal-recorder-db.ts.bak") -Force
Copy-Item -LiteralPath $panelPath -Destination (Join-Path $backup "signal-performance-panel.tsx.bak") -Force

Write-Host "Backup: $backup" -ForegroundColor DarkGray

# ---------------------------------------------------------
# Helper: insert text after a complete const declaration.
# Uses the first semicolon after the anchor instead of relying
# on exact formatting/newlines.
# ---------------------------------------------------------
function Insert-AfterDeclaration {
    param(
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$true)][string]$Anchor,
        [Parameter(Mandatory=$true)][string]$InsertText
    )

    $start = $Content.IndexOf($Anchor)

    if ($start -lt 0) {
        throw "Anchor tidak ditemukan: $Anchor"
    }

    $semicolon = $Content.IndexOf(";", $start)

    if ($semicolon -lt 0) {
        throw "Akhir declaration tidak ditemukan setelah: $Anchor"
    }

    return (
        $Content.Substring(0, $semicolon + 1) +
        $InsertText +
        $Content.Substring($semicolon + 1)
    )
}

# =========================================================
# 1. PATCH SERVER RECORDER
# =========================================================

$db = [System.IO.File]::ReadAllText($dbPath)
$originalDb = $db

if ($db -notmatch 'async function fetchTrackedTokenPrices\s*\(') {

$helper = @'

type DexPricePair = {
  chainId?: string;
  priceUsd?: string;
  baseToken?: {
    address?: string;
  };
  liquidity?: {
    usd?: number;
  };
};

async function fetchTrackedTokenPrices(
  addresses: string[],
) {
  const unique = Array.from(
    new Set(
      addresses.filter(Boolean),
    ),
  );

  const prices = new Map<
    string,
    number
  >();

  for (
    let index = 0;
    index < unique.length;
    index += 30
  ) {
    const batch =
      unique.slice(
        index,
        index + 30,
      );

    if (
      batch.length === 0
    ) {
      continue;
    }

    try {
      const url =
        `https://api.dexscreener.com/tokens/v1/solana/${batch.join(
          ",",
        )}`;

      const response =
        await fetch(
          url,
          {
            cache: "no-store",
            headers: {
              accept:
                "application/json",
            },
          },
        );

      if (!response.ok) {
        continue;
      }

      const pairs =
        (await response.json()) as DexPricePair[];

      const bestLiquidity =
        new Map<
          string,
          number
        >();

      for (
        const pair of pairs
      ) {
        const address =
          pair.baseToken?.address;

        const parsedPrice =
          Number(
            pair.priceUsd,
          );

        if (
          !address ||
          !Number.isFinite(
            parsedPrice,
          ) ||
          parsedPrice <= 0
        ) {
          continue;
        }

        const liquidity =
          Number(
            pair.liquidity?.usd ??
              0,
          );

        const previousLiquidity =
          bestLiquidity.get(
            address,
          ) ?? -1;

        if (
          liquidity >=
          previousLiquidity
        ) {
          prices.set(
            address,
            parsedPrice,
          );

          bestLiquidity.set(
            address,
            liquidity,
          );
        }
      }
    } catch {
      // Keep existing stored price if DexScreener temporarily fails.
    }
  }

  return prices;
}

'@

    $marker = 'export async function recordSignalSnapshot('
    $idx = $db.IndexOf($marker)

    if ($idx -lt 0) {
        throw "recordSignalSnapshot tidak ditemukan. Tidak ada file yang ditulis."
    }

    $db =
        $db.Substring(0, $idx) +
        $helper +
        $db.Substring($idx)

    Write-Host "Added tracked-token DexScreener price helper." -ForegroundColor Green
}

if ($db -notmatch 'const\s+trackedPrices\s*=') {

    # Prefer activeRecords declaration. We only need its variable to exist.
    if ($db.Contains("const activeRecords")) {
$insert = @'

  const trackedPrices =
    await fetchTrackedTokenPrices(
      activeRecords.map(
        (record) =>
          record.tokenAddress,
      ),
    );
'@

        $db = Insert-AfterDeclaration `
            -Content $db `
            -Anchor "const activeRecords" `
            -InsertText $insert

        Write-Host "Inserted trackedPrices after activeRecords." -ForegroundColor Green
    }
    else {
        throw "Declaration 'const activeRecords' tidak ditemukan. Tidak ada file yang ditulis."
    }
}

# Replace only the current-price expression inside the ACTIVE RECORD loop.
if ($db -notmatch 'trackedPrices\.get\(\s*record\.tokenAddress') {

    $recordLoop = $db.IndexOf("for (const record of activeRecords)")

    if ($recordLoop -lt 0) {
        $recordLoop = $db.IndexOf("for (`r`n    const record of activeRecords")
    }

    if ($recordLoop -lt 0) {
        $recordLoop = $db.IndexOf("activeRecords")
    }

    if ($recordLoop -lt 0) {
        throw "Loop activeRecords tidak ditemukan. Tidak ada file yang ditulis."
    }

    $currentStart = $db.IndexOf("const currentPrice", $recordLoop)

    if ($currentStart -lt 0) {
        throw "currentPrice untuk active record tidak ditemukan. Tidak ada file yang ditulis."
    }

    $currentEnd = $db.IndexOf(";", $currentStart)

    if ($currentEnd -lt 0) {
        throw "Akhir declaration currentPrice tidak ditemukan. Tidak ada file yang ditulis."
    }

$newCurrent = @'
const currentPrice =
      trackedPrices.get(
        record.tokenAddress,
      ) ??
      token?.priceUsd ??
      signal?.priceUsd ??
      record.currentPriceUsd
'@

    $db =
        $db.Substring(0, $currentStart) +
        $newCurrent +
        $db.Substring($currentEnd)

    Write-Host "Active record now prefers independently tracked price." -ForegroundColor Green
}

# Validate before writing.
if ($db -notmatch 'async function fetchTrackedTokenPrices\s*\(') {
    throw "Validasi helper gagal. Tidak ada file yang ditulis."
}

if ($db -notmatch 'const\s+trackedPrices\s*=') {
    throw "Validasi trackedPrices gagal. Tidak ada file yang ditulis."
}

if ($db -notmatch 'trackedPrices\.get\(\s*record\.tokenAddress') {
    throw "Validasi currentPrice gagal. Tidak ada file yang ditulis."
}

if ($db -ne $originalDb) {
    [System.IO.File]::WriteAllText(
        $dbPath,
        $db,
        $utf8
    )

    Write-Host "Updated: src/lib/signal-recorder-db.ts" -ForegroundColor Green
}
else {
    Write-Host "Server recorder patch already present." -ForegroundColor Yellow
}

# =========================================================
# 2. PATCH CLIENT HEARTBEAT
# =========================================================

$panel = [System.IO.File]::ReadAllText($panelPath)
$originalPanel = $panel

if ($panel -notmatch 'void\s+runRecorder\(true\);\s*\}\s*,\s*10_000') {

    # Find the periodic loadData timer and change only that timer.
    $timerPattern =
        '(?s)const timer\s*=\s*window\.setInterval\(\s*\(\)\s*=>\s*\{\s*void\s+loadData\(\);\s*\},\s*20_000,\s*\);'

    if ([regex]::IsMatch($panel, $timerPattern)) {
$newTimer = @'
const timer =
      window.setInterval(
        () => {
          void runRecorder(true);
        },
        10_000,
      );
'@

        $panel = [regex]::Replace(
            $panel,
            $timerPattern,
            $newTimer,
            1
        )

        # The effect dependency also needs runRecorder instead of loadData.
        $dependencyPattern =
            '(?s)(if\s*\(\s*configured\s*!==\s*true\s*\)\s*\{\s*return;\s*\}.*?return\s*\(\)\s*=>\s*window\.clearInterval\(timer\);\s*\},\s*\[\s*configured,\s*)loadData(\s*,?\s*\]\s*\);)'

        if ([regex]::IsMatch($panel, $dependencyPattern)) {
            $panel = [regex]::Replace(
                $panel,
                $dependencyPattern,
                '$1runRecorder$2',
                1
            )
        }

        Write-Host "Changed browser heartbeat to recorder every 10 seconds." -ForegroundColor Green
    }
    elseif ($panel -match 'runRecorder\(true\)') {
        Write-Host "Recorder heartbeat already appears to be installed." -ForegroundColor Yellow
    }
    else {
        throw "Timer loadData 20 detik tidak ditemukan. Panel tidak ditulis."
    }
}

$panel = $panel.Replace(
    'Stored in PostgreSQL, not browser localStorage.',
    'Stored in PostgreSQL and refreshed from tracked market prices about every 10 seconds while this page is open.'
)

if ($panel -ne $originalPanel) {
    [System.IO.File]::WriteAllText(
        $panelPath,
        $panel,
        $utf8
    )

    Write-Host "Updated: src/components/signal-performance-panel.tsx" -ForegroundColor Green
}

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 15.2 v2 installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Gain tracking now:" -ForegroundColor Cyan
Write-Host " - fetches active-token prices independently"
Write-Host " - does not depend on Scanner candidate membership"
Write-Host " - records every ~10s while /signals is open"
Write-Host " - updates Gain / Peak / Drawdown / TP / SL"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run build"
Write-Host ""
