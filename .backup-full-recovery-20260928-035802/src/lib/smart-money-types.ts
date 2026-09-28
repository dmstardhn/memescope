export type SmartMoneyEvent = {
  wallet: string;
  mint: string;
  amount: number;
  timestamp: number;
  signature: string;
};

export type SmartMoneySignal = {
  mint: string;
  symbol: string;
  name: string;
  walletCount: number;
  wallets: string[];
  eventCount: number;
  totalTokenInflow: number;
  latestTimestamp: number;

  priceUsd: number | null;
  liquidityUsd: number | null;
  marketCap: number | null;
  fdv: number | null;
  volume5m: number | null;
  buys5m: number | null;
  sells5m: number | null;
  priceChange5m: number | null;
  pairCreatedAt: number | null;
  dexUrl: string | null;

  attentionScore: number;
  classification: "cluster" | "single";
};

export type SmartMoneyResponse = {
  generatedAt: number;
  walletsRequested: number;
  walletsAnalyzed: number;
  signaturesInspected: number;
  transactionsInspected: number;
  windowMinutes: number;
  signals: SmartMoneySignal[];
  events: SmartMoneyEvent[];
  warnings: string[];
};