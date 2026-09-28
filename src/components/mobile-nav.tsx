"use client";

import {
  BrainCircuit,
  BellRing,
  Eye,
  LayoutDashboard,
  Radar,
  Rocket,
  WalletCards,
} from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

const items = [
  { href: "/workspace", label: "Home", icon: LayoutDashboard },
  { href: "/scanner", label: "Scan", icon: Radar },
  { href: "/discover", label: "Discover", icon: Rocket },
  { href: "/signals", label: "Signals", icon: BellRing },
  { href: "/analyst", label: "Analyst", icon: BrainCircuit },
  { href: "/wallets", label: "Wallets", icon: WalletCards },
  { href: "/watchlist", label: "Watch", icon: Eye },
];

export function MobileNav() {
  const pathname = usePathname();

  return (
    <nav className="fixed inset-x-3 bottom-3 z-50 rounded-2xl border border-white/10 bg-[#0b0e14]/95 p-1.5 shadow-2xl shadow-black/50 backdrop-blur-xl lg:hidden">
      <div className="grid grid-cols-7">
        {items.map((item) => {
          const active =
            pathname === item.href ||
            pathname.startsWith(`${item.href}/`);
          const Icon = item.icon;

          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex min-w-0 flex-col items-center gap-1 rounded-xl px-1 py-2 text-[10px] transition ${
                active
                  ? "bg-white text-black"
                  : "text-zinc-500"
              }`}
            >
              <Icon className="h-4 w-4" />
              <span className="truncate">{item.label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
