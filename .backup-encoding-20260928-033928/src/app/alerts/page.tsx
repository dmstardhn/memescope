import { AppShell } from "@/components/app-shell";
import { BellRing, Radio, Zap } from "lucide-react";

const rules = [
  {
    icon: Zap,
    title: "Early Momentum",
    description: "Score â‰¥ 80, liquidity â‰¥ $25K and 5m buy/sell â‰¥ 2.0x",
  },
  {
    icon: Radio,
    title: "Volume Spike",
    description: "5m volume exceeds configured rolling baseline",
  },
  {
    icon: BellRing,
    title: "Risk Change",
    description: "Notify when a watched token receives a new security flag",
  },
];

export default function AlertsPage() {
  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="text-sm text-emerald-300">Automation</div>
        <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">Alert Rules</h1>
        <p className="mt-1 text-sm text-zinc-500">
          The UI is ready. Telegram delivery will be connected in a later integration step.
        </p>
      </div>

      <div className="grid gap-3 p-5 md:grid-cols-2 xl:grid-cols-3 lg:p-8">
        {rules.map((rule) => {
          const Icon = rule.icon;
          return (
            <div key={rule.title} className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
              <div className="grid h-10 w-10 place-items-center rounded-xl bg-white/5">
                <Icon className="h-4 w-4 text-zinc-300" />
              </div>
              <div className="mt-5 font-medium text-white">{rule.title}</div>
              <p className="mt-2 text-sm leading-6 text-zinc-500">{rule.description}</p>
              <div className="mt-5 inline-flex rounded-full border border-white/8 px-3 py-1 text-xs text-zinc-600">
                Draft
              </div>
            </div>
          );
        })}
      </div>
    </AppShell>
  );
}
