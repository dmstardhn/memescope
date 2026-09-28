import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "MemeScope â€” Solana Market Intelligence",
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
