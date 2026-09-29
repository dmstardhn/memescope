$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Full([string]$p) { Join-Path $root $p }
function WriteUtf8([string]$rel,[string]$text) {
  $path = Full $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path,$text,$utf8)
  Write-Host "WRITE $rel" -ForegroundColor Green
}

$enginePath = Full "src\lib\content-hq-v4\engine.ts"
$dbPath = Full "src\lib\content-hq-v4\db.ts"

foreach ($p in @($enginePath,$dbPath)) {
  if (!(Test-Path -LiteralPath $p)) { throw "Missing required file: $p" }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-V4-TestLab-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath $enginePath -Destination (Join-Path $backup "engine.ts") -Force

$engine = [System.IO.File]::ReadAllText($enginePath)

if (!$engine.Contains("export async function contentHqV4TestBatch")) {
$append = @'

export async function contentHqV4TestBatch(limit = 6) {
  await ensureV4Schema();
  const sql = sqlV4();
  const candidates = await buildTokenCandidates();
  const observation = await maybeObservation();
  if (observation) candidates.push(observation);

  const unique = new Map<string, Candidate>();
  for (const candidate of candidates) {
    const key = `${candidate.contentType}:${candidate.tokenAddress ?? "text"}`;
    if (!unique.has(key)) unique.set(key, candidate);
  }

  const picked = [...unique.values()].slice(0, Math.max(1, Math.min(limit, 8)));
  const created: Array<Record<string, unknown>> = [];

  for (let index = 0; index < picked.length; index++) {
    const selected = picked[index];

    const visual = await renderContent({
      symbol: selected.symbol,
      contentType: selected.contentType,
      visualStyle: selected.visualStyle,
      firstMarketCap: selected.firstMc,
      currentMarketCap: selected.currentMc,
      multiple: selected.multiple,
      liquidity: selected.liquidity,
      volume: selected.volume,
      candles: selected.candles,
      historicCandles: selected.historicCandles,
      branded: selected.branded,
    });

    if (selected.contentType !== "market_observation" && !visual) continue;

    const testKey = `v4test:${Date.now()}:${index}:${selected.tokenAddress ?? "text"}`;

    const rows = await sql`
      INSERT INTO memescope_content_v4_queue (
        event_key, token_address, pair_address, symbol,
        content_type, visual_style, caption_template, caption,
        reason, first_market_cap, current_market_cap, multiple,
        image_base64, image_mime, branded, status
      )
      VALUES (
        ${testKey}, ${selected.tokenAddress}, ${selected.pairAddress}, ${selected.symbol},
        ${selected.contentType}, ${selected.visualStyle}, ${selected.captionTemplate}, ${selected.caption},
        ${`TEST LAB: ${selected.reason}`}, ${selected.firstMc}, ${selected.currentMc}, ${selected.multiple},
        ${visual ? visual.buffer.toString("base64") : null}, ${visual?.mime ?? null},
        ${selected.branded}, 'queued'
      )
      RETURNING id, content_type, symbol, visual_style, caption, status
    `;

    if (rows.length) created.push(rows[0] as Record<string, unknown>);
  }

  return {
    ok: true,
    requested: limit,
    availableCandidates: candidates.length,
    created: created.length,
    items: created,
  };
}
'@
  [System.IO.File]::WriteAllText($enginePath,$engine+$append,$utf8)
  Write-Host "PATCH engine.ts -> test batch helper" -ForegroundColor Green
}

$route = @'
import { NextResponse } from "next/server";
import { contentHqV4TestBatch } from "@/lib/content-hq-v4/engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${secret}`;
}

export async function POST(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({error:"Unauthorized"},{status:401});
  }

  try {
    const body = await request.json().catch(()=>({})) as {limit?:number};
    const limit = Math.max(1,Math.min(Number(body.limit ?? 6),8));
    return NextResponse.json(await contentHqV4TestBatch(limit));
  } catch (error) {
    return NextResponse.json(
      {ok:false,error:error instanceof Error ? error.message : String(error)},
      {status:500},
    );
  }
}
'@

WriteUtf8 "src/app/api/content-hq-v4/test-batch/route.ts" $route

$tester = @'
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$envFile = Join-Path $root ".env.local"
$secret = $null

if (Test-Path $envFile) {
  $line = Get-Content $envFile | Where-Object { $_ -match '^\s*CRON_SECRET\s*=' } | Select-Object -First 1
  if ($line) { $secret = ($line -replace '^\s*CRON_SECRET\s*=','').Trim().Trim('"').Trim("'") }
}

if (!$secret) {
  $secure = Read-Host "CRON_SECRET" -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

$body = @{limit=6} | ConvertTo-Json
$result = Invoke-RestMethod `
  -Uri "https://memescopes.vercel.app/api/content-hq-v4/test-batch" `
  -Method Post `
  -Headers @{Authorization="Bearer $secret"} `
  -ContentType "application/json" `
  -Body $body

$result | ConvertTo-Json -Depth 8

Write-Host ""
Write-Host "Now open:" -ForegroundColor Cyan
Write-Host "  https://memescopes.vercel.app/content-hq"
Write-Host ""
Write-Host "Then open Telegram admin:" -ForegroundColor Cyan
Write-Host "  /contenthq -> Queue"
Write-Host ""
Write-Host "These test items are QUEUED only. They are not published automatically while Manual Approval is ON." -ForegroundColor Yellow
'@

WriteUtf8 "TEST-MEMESCOPE-CONTENT-HQ-V4-REAL-CONTENT.ps1" $tester

Write-Host ""
Write-Host "Test Lab installed." -ForegroundColor Green
Write-Host "Run npm run typecheck and npm run build, then deploy." -ForegroundColor Cyan
