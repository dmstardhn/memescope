export type WalletHolding = {
  mint: string;
  amount: number;
  decimals: number;
  symbol: string | null;
  name: string | null;
  priceUsd: number;
  valueUsd: number;
  marketCap: number;
  liquidity: number;
  dexUrl: string | null;
};

export type WalletActivity = {
  signature: string;
  blockTime: number | null;
  status: "success" | "failed";
  mint: string | null;
  delta: number;
  direction: "acquired" | "disposed" | "other";
  currentPriceUsd: number;
  currentDeltaValueUsd: number;
};

export type WalletReport = {
  ok: boolean;
  address: string;
  solBalance: number;
  visibleTokenValueUsd: number;
  holdings: WalletHolding[];
  recentActivity: WalletActivity[];
  recentSignatureCount: number;
  distinctTokensTouched: number;
  activityScore: number;
  positionTier: "Small" | "Medium" | "Large";
  rpcSource: string;
  updatedAt: number;
  limitations: string[];
  error?: string;
};
