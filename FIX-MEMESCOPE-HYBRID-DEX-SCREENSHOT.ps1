$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this script from the memecoin-analyst project root."
}

$path = Join-Path $root "src\lib\content-hq.ts"
if (!(Test-Path -LiteralPath $path)) {
    throw "Missing file: $path"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-HybridScreenshot-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "content-hq.ts") -Force

$content = [System.IO.File]::ReadAllText($path)

$start = $content.IndexOf("async function captureRawScreenshot(")
$end = $content.IndexOf("async function annotateScreenshot(", $start)

if ($start -lt 0 -or $end -le $start) {
    throw "Screenshot capture block markers were not found. No file was changed."
}

$captureBlock = @'
type RawScreenshotResult = {
  buffer: Buffer;
  challengeDetected: boolean;
};

type DexMarketSnapshot = {
  pairAddress: string | null;
  dexId: string | null;
  quoteSymbol: string | null;
  priceUsd: number | null;
  marketCapUsd: number | null;
  liquidityUsd: number | null;
  volume24hUsd: number | null;
  buys5m: number | null;
  sells5m: number | null;
  change5mPct: number | null;
  change1hPct: number | null;
};

type CandlePoint = {
  timestamp: number;
  close: number;
};

async function captureRawScreenshot(
  url: string,
  source:
    VisualSource,
): Promise<RawScreenshotResult> {
  const executablePath =
    await chromium.executablePath();

  const browser =
    await playwrightChromium.launch(
      {
        args:
          chromium.args,
        executablePath,
        headless: true,
      },
    );

  try {
    const page =
      await browser.newPage({
        viewport: {
          width: 1600,
          height: 900,
        },
        deviceScaleFactor: 1,
      });

    await page.goto(
      url,
      {
        waitUntil:
          "domcontentloaded",
        timeout: 35_000,
      },
    );

    await page.waitForTimeout(
      source ===
      "gmgn"
        ? 7_000
        : 5_000,
    );

    const challengeDetected =
      await page
        .evaluate(() => {
          const body =
            (
              document.body
                ?.innerText ??
              ""
            ).toLowerCase();

          const title =
            document.title
              .toLowerCase();

          const securityText =
            body.includes(
              "performing security verification",
            ) ||
            body.includes(
              "verify you are human",
            ) ||
            body.includes(
              "checking your browser",
            ) ||
            title.includes(
              "just a moment",
            );

          const securityUi =
            Boolean(
              document.querySelector(
                [
                  'iframe[src*="challenges.cloudflare.com"]',
                  '[name="cf-turnstile-response"]',
                  "#challenge-stage",
                ].join(","),
              ),
            );

          return (
            securityText ||
            securityUi
          );
        })
        .catch(
          () => false,
        );

    if (!challengeDetected) {
      await page
        .evaluate(() => {
          const selectors = [
            '[class*="cookie"]',
            '[id*="cookie"]',
            '[class*="modal"]',
            '[class*="popup"]',
          ];

          for (
            const selector of selectors
          ) {
            document
              .querySelectorAll(
                selector,
              )
              .forEach(
                (node) => {
                  (
                    node as HTMLElement
                  ).style.display =
                    "none";
                },
              );
          }
        })
        .catch(
          () => undefined,
        );
    }

    return {
      buffer:
        Buffer.from(
          await page.screenshot({
            type: "png",
            fullPage: false,
          }),
        ),
      challengeDetected,
    };
  } finally {
    await browser.close();
  }
}

async function fetchDexMarketSnapshot(
  candidate:
    ContentCandidate,
): Promise<DexMarketSnapshot> {
  const response =
    await fetch(
      `https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(
        candidate.tokenAddress,
      )}`,
      {
        headers: {
          Accept:
            "application/json",
        },
        cache: "no-store",
      },
    );

  if (!response.ok) {
    throw new Error(
      `DEX Screener API returned ${response.status}.`,
    );
  }

  const body =
    (await response.json()) as {
      pairs?: Array<{
        chainId?: string;
        pairAddress?: string;
        dexId?: string;
        quoteToken?: {
          symbol?: string;
        };
        priceUsd?: string;
        marketCap?: number;
        fdv?: number;
        liquidity?: {
          usd?: number;
        };
        volume?: {
          h24?: number;
        };
        txns?: {
          m5?: {
            buys?: number;
            sells?: number;
          };
        };
        priceChange?: {
          m5?: number;
          h1?: number;
        };
      }>;
    };

  const pairs =
    (
      body.pairs ?? []
    ).filter(
      (pair) =>
        pair.chainId ===
        "solana",
    );

  const selected =
    pairs.find(
      (pair) =>
        candidate.pairAddress &&
        pair.pairAddress ===
          candidate.pairAddress,
    ) ??
    pairs.sort(
      (a, b) =>
        num(
          b.liquidity?.usd,
        ) -
        num(
          a.liquidity?.usd,
        ),
    )[0];

  if (!selected) {
    return {
      pairAddress:
        candidate.pairAddress,
      dexId: null,
      quoteSymbol: null,
      priceUsd: null,
      marketCapUsd:
        candidate.currentMarketCap,
      liquidityUsd:
        candidate.liquidityUsd,
      volume24hUsd:
        candidate.volumeUsd,
      buys5m: null,
      sells5m: null,
      change5mPct: null,
      change1hPct: null,
    };
  }

  return {
    pairAddress:
      selected.pairAddress ??
      candidate.pairAddress,
    dexId:
      selected.dexId ??
      null,
    quoteSymbol:
      selected.quoteToken
        ?.symbol ??
      null,
    priceUsd:
      selected.priceUsd
        ? num(
            selected.priceUsd,
            NaN,
          )
        : null,
    marketCapUsd:
      maybeNum(
        selected.marketCap ??
          selected.fdv,
      ),
    liquidityUsd:
      maybeNum(
        selected.liquidity
          ?.usd,
      ),
    volume24hUsd:
      maybeNum(
        selected.volume
          ?.h24,
      ),
    buys5m:
      maybeNum(
        selected.txns
          ?.m5
          ?.buys,
      ),
    sells5m:
      maybeNum(
        selected.txns
          ?.m5
          ?.sells,
      ),
    change5mPct:
      maybeNum(
        selected.priceChange
          ?.m5,
      ),
    change1hPct:
      maybeNum(
        selected.priceChange
          ?.h1,
      ),
  };
}

async function fetchGeckoCandles(
  pairAddress:
    string | null,
): Promise<CandlePoint[]> {
  if (!pairAddress) {
    return [];
  }

  const url =
    `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(
      pairAddress,
    )}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base`;

  try {
    const response =
      await fetch(
        url,
        {
          headers: {
            Accept:
              "application/json;version=20230203",
          },
          cache: "no-store",
        },
      );

    if (!response.ok) {
      return [];
    }

    const body =
      (await response.json()) as {
        data?: {
          attributes?: {
            ohlcv_list?:
              Array<
                Array<number>
              >;
          };
        };
      };

    return (
      body.data
        ?.attributes
        ?.ohlcv_list ??
      []
    )
      .map(
        (row) => ({
          timestamp:
            num(
              row[0],
            ) * 1000,
          close:
            num(
              row[4],
              NaN,
            ),
        }),
      )
      .filter(
        (point) =>
          Number.isFinite(
            point.timestamp,
          ) &&
          Number.isFinite(
            point.close,
          ) &&
          point.close > 0,
      )
      .sort(
        (a, b) =>
          a.timestamp -
          b.timestamp,
      );
  } catch {
    return [];
  }
}

function xmlText(
  value: string,
) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function formatPrice(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1) {
    return `$${value.toFixed(
      4,
    )}`;
  }

  if (value >= 0.01) {
    return `$${value.toFixed(
      6,
    )}`;
  }

  return `$${value.toPrecision(
    5,
  )}`;
}

function buildChartGeometry(
  candles:
    CandlePoint[],
  detectedAt:
    string,
) {
  const left = 90;
  const top = 178;
  const width = 1040;
  const height = 490;

  if (
    candles.length < 2
  ) {
    return {
      polyline: "",
      firstX: null as
        | number
        | null,
      firstY: null as
        | number
        | null,
      currentX: null as
        | number
        | null,
      currentY: null as
        | number
        | null,
    };
  }

  const values =
    candles.map(
      (point) =>
        point.close,
    );

  const min =
    Math.min(
      ...values,
    );

  const max =
    Math.max(
      ...values,
    );

  const range =
    Math.max(
      max - min,
      max * 0.015,
      1e-12,
    );

  const points =
    candles.map(
      (
        point,
        index,
      ) => {
        const x =
          left +
          (index /
            (candles.length -
              1)) *
            width;

        const y =
          top +
          height -
          ((point.close -
            min) /
            range) *
            height;

        return {
          x,
          y,
          timestamp:
            point.timestamp,
        };
      },
    );

  const detectedMs =
    new Date(
      detectedAt,
    ).getTime();

  let first:
    {
      x: number;
      y: number;
      timestamp: number;
    } | null =
    null;

  if (
    Number.isFinite(
      detectedMs,
    ) &&
    detectedMs >=
      candles[0].timestamp &&
    detectedMs <=
      candles[
        candles.length - 1
      ].timestamp
  ) {
    first =
      points.reduce(
        (
          best,
          point,
        ) =>
          Math.abs(
            point.timestamp -
              detectedMs,
          ) <
          Math.abs(
            best.timestamp -
              detectedMs,
          )
            ? point
            : best,
        points[0],
      );
  }

  const current =
    points[
      points.length - 1
    ];

  return {
    polyline:
      points
        .map(
          (point) =>
            `${point.x.toFixed(
              1,
            )},${point.y.toFixed(
              1,
            )}`,
        )
        .join(" "),
    firstX:
      first?.x ??
      null,
    firstY:
      first?.y ??
      null,
    currentX:
      current.x,
    currentY:
      current.y,
  };
}

async function renderDexFallback(
  candidate:
    ContentCandidate,
) {
  const market =
    await fetchDexMarketSnapshot(
      candidate,
    );

  const candles =
    await fetchGeckoCandles(
      market.pairAddress,
    );

  const chart =
    buildChartGeometry(
      candles,
      candidate.detectedAt,
    );

  const currentMc =
    market.marketCapUsd ??
    candidate.currentMarketCap;

  const liquidity =
    market.liquidityUsd ??
    candidate.liquidityUsd;

  const volume =
    market.volume24hUsd ??
    candidate.volumeUsd;

  const buySell =
    market.buys5m ===
      null &&
    market.sells5m === null
      ? "N/A"
      : `${market.buys5m ?? 0} / ${market.sells5m ?? 0}`;

  const chartBody =
    chart.polyline
      ? `<polyline points="${chart.polyline}" fill="none" stroke="#e6e6e6" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>
         <polyline points="${chart.polyline} 1130,668 90,668" fill="rgba(255,255,255,0.025)" stroke="none"/>`
      : `<text x="610" y="430" text-anchor="middle" class="muted">chart data temporarily unavailable</text>`;

  const firstMarker =
    chart.firstX !== null &&
    chart.firstY !== null
      ? `<circle cx="${chart.firstX}" cy="${chart.firstY}" r="7" fill="#ffffff"/>
         <line x1="${chart.firstX}" y1="${chart.firstY - 4}" x2="${chart.firstX}" y2="${chart.firstY - 58}" stroke="#ffffff" stroke-width="2"/>
         <text x="${chart.firstX}" y="${chart.firstY - 70}" text-anchor="middle" class="small">first spotted</text>`
      : "";

  const currentMarker =
    chart.currentX !== null &&
    chart.currentY !== null
      ? `<circle cx="${chart.currentX}" cy="${chart.currentY}" r="7" fill="#73e0aa"/>
         <line x1="${chart.currentX}" y1="${chart.currentY - 4}" x2="${chart.currentX}" y2="${chart.currentY - 58}" stroke="#73e0aa" stroke-width="2"/>
         <text x="${chart.currentX}" y="${chart.currentY - 70}" text-anchor="middle" class="small green">current</text>`
      : "";

  const svg =
    `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#0b0b0b"/>
      <style>
        .title { font-family: Arial, sans-serif; font-size: 36px; fill: #f3f3f3; font-weight: 700; }
        .sub { font-family: Arial, sans-serif; font-size: 18px; fill: #8e8e8e; }
        .label { font-family: Arial, sans-serif; font-size: 17px; fill: #777777; }
        .value { font-family: Arial, sans-serif; font-size: 30px; fill: #eeeeee; font-weight: 600; }
        .small { font-family: Arial, sans-serif; font-size: 17px; fill: #dddddd; }
        .green { fill: #73e0aa; }
        .muted { font-family: Arial, sans-serif; font-size: 22px; fill: #666666; }
      </style>

      <text x="72" y="68" class="title">$${xmlText(
        candidate.symbol,
      )} / ${xmlText(
        market.quoteSymbol ?? "SOL",
      )}</text>
      <text x="72" y="101" class="sub">${xmlText(
        market.dexId ?? "Solana DEX",
      )} | 5m</text>
      <text x="1528" y="70" text-anchor="end" class="sub">MemeScope</text>

      <line x1="72" y1="128" x2="1528" y2="128" stroke="#252525"/>

      <rect x="72" y="150" width="1080" height="548" rx="10" fill="#0d0d0d" stroke="#242424"/>
      <line x1="90" y1="668" x2="1130" y2="668" stroke="#242424"/>
      <line x1="90" y1="545" x2="1130" y2="545" stroke="#171717"/>
      <line x1="90" y1="422" x2="1130" y2="422" stroke="#171717"/>
      <line x1="90" y1="299" x2="1130" y2="299" stroke="#171717"/>

      ${chartBody}
      ${firstMarker}
      ${currentMarker}

      <rect x="1182" y="150" width="346" height="548" rx="10" fill="#0d0d0d" stroke="#242424"/>

      <text x="1215" y="201" class="label">price</text>
      <text x="1215" y="239" class="value">${xmlText(
        formatPrice(
          market.priceUsd,
        ),
      )}</text>

      <text x="1215" y="302" class="label">market cap</text>
      <text x="1215" y="340" class="value">${xmlText(
        compactUsd(
          currentMc,
        ),
      )}</text>

      <text x="1215" y="403" class="label">liquidity</text>
      <text x="1215" y="441" class="value">${xmlText(
        compactUsd(
          liquidity,
        ),
      )}</text>

      <text x="1215" y="504" class="label">24h volume</text>
      <text x="1215" y="542" class="value">${xmlText(
        compactUsd(
          volume,
        ),
      )}</text>

      <text x="1215" y="605" class="label">5m buys / sells</text>
      <text x="1215" y="643" class="value">${xmlText(
        buySell,
      )}</text>

      <rect x="72" y="728" width="456" height="105" rx="10" fill="#101010" stroke="#242424"/>
      <text x="100" y="766" class="label">first spotted</text>
      <text x="100" y="807" class="value">${xmlText(
        compactUsd(
          candidate.firstMarketCap,
        ),
      )} MC</text>

      <rect x="548" y="728" width="456" height="105" rx="10" fill="#101010" stroke="#242424"/>
      <text x="576" y="766" class="label">current</text>
      <text x="576" y="807" class="value">${xmlText(
        compactUsd(
          currentMc,
        ),
      )} MC</text>

      <rect x="1024" y="728" width="504" height="105" rx="10" fill="#101010" stroke="#242424"/>
      <text x="1052" y="766" class="label">since first detection</text>
      <text x="1052" y="807" class="value">${xmlText(
        `${candidate.multiple.toFixed(
          2,
        )}x`,
      )}</text>

      <text x="72" y="874" class="sub">Market data: DEX Screener | Chart data: ${candles.length ? "GeckoTerminal" : "unavailable"} | Render: MemeScope</text>
    </svg>`;

  return sharp(
    Buffer.from(
      svg,
      "utf8",
    ),
  )
    .webp({
      quality: 90,
    })
    .toBuffer();
}

'@

$content =
    $content.Substring(0, $start) +
    $captureBlock +
    $content.Substring($end)

$shotStart = $content.IndexOf("async function screenshotForCandidate(")
$shotEnd = $content.IndexOf("async function createQueueItem(", $shotStart)

if ($shotStart -lt 0 -or $shotEnd -le $shotStart) {
    throw "screenshotForCandidate block markers were not found. No file was changed."
}

$shotBlock = @'
async function screenshotForCandidate(
  candidate:
    ContentCandidate,
  source:
    VisualSource,
) {
  if (
    source ===
    "text_only"
  ) {
    return {
      buffer: null,
      mime: null,
    };
  }

  const url =
    sourceUrl(
      source,
      candidate,
    );

  if (!url) {
    return {
      buffer: null,
      mime: null,
    };
  }

  if (
    source ===
    "dex_screener"
  ) {
    try {
      const raw =
        await captureRawScreenshot(
          url,
          source,
        );

      if (
        !raw.challengeDetected
      ) {
        const annotated =
          await annotateScreenshot(
            raw.buffer,
            candidate,
          );

        return {
          buffer:
            annotated,
          mime:
            "image/webp",
        };
      }
    } catch {
      // Browser capture failed. Use the deterministic fallback below.
    }

    const fallback =
      await renderDexFallback(
        candidate,
      );

    return {
      buffer:
        fallback,
      mime:
        "image/webp",
    };
  }

  const raw =
    await captureRawScreenshot(
      url,
      source,
    );

  if (
    raw.challengeDetected
  ) {
    return {
      buffer: null,
      mime: null,
    };
  }

  const annotated =
    await annotateScreenshot(
      raw.buffer,
      candidate,
    );

  return {
    buffer:
      annotated,
    mime:
      "image/webp",
  };
}

'@

$content =
    $content.Substring(0, $shotStart) +
    $shotBlock +
    $content.Substring($shotEnd)

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $utf8)

Write-Host ""
Write-Host "Hybrid DEX screenshot engine installed." -ForegroundColor Green
Write-Host "Behavior:" -ForegroundColor Cyan
Write-Host " 1. Try real DEX Screener screenshot"
Write-Host " 2. Detect human/security verification"
Write-Host " 3. If challenged, discard that screenshot"
Write-Host " 4. Fetch DEX Screener market data"
Write-Host " 5. Fetch GeckoTerminal candles when available"
Write-Host " 6. Render a clean 1600x900 MemeScope trader view"
Write-Host ""
Write-Host "No Cloudflare bypass is attempted." -ForegroundColor Yellow
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Run next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
