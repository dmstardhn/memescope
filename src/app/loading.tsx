export default function Loading() {
  return (
    <div className="min-h-screen bg-[#080a0f] p-6 text-zinc-100">
      <div className="mx-auto max-w-6xl animate-pulse">
        <div className="h-4 w-32 rounded bg-white/5" />
        <div className="mt-4 h-9 w-72 rounded bg-white/5" />

        <div className="mt-8 grid gap-3 md:grid-cols-4">
          {Array.from({ length: 4 }).map((_, index) => (
            <div
              key={index}
              className="h-24 rounded-2xl border border-white/5 bg-white/[0.025]"
            />
          ))}
        </div>

        <div className="mt-5 h-96 rounded-2xl border border-white/5 bg-white/[0.025]" />
      </div>
    </div>
  );
}
