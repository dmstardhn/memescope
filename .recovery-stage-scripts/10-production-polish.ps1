$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not (Test-Path "package.json")) {
    throw "Jalankan script ini dari root folder memecoin-analyst."
}

Step "Backup Stage 10"
$BackupDir = "backup-stage-10"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
foreach ($file in @(
    "src/components/app-shell.tsx",
    "src/app/globals.css",
    "src/app/layout.tsx",
    "package.json"
)) {
    if (Test-Path $file) {
        $safe = ($file -replace '[\\/]', '-')
        Copy-Item $file "$BackupDir/$safe.bak" -Force
    }
}

Step "Membuat mobile navigation"
@'
"use client";

import {
  BrainCircuit,
  Eye,
  Radar,
  Rocket,
  WalletCards,
} from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

const items = [
  { href: "/scanner", label: "Scan", icon: Radar },
  { href: "/discover", label: "Discover", icon: Rocket },
  { href: "/analyst", label: "Analyst", icon: BrainCircuit },
  { href: "/wallets", label: "Wallets", icon: WalletCards },
  { href: "/watchlist", label: "Watch", icon: Eye },
];

export function MobileNav() {
  const pathname = usePathname();

  return (
    <nav className="fixed inset-x-3 bottom-3 z-50 rounded-2xl border border-white/10 bg-[#0b0e14]/95 p-1.5 shadow-2xl shadow-black/50 backdrop-blur-xl lg:hidden">
      <div className="grid grid-cols-5">
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
'@ | Set-Content -Encoding UTF8 "src/components/mobile-nav.tsx"

Step "Membuat polished top bar"
@'
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
'@ | Set-Content -Encoding UTF8 "src/components/top-bar.tsx"

Step "Update AppShell"
@'
import { MobileNav } from "@/components/mobile-nav";
import { Sidebar } from "@/components/sidebar";
import { TopBar } from "@/components/top-bar";

export function AppShell({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen bg-[#080a0f] text-zinc-100">
      <div className="mx-auto flex min-h-screen max-w-[1900px]">
        <Sidebar />

        <div className="min-w-0 flex-1">
          <TopBar />
          <main className="min-w-0 pb-24 lg:pb-0">
            {children}
          </main>
        </div>

        <MobileNav />
      </div>
    </div>
  );
}
'@ | Set-Content -Encoding UTF8 "src/components/app-shell.tsx"

Step "Polish global CSS"
@'
@import "tailwindcss";

:root {
  color-scheme: dark;
  --background: #080a0f;
  --panel: #0d1016;
  --border: rgba(255, 255, 255, 0.08);
}

* {
  box-sizing: border-box;
}

html {
  background: var(--background);
  scroll-behavior: smooth;
}

body {
  margin: 0;
  min-height: 100vh;
  background:
    radial-gradient(circle at 85% -10%, rgba(52, 211, 153, 0.08), transparent 34rem),
    radial-gradient(circle at 20% 15%, rgba(59, 130, 246, 0.035), transparent 28rem),
    var(--background);
  color: #f4f4f5;
  font-family: Arial, Helvetica, sans-serif;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}

button,
input,
select,
textarea {
  font: inherit;
}

button,
a {
  -webkit-tap-highlight-color: transparent;
}

button:focus-visible,
a:focus-visible,
input:focus-visible,
select:focus-visible,
textarea:focus-visible {
  outline: 2px solid rgba(52, 211, 153, 0.55);
  outline-offset: 2px;
}

::selection {
  background: rgba(52, 211, 153, 0.25);
}

::-webkit-scrollbar {
  width: 10px;
  height: 10px;
}

::-webkit-scrollbar-track {
  background: #080a0f;
}

::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.12);
  border: 3px solid #080a0f;
  border-radius: 999px;
}

::-webkit-scrollbar-thumb:hover {
  background: rgba(255, 255, 255, 0.2);
}

table {
  font-variant-numeric: tabular-nums;
}
'@ | Set-Content -Encoding UTF8 "src/app/globals.css"

Step "Update metadata"
@'
import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "MemeScope — Solana Market Intelligence",
    template: "%s | MemeScope",
  },
  description:
    "Real-time Solana memecoin scanner, discovery, risk analysis, wallet intelligence and AI-assisted market research.",
  applicationName: "MemeScope",
  keywords: [
    "Solana",
    "memecoin",
    "DEX",
    "market scanner",
    "token risk",
    "wallet tracker",
  ],
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#080a0f",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
'@ | Set-Content -Encoding UTF8 "src/app/layout.tsx"

Step "Membuat loading UI"
@'
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
'@ | Set-Content -Encoding UTF8 "src/app/loading.tsx"

Step "Membuat error boundary"
@'
"use client";

import { AlertTriangle, RefreshCw } from "lucide-react";

export default function GlobalError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <html>
      <body className="m-0 bg-[#080a0f] text-zinc-100">
        <div className="grid min-h-screen place-items-center p-6">
          <div className="w-full max-w-lg rounded-3xl border border-rose-400/15 bg-rose-400/5 p-8 text-center">
            <AlertTriangle className="mx-auto h-8 w-8 text-rose-300" />
            <h1 className="mt-4 text-2xl font-semibold">
              Something went wrong
            </h1>
            <p className="mt-2 text-sm leading-6 text-zinc-500">
              The terminal hit an unexpected client or server error.
              Your market data source may also be temporarily unavailable.
            </p>
            <button
              onClick={reset}
              className="mt-6 inline-flex items-center gap-2 rounded-xl bg-white px-4 py-2 text-sm font-medium text-black"
            >
              <RefreshCw className="h-4 w-4" />
              Try again
            </button>
          </div>
        </div>
      </body>
    </html>
  );
}
'@ | Set-Content -Encoding UTF8 "src/app/global-error.tsx"

Step "Production security headers"
@'
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          {
            key: "X-Content-Type-Options",
            value: "nosniff",
          },
          {
            key: "Referrer-Policy",
            value: "strict-origin-when-cross-origin",
          },
          {
            key: "Permissions-Policy",
            value: "camera=(), microphone=(), geolocation=()",
          },
          {
            key: "X-Frame-Options",
            value: "SAMEORIGIN",
          },
        ],
      },
    ];
  },
};

export default nextConfig;
'@ | Set-Content -Encoding UTF8 "next.config.ts"

Step "Menambahkan scripts production check"
$pkg = Get-Content "package.json" -Raw | ConvertFrom-Json
if (-not $pkg.scripts) {
    $pkg | Add-Member -MemberType NoteProperty -Name scripts -Value ([pscustomobject]@{})
}

$pkg.scripts | Add-Member -MemberType NoteProperty -Name typecheck -Value "tsc --noEmit" -Force
$pkg.scripts | Add-Member -MemberType NoteProperty -Name check -Value "npm run lint && npm run typecheck && npm run build" -Force

$json = $pkg | ConvertTo-Json -Depth 100
$utf8NoBomPackage = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    (Join-Path (Get-Location) "package.json"),
    $json,
    $utf8NoBomPackage
)

Step "Membuat production env template"
@'
# Core data
SOLANA_RPC_URL=
SOLANA_WSS_URL=

# Optional direct launch stream
PUMPPORTAL_API_KEY=

# Optional AI Analyst
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna

# Future
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
EVM_RPC_URL=
'@ | Set-Content -Encoding UTF8 ".env.production.example"

Step "Membuat production checklist"
@'
# MemeScope — Production Checklist

## Required before public launch

1. Replace public Solana RPC with a private production RPC.
2. Configure both HTTP and WebSocket endpoints:
   - `SOLANA_RPC_URL`
   - `SOLANA_WSS_URL`
3. Keep all secret keys server-side only.
4. Run:
   ```powershell
   npm run check
   ```
5. Deploy only if lint, TypeScript, and production build all pass.

## Optional

AI Analyst:
```text
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna
```

Pump live stream:
```text
PUMPPORTAL_API_KEY=
```

## Vercel

Add the environment variables in the project settings, then deploy the repository.

Recommended production command is the default:

```text
npm run build
npm run start
```

## Product disclaimer

MemeScope should describe scores and AI output as research signals, not guaranteed safety, return forecasts, or investment recommendations.
'@ | Set-Content -Encoding UTF8 "PRODUCTION.md"

Step "Membersihkan cache"
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue


Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Stage 10 files restored (checks deferred)." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
