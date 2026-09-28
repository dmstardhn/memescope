import { Activity, CircleDot } from "lucide-react";

export function TopBar() {
  return (
    <div className="sticky top-0 z-40 flex h-12 items-center justify-between border-b border-white/8 bg-[#080a0f]/85 px-4 backdrop-blur-xl lg:px-8">
      <div className="flex items-center gap-2 text-xs text-zinc-500">
        <Activity className="h-3.5 w-3.5 text-emerald-300" />
        MemeScope Terminal
      </div>

      <div className="flex items-center gap-2 rounded-full border border-emerald-400/15 bg-emerald-400/5 px-2.5 py-1 text-[11px] text-emerald-300">
        <CircleDot className="h-3 w-3" />
        Solana
      </div>
    </div>
  );
}
