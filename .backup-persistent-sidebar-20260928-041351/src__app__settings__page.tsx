import { AppShell } from "@/components/app-shell";

export default function SettingsPage() {
  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="text-sm text-emerald-300">Configuration</div>
        <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">Settings</h1>
      </div>

      <div className="max-w-3xl space-y-4 p-5 lg:p-8">
        {[
          ["DEX Screener", "Public market data connection", "Ready"],
          ["Solana RPC", "Holder, mint, freeze, LP and wallet intelligence", "Not connected"],
          ["EVM RPC", "Base / Ethereum contract intelligence", "Not connected"],
          ["Telegram Bot", "Custom scanner alerts", "Not connected"],
          ["AI Provider", "Natural-language token analysis", "Not connected"],
        ].map(([name, description, status]) => (
          <div
            key={name}
            className="flex flex-col gap-4 rounded-2xl border border-white/8 bg-white/[0.025] p-5 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <div className="font-medium text-white">{name}</div>
              <div className="mt-1 text-sm text-zinc-500">{description}</div>
            </div>
            <div className="rounded-full border border-white/8 px-3 py-1 text-xs text-zinc-500">
              {status}
            </div>
          </div>
        ))}
      </div>
    </AppShell>
  );
}