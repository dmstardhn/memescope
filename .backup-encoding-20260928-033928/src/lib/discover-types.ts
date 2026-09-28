export type DiscoverCategory =
  | "new"
  | "trending"
  | "volume-spike"
  | "high-score";

export type DiscoverToken = {
  chainId: "solana";
  tokenAddress: string;
  pairAddress: string;
  name: string;
  symbol: string;
  imageUrl: string | null;
  dexId: string;
  dexUrl: string;
  priceUsd: number;
  marketCap: number;
  fdv: number;
  liquidity: number;
  volume5m: number;
  volume1h: number;
  volume24h: number;
  buys5m: number;
  sells5m: number;
  priceChange5m: number;
  priceChange1h: number;
  pairCreatedAt: number | null;
  ageMinutes: number | null;
  score: number;
  trendScore: number;
  volumeSpikeRatio: number;
  buySellRatio: number;
  boosts: number;
  categories: DiscoverCategory[];
};

export type DiscoverResponse = {
  ok: boolean;
  source: string;
  updatedAt: number;
  refreshMs: number;
  discoveryRefreshMs: number;
  candidates: number;
  tokens: DiscoverToken[];
  error?: string;
};

export type PumpLiveEvent = {
  receivedAt: number;
  type: "new-token" | "migration" | "unknown";
  mint: string | null;
  name: string | null;
  symbol: string | null;
  signature: string | null;
  rawType: string | null;
};
