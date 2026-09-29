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