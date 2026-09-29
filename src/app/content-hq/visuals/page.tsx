import { VISUAL_TEMPLATES } from "@/lib/content-hq-blueprint-v3";

export const dynamic = "force-dynamic";

export default function ContentHqVisualsPage() {
  const sources = [
    "dex_screener",
    "gmgn",
    "memescope",
  ] as const;

  return (
    <main className="mx-auto min-h-screen w-full max-w-7xl px-4 py-8 lg:px-8">
      <div className="mb-8">
        <div className="text-xs uppercase tracking-[0.28em] text-zinc-500">
          Content HQ
        </div>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
          Visual Templates
        </h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
          1600x900 deterministic layouts. Source + content type + anti-repeat history select the visual.
        </p>
      </div>

      <div className="space-y-10">
        {sources.map((source) => {
          const templates =
            VISUAL_TEMPLATES.filter(
              (item) =>
                item.source === source,
            );

          return (
            <section key={source}>
              <h2 className="mb-4 text-xl font-medium text-white">
                {source}
              </h2>

              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                {templates.map(
                  (template) => (
                    <article
                      key={
                        template.id
                      }
                      className="rounded-2xl border border-white/8 bg-white/[0.025] p-5"
                    >
                      <div className="text-sm font-medium text-white">
                        {template.id}
                      </div>

                      <p className="mt-3 text-sm leading-6 text-zinc-500">
                        {template.description}
                      </p>

                      <div className="mt-4 flex flex-wrap gap-2">
                        {template.contentTypes.map(
                          (type) => (
                            <span
                              key={type}
                              className="rounded-full border border-white/10 px-2.5 py-1 text-[11px] text-zinc-400"
                            >
                              {type}
                            </span>
                          ),
                        )}
                      </div>
                    </article>
                  ),
                )}
              </div>
            </section>
          );
        })}
      </div>
    </main>
  );
}