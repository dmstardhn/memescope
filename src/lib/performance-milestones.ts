export const PUBLIC_MILESTONES = [3, 5, 10, 20, 50, 100] as const;

export function highestPublicMilestone(peakMultiple: number | null): number {
  if (peakMultiple === null || !Number.isFinite(peakMultiple)) return 0;
  return PUBLIC_MILESTONES.reduce<number>(
    (highest, milestone) => peakMultiple >= milestone ? milestone : highest,
    0,
  );
}

export function nextPublicMilestone(peakMultiple: number | null, published: number): number {
  const highest = highestPublicMilestone(peakMultiple);
  return highest > published ? highest : 0;
}

export function observedMultiple(
  previousPeak: number | null,
  entryPrice: number | null,
  callMarketCap: number | null,
  currentPrice: number | null,
  currentMarketCap: number | null,
): { current: number | null; peak: number } {
  const priceMultiple = entryPrice && entryPrice > 0 && currentPrice && currentPrice > 0
    ? currentPrice / entryPrice : null;
  const capMultiple = callMarketCap && callMarketCap > 0 && currentMarketCap && currentMarketCap > 0
    ? currentMarketCap / callMarketCap : null;
  const current = capMultiple ?? priceMultiple;
  return {
    current,
    peak: Math.max(1, previousPeak ?? 1, current ?? 0),
  };
}

export type PersistedCallInput = {
  tokenAddress: string;
  entryPriceUsd: number | null;
  callMarketCapUsd: number | null;
  peakMultiple: number | null;
  lastPublicMilestone: number;
};

export type MarketInput = { priceUsd: number | null; marketCapUsd: number | null };

export function evaluatePersistedCall(
  call: PersistedCallInput,
  markets: ReadonlyMap<string, MarketInput>,
) {
  const market = markets.get(call.tokenAddress);
  const price = market?.priceUsd && market.priceUsd > 0 ? market.priceUsd : null;
  const cap = market?.marketCapUsd && market.marketCapUsd > 0 ? market.marketCapUsd : null;
  if (!price && !cap) return null;
  const callCap = call.callMarketCapUsd ??
    (cap && price && call.entryPriceUsd && call.entryPriceUsd > 0
      ? cap * call.entryPriceUsd / price : null);
  const observed = observedMultiple(call.peakMultiple, call.entryPriceUsd, callCap, price, cap);
  return { price, cap, callCap, ...observed,
    nextMilestone: nextPublicMilestone(observed.peak, call.lastPublicMilestone) };
}
