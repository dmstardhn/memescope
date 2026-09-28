import type { Metadata, Viewport } from "next";

import { AppShell } from "@/components/app-shell";

import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "MemeScope - Solana Market Intelligence",
    template: "%s | MemeScope",
  },
  description:
    "Solana memecoin scanner, discovery, signal calls, risk analysis, wallet intelligence and market research.",
  applicationName: "MemeScope",
  keywords: [
    "Solana",
    "memecoin",
    "DEX",
    "market scanner",
    "signal calls",
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
      <body>
        <AppShell>{children}</AppShell>
      </body>
    </html>
  );
}