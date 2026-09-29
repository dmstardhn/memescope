import {
  ContentActions,
} from "@/components/content-hq-actions";
import {
  getContentStats,
  listContentQueue,
} from "@/lib/content-hq";

export const dynamic =
  "force-dynamic";

export default async function ContentHqPage() {
  const [
    stats,
    queue,
  ] =
    await Promise.all([
      getContentStats(),
      listContentQueue(
        36,
      ),
    ]);

  return (
    <main className="mx-auto min-h-screen w-full max-w-7xl px-4 py-7 lg:px-8">
      <div className="mb-7">
        <div className="text-xs uppercase tracking-[0.28em] text-zinc-500">
          MemeScope
        </div>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
          Content HQ
        </h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
          Deterministic content automation. Market data to rule engine to screenshot to caption template to queue. No AI content generation.
        </p>
      </div>

      <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          [
            "Queued",
            stats.queued,
          ],
          [
            "Scheduled",
            stats.scheduled,
          ],
          [
            "Published Today",
            stats.publishedToday,
          ],
          [
            "Failed",
            stats.failed,
          ],
        ].map(
          ([
            label,
            value,
          ]) => (
            <div
              key={label}
              className="rounded-2xl border border-white/8 bg-white/[0.025] p-5"
            >
              <div className="text-xs uppercase tracking-[0.18em] text-zinc-600">
                {label}
              </div>
              <div className="mt-3 text-3xl font-semibold text-white">
                {value}
              </div>
            </div>
          ),
        )}
      </section>

      <section className="mt-8">
        <div className="mb-4 flex items-end justify-between gap-4">
          <div>
            <h2 className="text-xl font-medium text-white">
              Queue
            </h2>
            <p className="mt-1 text-sm text-zinc-600">
              Raw trader-style content previews.
            </p>
          </div>
        </div>

        <div className="grid gap-5 xl:grid-cols-2">
          {queue.map(
            (item) => (
              <article
                key={item.id}
                className="overflow-hidden rounded-2xl border border-white/8 bg-white/[0.02]"
              >
                {item.imageMime ? (
                  <img
                    src={`/api/content-hq/media/${item.id}`}
                    alt={`${item.symbol} content preview`}
                    className="aspect-video w-full bg-black object-cover"
                  />
                ) : (
                  <div className="flex aspect-video items-center justify-center bg-black/40 text-sm text-zinc-600">
                    Text-only post
                  </div>
                )}

                <div className="p-5">
                  <div className="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-[0.16em] text-zinc-600">
                    <span>
                      {item.visualSource}
                    </span>
                    <span>/</span>
                    <span>
                      {item.contentType}
                    </span>
                    <span>/</span>
                    <span>
                      {item.captionTemplate}
                    </span>
                    <span>/</span>
                    <span>
                      {item.status}
                    </span>
                  </div>

                  <div className="mt-3 flex items-baseline justify-between gap-4">
                    <div className="text-xl font-semibold text-white">
                      ${item.symbol}
                    </div>
                    <div className="text-sm text-zinc-500">
                      {item.multiple.toFixed(
                        2,
                      )}x
                    </div>
                  </div>

                  <ContentActions
                    id={item.id}
                    initialCaption={
                      item.caption
                    }
                  />
                </div>
              </article>
            ),
          )}
        </div>
      </section>
    </main>
  );
}