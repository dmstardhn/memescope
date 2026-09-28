$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 15.2 - Live Gain Tracking Fix" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$dbPath = Join-Path $root "src/lib/signal-recorder-db.ts"
$panelPath = Join-Path $root "src/components/signal-performance-panel.tsx"

if (!(Test-Path -LiteralPath $dbPath)) {
    throw "src/lib/signal-recorder-db.ts tidak ditemukan."
}

if (!(Test-Path -LiteralPath $panelPath)) {
    throw "src/components/signal-performance-panel.tsx tidak ditemukan."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $root ".backup-stage15-live-gain-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

Copy-Item -LiteralPath $dbPath -Destination (Join-Path $backup "signal-recorder-db.ts.bak") -Force
Copy-Item -LiteralPath $panelPath -Destination (Join-Path $backup "signal-performance-panel.tsx.bak") -Force

Write-Host "Backup: $backup" -ForegroundColor DarkGray

# =========================================================
# 1. Server recorder: fetch current prices directly from
#    DexScreener for ALL active signal tokens.
# =========================================================

$db = [System.IO.File]::ReadAllText($dbPath)

if ($db -notmatch 'async function fetchTrackedTokenPrices') {

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

  // DexScreener accepts multiple Solana token addresses.
  // Keep batches small so URLs remain safe and predictable.
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

        // Use the most liquid market for the token so the
        // tracked price is less affected by tiny side pools.
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
      // Keep the recorder alive if DexScreener has a temporary failure.
    }
  }

  return prices;
}

'@

    $marker = 'export async function recordSignalSnapshot('
    $idx = $db.IndexOf($marker)

    if ($idx -lt 0) {
        throw "Marker recordSignalSnapshot tidak ditemukan. Tidak ada file yang diubah."
    }

    $db =
        $db.Substring(0, $idx) +
        $helper +
        $db.Substring($idx)

    Write-Host "Added direct tracked-token price fetcher." -ForegroundColor Green
}

# Insert active tracked-price fetch after activeRecords is created.
if ($db -notmatch 'const trackedPrices\s*=') {
    $pattern = '(?s)(const activeRecords\s*=\s*activeRows\.map\(\s*\(row\)\s*=>\s*normalizeRecord\(\s*row as DbRow,\s*\),\s*\);)'

    $match = [regex]::Match($db, $pattern)

    if (!$match.Success) {
        throw "Blok activeRecords tidak ditemukan. Tidak ada file yang diubah."
    }

$insert = @'

  const trackedPrices =
    await fetchTrackedTokenPrices(
      activeRecords.map(
        (record) =>
          record.tokenAddress,
      ),
    );
'@

    $db = [regex]::Replace(
        $db,
        $pattern,
        '$1' + $insert,
        1
    )

    Write-Host "Active signal tokens now get independent live prices." -ForegroundColor Green
}

# Prefer the independently fetched tracked price for active records.
$oldCurrent = @'
    const currentPrice =
      token?.priceUsd ?? signal?.priceUsd ?? record.currentPriceUsd;
'@

$newCurrent = @'
    const currentPrice =
      trackedPrices.get(
        record.tokenAddress,
      ) ??
      token?.priceUsd ??
      signal?.priceUsd ??
      record.currentPriceUsd;
'@

if ($db.Contains($oldCurrent)) {
    $db = $db.Replace(
        $oldCurrent,
        $newCurrent
    )

    Write-Host "Recorder current-price priority fixed." -ForegroundColor Green
} elseif ($db -notmatch 'trackedPrices\.get\(\s*record\.tokenAddress') {
    throw "Blok currentPrice active record tidak cocok. Tidak ada file yang diubah."
}

[System.IO.File]::WriteAllText(
    $dbPath,
    $db,
    $utf8
)

# =========================================================
# 2. Client panel: recorder heartbeat every 10 seconds.
#    Previously the 20s timer only reloaded DB history;
#    it did not guarantee a fresh market-price recording.
# =========================================================

$panel = [System.IO.File]::ReadAllText($panelPath)

$oldEffect = @'
  useEffect(() => {
    if (configured !== true) return;

    const timer = window.setInterval(() => {
      void loadData();
    }, 20_000);

    return () => window.clearInterval(timer);
  }, [configured, loadData]);
'@

$newEffect = @'
  useEffect(() => {
    if (configured !== true) return;

    // Near-real-time heartbeat while Signal Calls is open.
    // Each cycle records fresh server-side prices first,
    // then reloads history/analytics.
    const timer = window.setInterval(() => {
      void runRecorder(true);
    }, 10_000);

    return () => window.clearInterval(timer);
  }, [configured, runRecorder]);
'@

if ($panel.Contains($oldEffect)) {
    $panel = $panel.Replace(
        $oldEffect,
        $newEffect
    )

    Write-Host "Signal history heartbeat changed to 10 seconds." -ForegroundColor Green
} elseif ($panel -match 'window\.setInterval\(\(\)\s*=>\s*\{\s*void runRecorder\(true\);') {
    Write-Host "10-second recorder heartbeat already installed." -ForegroundColor Yellow
} else {
    throw "Polling block signal-performance-panel tidak cocok. Tidak ada file yang diubah."
}

# Update wording so the UI accurately describes the behavior.
$panel = $panel.Replace(
    'Stored in PostgreSQL, not browser localStorage.',
    'Stored in PostgreSQL and refreshed from tracked market prices about every 10 seconds while this page is open.'
)

[System.IO.File]::WriteAllText(
    $panelPath,
    $panel,
    $utf8
)

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Live Gain Tracking fix installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "What changed:" -ForegroundColor Cyan
Write-Host " - active signals fetch their token price directly from DexScreener"
Write-Host " - tracking continues even if token disappears from Scanner candidates"
Write-Host " - server history is recorded every ~10 seconds while /signals is open"
Write-Host " - gain, peak gain, drawdown, TP/SL can now move with observed price"
Write-Host ""
Write-Host "This is near-real-time (10s), not tick-by-tick." -ForegroundColor Yellow
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run build"
Write-Host ""
