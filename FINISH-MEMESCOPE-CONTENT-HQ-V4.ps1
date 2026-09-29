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

foreach ($rel in @(
  "src\lib\content-hq-v4\db.ts",
  "src\lib\content-hq-v4\telegram-admin.ts",
  "src\app\api\telegram\cron\route.ts"
)) {
  if (!(Test-Path (Full $rel))) { throw "Missing required file: $rel" }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-V4-FinalControl-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item (Full "src\lib\content-hq-v4\telegram-admin.ts") (Join-Path $backup "telegram-admin.ts") -Force
Copy-Item (Full "src\app\api\telegram\cron\route.ts") (Join-Path $backup "cron-route.ts") -Force

npm install twitter-api-v2 sharp
if ($LASTEXITCODE -ne 0) { throw "npm install failed." }

$publisher = @'
import "server-only";
import sharp from "sharp";
import { TwitterApi } from "twitter-api-v2";
import { getV4Settings, sqlV4 } from "./db";

type Row = Record<string, unknown>;

function credentials() {
  const appKey = process.env.X_API_KEY?.trim();
  const appSecret = process.env.X_API_SECRET?.trim();
  const accessToken = process.env.X_ACCESS_TOKEN?.trim();
  const accessSecret = process.env.X_ACCESS_SECRET?.trim();

  if (!appKey || !appSecret || !accessToken || !accessSecret) return null;
  return { appKey, appSecret, accessToken, accessSecret };
}

export function xPublishingConfigured() {
  return Boolean(credentials());
}

async function item(id: number) {
  const sql = sqlV4();
  const rows = await sql`SELECT * FROM memescope_content_v4_queue WHERE id=${id} LIMIT 1`;
  return rows.length ? rows[0] as Row : null;
}

async function publish(id: number) {
  const row = await item(id);
  if (!row) throw new Error("Content item not found.");

  const status = String(row.status ?? "");
  if (!["approved","scheduled"].includes(status)) {
    throw new Error(`Content status ${status} is not publishable.`);
  }

  const creds = credentials();
  if (!creds) throw new Error("X publishing is not configured.");

  const client = new TwitterApi(creds);
  let mediaIds: string[] = [];

  if (row.image_base64) {
    const input = Buffer.from(String(row.image_base64),"base64");
    const png = await sharp(input).png().toBuffer();
    const mediaId = await client.v1.uploadMedia(png,{mimeType:"image/png"});
    mediaIds = [mediaId];
  }

  const caption = String(row.caption ?? "").trim();
  if (!caption) throw new Error("Caption is empty.");

  const result = mediaIds.length
    ? await client.v2.tweet(caption,{media:{media_ids:mediaIds as [string]}})
    : await client.v2.tweet(caption);

  const tweetId = result.data.id;
  const sql = sqlV4();

  await sql`
    UPDATE memescope_content_v4_queue
    SET status='published',
        published_at=NOW(),
        x_post_id=${tweetId}
    WHERE id=${id}
  `;

  return {id,tweetId};
}

async function publicationGuard(force: boolean) {
  if (force) return;
  const settings = await getV4Settings();
  const sql = sqlV4();

  const today = await sql`
    SELECT COUNT(*)::INTEGER AS count
    FROM memescope_content_v4_queue
    WHERE status='published'
      AND published_at >= date_trunc('day', NOW() AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'Asia/Jakarta'
  `;
  if (Number(today[0]?.count ?? 0) >= settings.maxPostsPerDay) throw new Error("Daily publish limit reached.");

  const latest = await sql`
    SELECT published_at
    FROM memescope_content_v4_queue
    WHERE status='published'
    ORDER BY published_at DESC
    LIMIT 1
  `;
  if (latest.length) {
    const gap = (Date.now()-new Date(String(latest[0].published_at)).getTime())/60000;
    if (gap < settings.minGapMinutes) throw new Error("Minimum publish gap is still active.");
  }
}

export async function publishNow(id: number, force = true) {
  await publicationGuard(force);
  const sql = sqlV4();
  await sql`
    UPDATE memescope_content_v4_queue
    SET status='approved', approved_at=COALESCE(approved_at,NOW())
    WHERE id=${id}
  `;
  return publish(id);
}

export async function scheduleIn(id: number, minutes: number) {
  const sql = sqlV4();
  const rows = await sql`
    UPDATE memescope_content_v4_queue
    SET status='scheduled',
        approved_at=COALESCE(approved_at,NOW()),
        scheduled_at=NOW()+(${minutes}::text || ' minutes')::interval
    WHERE id=${id}
    RETURNING scheduled_at
  `;
  if (!rows.length) throw new Error("Content item not found.");
  return new Date(String(rows[0].scheduled_at)).toISOString();
}

export async function publishDue() {
  if (!xPublishingConfigured()) return {published:0,reason:"x-not-configured"};

  const sql = sqlV4();
  const due = await sql`
    SELECT id
    FROM memescope_content_v4_queue
    WHERE status='scheduled'
      AND scheduled_at <= NOW()
    ORDER BY scheduled_at ASC
    LIMIT 1
  `;
  if (due.length) {
    try {
      await publicationGuard(false);
      const result = await publish(Number(due[0].id));
      return {published:1,result};
    } catch (error) {
      return {published:0,reason:error instanceof Error ? error.message : String(error)};
    }
  }

  const settings = await getV4Settings();
  if (settings.manualApproval) return {published:0,reason:"manual-approval"};

  const localHourRows = await sql`
    SELECT EXTRACT(HOUR FROM NOW() AT TIME ZONE 'Asia/Jakarta')::INTEGER AS hour
  `;
  const hour = Number(localHourRows[0]?.hour ?? -1);
  const insideWindow =
    (hour >= 8 && hour < 10) ||
    (hour >= 12 && hour < 14) ||
    (hour >= 17 && hour < 19) ||
    (hour >= 21 && hour < 23);

  if (!insideWindow) return {published:0,reason:"outside-posting-window"};

  const approved = await sql`
    SELECT id
    FROM memescope_content_v4_queue
    WHERE status='approved'
    ORDER BY created_at ASC
    LIMIT 1
  `;
  if (!approved.length) return {published:0,reason:"nothing-approved"};

  try {
    await publicationGuard(false);
    const result = await publish(Number(approved[0].id));
    return {published:1,result};
  } catch (error) {
    return {published:0,reason:error instanceof Error ? error.message : String(error)};
  }
}
'@
WriteUtf8 "src/lib/content-hq-v4/publisher.ts" $publisher

$actionRoute = @'
import { NextResponse } from "next/server";
import { approve, nextCaption, nextVisual, reject } from "@/lib/content-hq-v4/queue-control";
import { publishNow, scheduleIn } from "@/lib/content-hq-v4/publisher";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const expected = process.env.CONTENT_HQ_ADMIN_KEY?.trim() || process.env.CRON_SECRET?.trim();
  if (!expected) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${expected}`;
}

export async function POST(request: Request) {
  if (!authorized(request)) return NextResponse.json({error:"Unauthorized"},{status:401});

  try {
    const body = await request.json() as {id?:number;action?:string;minutes?:number};
    const id = Number(body.id);
    if (!Number.isFinite(id)) return NextResponse.json({error:"Invalid id"},{status:400});

    if (body.action === "approve") await approve(id);
    else if (body.action === "reject") await reject(id);
    else if (body.action === "next_caption") await nextCaption(id);
    else if (body.action === "next_visual") await nextVisual(id);
    else if (body.action === "publish_now") return NextResponse.json({ok:true,result:await publishNow(id,true)});
    else if (body.action === "schedule") return NextResponse.json({ok:true,scheduledAt:await scheduleIn(id,Number(body.minutes ?? 60))});
    else return NextResponse.json({error:"Unknown action"},{status:400});

    return NextResponse.json({ok:true});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}
'@
WriteUtf8 "src/app/api/content-hq-v4/action/route.ts" $actionRoute

$publishRoute = @'
import { NextResponse } from "next/server";
import { publishDue } from "@/lib/content-hq-v4/publisher";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${secret}`;
}

export async function GET(request: Request) {
  if (!authorized(request)) return NextResponse.json({error:"Unauthorized"},{status:401});
  try {
    return NextResponse.json({ok:true,...(await publishDue())});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}
export async function POST(request: Request) { return GET(request); }
'@
WriteUtf8 "src/app/api/content-hq-v4/publish/route.ts" $publishRoute

$listRoute = @'
import { NextResponse } from "next/server";
import { getV4Settings, sqlV4 } from "@/lib/content-hq-v4/db";
import { xPublishingConfigured } from "@/lib/content-hq-v4/publisher";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const settings = await getV4Settings();
    const sql = sqlV4();
    const rows = await sql`
      SELECT id, token_address, pair_address, symbol, content_type, visual_style,
             caption_template, caption, reason, first_market_cap, current_market_cap,
             multiple, image_mime, branded, status, created_at, approved_at,
             scheduled_at, published_at, x_post_id,
             CASE WHEN image_base64 IS NOT NULL THEN TRUE ELSE FALSE END AS has_image
      FROM memescope_content_v4_queue
      WHERE created_at >= ${settings.historyResetAt}::timestamptz
        AND status <> 'archived_before_reset'
      ORDER BY created_at DESC
      LIMIT 100
    `;
    return NextResponse.json({ok:true,settings,xConfigured:xPublishingConfigured(),items:rows});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}
'@
WriteUtf8 "src/app/api/content-hq-v4/queue/route.ts" $listRoute

$dashboard = @'
import { getV4Settings, sqlV4 } from "@/lib/content-hq-v4/db";
import { xPublishingConfigured } from "@/lib/content-hq-v4/publisher";

export const dynamic = "force-dynamic";

function fmt(value: unknown) {
  const n=Number(value);
  if (!Number.isFinite(n)) return "-";
  if (n>=1e9) return `$${(n/1e9).toFixed(2)}B`;
  if (n>=1e6) return `$${(n/1e6).toFixed(2)}M`;
  if (n>=1e3) return `$${(n/1e3).toFixed(0)}K`;
  return `$${n.toFixed(0)}`;
}

export default async function ContentHqPage() {
  const settings=await getV4Settings();
  const sql=sqlV4();
  const rows=await sql`
    SELECT id,symbol,content_type,visual_style,caption,reason,
           first_market_cap,current_market_cap,multiple,branded,status,
           created_at,scheduled_at,published_at,
           CASE WHEN image_base64 IS NOT NULL THEN TRUE ELSE FALSE END AS has_image
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 40
  `;

  const queued=rows.filter(r=>r.status==="queued").length;
  const approved=rows.filter(r=>r.status==="approved").length;
  const published=rows.filter(r=>r.status==="published").length;

  return (
    <main className="mx-auto min-h-screen w-full max-w-7xl px-4 py-8 lg:px-8">
      <div className="mb-8 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <div className="text-xs uppercase tracking-[0.28em] text-zinc-500">MemeScope</div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">Content HQ V4</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
            Natural trader content: text observations, raw charts, token updates, Before The Move, Call Journey and recaps.
          </p>
        </div>
        <div className="text-sm text-zinc-500">
          X publishing: <span className={xPublishingConfigured()?"text-emerald-400":"text-amber-400"}>{xPublishingConfigured()?"READY":"NOT CONFIGURED"}</span>
        </div>
      </div>

      <section className="grid gap-3 md:grid-cols-4">
        {[
          ["Queued",queued],
          ["Approved",approved],
          ["Published",published],
          ["Manual Approval",settings.manualApproval?"ON":"OFF"],
        ].map(([label,value])=>(
          <div key={String(label)} className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            <div className="text-xs uppercase tracking-[0.18em] text-zinc-600">{label}</div>
            <div className="mt-3 text-2xl font-semibold text-white">{String(value)}</div>
          </div>
        ))}
      </section>

      <div className="mt-8 flex items-center justify-between">
        <div>
          <h2 className="text-xl font-medium text-white">Current queue</h2>
          <p className="mt-1 text-sm text-zinc-600">Management remains owner-only through the Telegram administrator bot.</p>
        </div>
        <div className="text-xs text-zinc-600">History since {new Date(settings.historyResetAt).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}</div>
      </div>

      <section className="mt-5 grid gap-5 lg:grid-cols-2">
        {rows.length===0 && (
          <div className="rounded-2xl border border-white/8 bg-white/[0.02] p-8 text-sm text-zinc-500">No Content HQ V4 items yet.</div>
        )}

        {rows.map(row=>(
          <article key={String(row.id)} className="overflow-hidden rounded-2xl border border-white/8 bg-[#0b0c0c]">
            {row.has_image ? (
              <img
                src={`/api/content-hq-v4/media/${row.id}`}
                alt=""
                className="aspect-video w-full object-cover"
              />
            ) : (
              <div className="flex aspect-video items-center justify-center border-b border-white/8 text-sm text-zinc-600">Text-only</div>
            )}

            <div className="p-5">
              <div className="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-[0.12em]">
                <span className="rounded-full border border-white/10 px-2.5 py-1 text-zinc-400">{String(row.content_type)}</span>
                <span className="rounded-full border border-white/10 px-2.5 py-1 text-zinc-500">{String(row.visual_style ?? "text_only")}</span>
                <span className="rounded-full border border-white/10 px-2.5 py-1 text-zinc-500">{String(row.status)}</span>
                {row.branded ? <span className="rounded-full border border-white/10 px-2.5 py-1 text-zinc-500">branded</span> : null}
              </div>

              <pre className="mt-5 whitespace-pre-wrap font-sans text-sm leading-6 text-zinc-200">{String(row.caption ?? "")}</pre>

              <div className="mt-5 border-t border-white/8 pt-4 text-xs leading-5 text-zinc-600">
                <div>{String(row.reason ?? "-")}</div>
                {row.symbol ? <div className="mt-2">${String(row.symbol)} / {fmt(row.first_market_cap)} to {fmt(row.current_market_cap)}{row.multiple?` / ${Number(row.multiple).toFixed(2)}x`:""}</div> : null}
              </div>
            </div>
          </article>
        ))}
      </section>
    </main>
  );
}
'@
WriteUtf8 "src/app/content-hq/page.tsx" $dashboard

# Add Publish/Schedule controls to Telegram admin using narrow string patches.
$adminPath = Full "src\lib\content-hq-v4\telegram-admin.ts"
$admin = [System.IO.File]::ReadAllText($adminPath)

if (!$admin.Contains('from "./publisher"')) {
  $needle = 'import { approve, getItem, listPending, nextCaption, nextVisual, reject } from "./queue-control";'
  if (!$admin.Contains($needle)) { throw "Telegram queue-control import marker not found." }
  $admin = $admin.Replace($needle, $needle + "`r`n" + 'import { publishNow, scheduleIn, xPublishingConfigured } from "./publisher";')
}

$oldButtons = @'
    [
      {text:"Next Caption",callback_data:`ch4:caption:${id}`},
      {text:"Next Chart Style",callback_data:`ch4:visual:${id}`},
    ],
    [
      {text:"Back",callback_data:"ch4:queue"},
    ],
'@
$newButtons = @'
    [
      {text:"Next Caption",callback_data:`ch4:caption:${id}`},
      {text:"Next Chart Style",callback_data:`ch4:visual:${id}`},
    ],
    [
      {text:"Publish Now",callback_data:`ch4:publish:${id}`},
      {text:"Schedule +1h",callback_data:`ch4:schedule:${id}`},
    ],
    [
      {text:"Back",callback_data:"ch4:queue"},
    ],
'@
if ($admin.Contains($oldButtons)) { $admin = $admin.Replace($oldButtons,$newButtons) }

$oldMatch = 'const match = callback?.match(/^ch4:(approve|reject|caption|visual):(\d+)$/);'
$newMatch = 'const match = callback?.match(/^ch4:(approve|reject|caption|visual|publish|schedule):(\d+)$/);'
if ($admin.Contains($oldMatch)) { $admin = $admin.Replace($oldMatch,$newMatch) }

$needleAction = @'
    if (action === "visual") await nextVisual(id);

    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`${action} applied`});
'@
$replacementAction = @'
    if (action === "visual") await nextVisual(id);
    if (action === "schedule") {
      const at = await scheduleIn(id,60);
      await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`Scheduled ${new Date(at).toLocaleTimeString("en-GB",{timeZone:"Asia/Jakarta"})}`});
      await sendQueueItem(chatId,id);
      return {handled:true};
    }
    if (action === "publish") {
      if (!xPublishingConfigured()) {
        await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:"X publishing is not configured.",show_alert:true});
        return {handled:true};
      }
      const result = await publishNow(id,true);
      await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`Published: ${result.tweetId}`,show_alert:true});
      await sendQueueItem(chatId,id);
      return {handled:true};
    }

    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`${action} applied`});
'@
if ($admin.Contains($needleAction)) {
  $admin = $admin.Replace($needleAction,$replacementAction)
} elseif (!$admin.Contains('action === "publish"')) {
  throw "Telegram action block marker not found."
}

[System.IO.File]::WriteAllText($adminPath,$admin,$utf8)
Write-Host "PATCH telegram-admin.ts" -ForegroundColor Green

# Patch Telegram cron: call V4 publisher after V4 processor. No other cron work is removed.
$cronPath = Full "src\app\api\telegram\cron\route.ts"
$cron = [System.IO.File]::ReadAllText($cronPath)

if (!$cron.Contains("/api/content-hq-v4/publish")) {
  $processLiteral = '"/api/content-hq-v4/process"'
  $pos = $cron.IndexOf($processLiteral)
  if ($pos -lt 0) { throw "V4 process URL not found in Telegram cron." }

  # Duplicate the nearest fetch block is unsafe; instead add fire-and-forget publication near final return.
  $returnPos = $cron.LastIndexOf("return ")
  if ($returnPos -lt 0) { throw "Could not safely find final return in Telegram cron." }

  $snippet = @'
  try {
    const baseUrl =
      process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/+$/, "") ||
      process.env.VERCEL_PROJECT_PRODUCTION_URL
        ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
        : "https://memescopes.vercel.app";

    const cronSecret = process.env.CRON_SECRET?.trim();
    if (cronSecret) {
      await fetch(`${baseUrl}/api/content-hq-v4/publish`, {
        method: "POST",
        headers: { Authorization: `Bearer ${cronSecret}` },
        cache: "no-store",
      }).catch(() => undefined);
    }
  } catch {
    // Content publishing must never break the signal/public Telegram cron.
  }

'@
  $cron = $cron.Insert($returnPos,$snippet)
  [System.IO.File]::WriteAllText($cronPath,$cron,$utf8)
  Write-Host "PATCH telegram cron -> V4 publisher" -ForegroundColor Green
}

Write-Host ""
Write-Host "Stage installed." -ForegroundColor Green
Write-Host "Run npm run typecheck && npm run build before deploy." -ForegroundColor Cyan
