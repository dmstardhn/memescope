export type SignalKind =
  | "early-momentum"
  | "momentum"
  | "volume-spike"
  | "overheated"
  | "thin-liquidity";

export type SignalDirection =
  | "watch"
  | "caution";

export type SignalConfidence =
  | "high"
  | "medium"
  | "limited";

export type SignalCall = {
  id: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  imageUrl: string | null;

  kind: SignalKind;
  direction: SignalDirection;
  label: string;

  signalScore: number;
  confidence: SignalConfidence;

  detectedAt: number;

  priceUsd: number | null;
  priceChange5m: number | null;
  priceChange1h: number | null;

  liquidityUsd: number;
  marketCap: number | null;
  volume5m: number;
  volume1h: number;

  buys5m: number;
  sells5m: number;
  buyShare5m: number | null;
  volumeSpike5m: number | null;
  pairAgeMinutes: number | null;

  activityScore: number;

  potentialTargetPercent: number;
  potentialTargetReason: string;

  reasons: string[];
  caution: string[];
  dexUrl: string | null;
};

export type SignalSettings = {
  minSignalScore: number;
  minLiquidityUsd: number;
  maxPairAgeHours: number;

  // Optional advanced gates. Existing callers that only provide the
  // original three fields remain compatible; normalizeSignalSettings()
  // fills these values deterministically.
  minPairAgeMinutes?: number;
  minVolume5mUsd?: number;
  minTransactions5m?: number;
  minBuyShare?: number;
  maxBuyShare?: number;
  minVolumeSpike?: number;
  maxVolumeSpike?: number;
  minMomentum5m?: number;
  maxMomentum5m?: number;
  minMomentum1h?: number;
  maxMomentum1h?: number;
  minLiquidityValuationRatio?: number;
};
