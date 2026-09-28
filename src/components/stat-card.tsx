type Props = {
  label: string;
  value: string;
  sub?: string;
};

export function StatCard({ label, value, sub }: Props) {
  return (
    <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
      <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">{label}</div>
      <div className="mt-2 text-2xl font-semibold tracking-tight text-white">{value}</div>
      {sub ? <div className="mt-1 text-xs text-zinc-500">{sub}</div> : null}
    </div>
  );
}